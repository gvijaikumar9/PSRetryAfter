#Requires -Version 5.1

Set-StrictMode -Version Latest

# Presets bundle the retry rules for a specific API family.
# RetryOn        - status codes worth retrying
# RateLimit403   - treat 403 as throttling when rate-limit headers say so (GitHub does this)
# BaseDelay      - starting backoff when the server gives no instruction
$script:RetryPresets = @{
    Generic = @{
        RetryOn      = @(408, 429, 500, 502, 503, 504)
        RateLimit403 = $false
        BaseDelay    = 1.0
    }
    Graph = @{
        RetryOn      = @(429, 500, 502, 503, 504)
        RateLimit403 = $false
        BaseDelay    = 2.0
    }
    SharePoint = @{
        RetryOn      = @(429, 500, 503)
        RateLimit403 = $false
        BaseDelay    = 2.0
    }
    GitHub = @{
        RetryOn      = @(429, 500, 502, 503)
        RateLimit403 = $true
        BaseDelay    = 1.0
    }
    AWS = @{
        RetryOn      = @(429, 500, 502, 503, 504)
        RateLimit403 = $false
        BaseDelay    = 1.0
    }
    ServiceNow = @{
        RetryOn      = @(429, 500, 502, 503)
        RateLimit403 = $false
        BaseDelay    = 1.0
    }
}

# Codes deliberately kept out of every preset, because a retry cannot fix them.
# This list is documentation, not an override. An explicit -RetryOn always wins,
# because silently contradicting a parameter the caller passed is worse than
# letting them retry something unusual on purpose.
$script:NotWorthRetrying = @(400, 401, 404, 405, 409, 410, 411, 412, 413, 414, 415, 422, 501)

function ConvertFrom-RetryAfterValue {
    <#
    .SYNOPSIS
        Converts a Retry-After header value into seconds.
    .DESCRIPTION
        RFC 9110 allows two forms, delta-seconds ("120") and an HTTP-date
        ("Wed, 21 Oct 2026 07:28:00 GMT"). Most implementations only handle the
        first and silently ignore the second. Returns $null when the value is
        absent or unparseable, so the caller can fall back to backoff.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[double]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $raw = $Value.Trim()

    # Form 1: delta-seconds
    $seconds = 0
    if ([int]::TryParse($raw, [ref] $seconds)) {
        if ($seconds -lt 0) { return $null }
        return [double] $seconds
    }

    # Form 2: HTTP-date
    $when = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [datetime]::TryParse(
        $raw,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref] $when)

    if ($parsed) {
        $delta = ($when - [datetime]::UtcNow).TotalSeconds
        if ($delta -lt 0) { return 0.0 }
        return [double] $delta
    }

    return $null
}

function ConvertTo-StatusCode {
    <#
    .SYNOPSIS
        Normalises a status code value, treating "no status" as no status.
    .DESCRIPTION
        HttpRequestException.StatusCode is null for transport failures such as a
        refused connection or a DNS failure, and [int]$null in PowerShell is 0
        rather than null. Without this guard every connection error looks like a
        real status code, matches nothing in the retry list, and fails instantly
        when it is the most retryable failure there is.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $Value
    )
    if ($null -eq $Value) { return $null }
    try { $code = [int] $Value } catch { return $null }
    if ($code -le 0) { return $null }
    return $code
}

function Get-ResponseDetail {
    <#
    .SYNOPSIS
        Pulls the status code and response headers out of a failed web call.
    .DESCRIPTION
        Windows PowerShell 5.1 throws System.Net.WebException carrying an
        HttpWebResponse, whose headers expose AllKeys. PowerShell 7 throws
        HttpResponseException carrying an HttpResponseMessage, whose headers
        enumerate as key/value pairs. This normalises both, and returns a null
        StatusCode for transport failures where there was no response at all.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    # PowerShell hashtables compare string keys case-insensitively, which is
    # what HTTP header lookup requires.
    $headers = @{}
    $status = $null
    $exception = $ErrorRecord.Exception

    $response = $null
    if ($null -ne $exception -and $exception.PSObject.Properties.Match('Response').Count -gt 0) {
        $response = $exception.Response
    }

    # PowerShell 7 puts the code on the exception as well as the response.
    if ($null -ne $exception -and $exception.PSObject.Properties.Match('StatusCode').Count -gt 0) {
        $status = ConvertTo-StatusCode $exception.StatusCode
    }

    if ($null -ne $response) {
        if ($null -eq $status -and $response.PSObject.Properties.Match('StatusCode').Count -gt 0) {
            $status = ConvertTo-StatusCode $response.StatusCode
        }

        $raw = $null
        if ($response.PSObject.Properties.Match('Headers').Count -gt 0) { $raw = $response.Headers }

        if ($null -ne $raw) {
            if ($raw.PSObject.Properties.Match('AllKeys').Count -gt 0) {
                # Windows PowerShell 5.1: WebHeaderCollection
                foreach ($key in $raw.AllKeys) { $headers[$key] = $raw[$key] }
            }
            else {
                # PowerShell 7: HttpResponseHeaders
                foreach ($pair in $raw) {
                    if ($pair.PSObject.Properties.Match('Key').Count -gt 0) {
                        $headers[[string] $pair.Key] = ($pair.Value -join ', ')
                    }
                }
            }
        }
    }

    return [pscustomobject] @{
        StatusCode = $status
        Headers    = $headers
    }
}

function Get-HeaderValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Headers.ContainsKey($Name)) { return [string] $Headers[$Name] }
    return $null
}

function Get-RetryDelay {
    <#
    .SYNOPSIS
        Decides how long to wait before the next attempt.
    .DESCRIPTION
        Prefers what the server actually said, in this order:
          1. x-ms-retry-after-ms  (Graph and several Azure services, milliseconds)
          2. Retry-After          (seconds or HTTP-date)
          3. x-ratelimit-reset    (unix epoch, honoured only when remaining is 0)
          4. exponential backoff with equal jitter, when the server said nothing
        Server instructions are returned uncapped. The caller enforces the
        overall time budget, because silently shortening a wait the server asked
        for is how a throttled client becomes a blocked one.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [int] $Attempt,
        [Parameter(Mandatory)] [double] $BaseDelaySeconds,
        [Parameter(Mandatory)] [double] $MaxDelaySeconds,
        [switch] $NoJitter
    )

    $ms = Get-HeaderValue -Headers $Headers -Name 'x-ms-retry-after-ms'
    if (-not [string]::IsNullOrWhiteSpace($ms)) {
        $parsedMs = 0
        if ([int]::TryParse($ms.Trim(), [ref] $parsedMs) -and $parsedMs -ge 0) {
            return [pscustomobject] @{ Seconds = [double] $parsedMs / 1000.0; Source = 'x-ms-retry-after-ms' }
        }
    }

    $retryAfter = ConvertFrom-RetryAfterValue (Get-HeaderValue -Headers $Headers -Name 'Retry-After')
    if ($null -ne $retryAfter) {
        return [pscustomobject] @{ Seconds = $retryAfter; Source = 'Retry-After' }
    }

    $remaining = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-remaining'
    $reset = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-reset'
    if ($remaining -eq '0' -and -not [string]::IsNullOrWhiteSpace($reset)) {
        $epoch = [long] 0
        if ([long]::TryParse($reset.Trim(), [ref] $epoch)) {
            $resetAt = [datetimeoffset]::FromUnixTimeSeconds($epoch).UtcDateTime
            $delta = ($resetAt - [datetime]::UtcNow).TotalSeconds
            if ($delta -lt 0) { $delta = 0.0 }
            return [pscustomobject] @{ Seconds = [double] $delta; Source = 'x-ratelimit-reset' }
        }
    }

    # Nothing from the server: exponential backoff, capped, with equal jitter.
    $uncapped = $BaseDelaySeconds * [Math]::Pow(2, ($Attempt - 1))
    $capped = [Math]::Min($uncapped, $MaxDelaySeconds)

    if ($NoJitter) {
        return [pscustomobject] @{ Seconds = [double] $capped; Source = 'backoff' }
    }

    # Equal jitter keeps a predictable floor, unlike full jitter which can
    # return almost zero and hammer a service that is already struggling.
    $half = $capped / 2.0
    $jittered = $half + (Get-Random -Minimum 0.0 -Maximum $half)
    return [pscustomobject] @{ Seconds = [double] $jittered; Source = 'backoff' }
}

function Test-RetryableFailure {
    <#
    .SYNOPSIS
        Decides whether a failure is worth another attempt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()] [AllowNull()] [System.Nullable[int]] $StatusCode,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [int[]] $RetryOn,
        [switch] $RateLimit403
    )

    # No status code means no response arrived: DNS, TLS, socket reset. Transient.
    if ($null -eq $StatusCode) { return $true }

    # GitHub reports secondary rate limits as 403, not 429. Only treat it as
    # throttling when the rate-limit headers agree, so a genuine permission
    # failure still fails immediately.
    if ($RateLimit403 -and $StatusCode -eq 403) {
        $remaining = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-remaining'
        if ($remaining -eq '0') { return $true }
        $retryAfter = Get-HeaderValue -Headers $Headers -Name 'Retry-After'
        if (-not [string]::IsNullOrWhiteSpace($retryAfter)) { return $true }
        return $false
    }

    # The retry list is the whole truth. Nothing is retried unless it is listed,
    # and anything listed is retried, including codes the presets avoid.
    if ($RetryOn -contains $StatusCode) { return $true }

    return $false
}

function Add-RetryContext {
    <#
    .SYNOPSIS
        Records how hard we tried onto the error, for post-mortem logging.
    .DESCRIPTION
        Annotates the exception's Data dictionary rather than its message, so
        existing error handling and log parsing are unaffected. Failing to
        annotate must never become the reason a call fails, hence the guard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [int] $Attempts,
        [Parameter(Mandatory)] [double] $ElapsedSeconds
    )
    try {
        $ErrorRecord.Exception.Data['PSRetryAfter.Attempts'] = $Attempts
        $ErrorRecord.Exception.Data['PSRetryAfter.ElapsedSeconds'] = [math]::Round($ElapsedSeconds, 2)
    }
    catch {
        Write-Debug "PSRetryAfter: could not annotate the error record. $($_.Exception.Message)"
    }
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Runs a script block, retrying throttled and transient failures using the
        delay the server asked for.

    .DESCRIPTION
        Wraps any call that may be throttled. On failure it reads the server's
        own instruction from Retry-After, x-ms-retry-after-ms or
        x-ratelimit-reset and waits exactly that long, falling back to
        exponential backoff with jitter only when the server said nothing.

        Failures that cannot succeed on a retry, such as 401 or 404, fail
        immediately rather than consuming the whole retry budget.

        Only terminating errors are caught. Use -ErrorAction Stop inside the
        script block if the command you are calling does not throw by default.

    .PARAMETER ScriptBlock
        The call to run. Its output is returned unchanged.

    .PARAMETER Preset
        Retry rules tuned for an API family: Generic, Graph, SharePoint, GitHub,
        AWS or ServiceNow. Defaults to Generic.

    .PARAMETER MaxAttempts
        Total attempts including the first. Defaults to 5. Set it high and let
        TimeoutSeconds govern when you are polling for something to come back.

    .PARAMETER TimeoutSeconds
        Overall budget across all attempts and waits. Defaults to 300. If the
        server asks for longer than the budget allows, the call fails at once
        instead of sleeping and failing anyway.

    .PARAMETER RetryOn
        Status codes to retry, replacing the preset's list. This is taken
        literally. Listing 404 will retry 404, which is what you want when you
        are waiting for something to be created.

    .PARAMETER BaseDelaySeconds
        First backoff delay when the server gives no instruction. Defaults to
        the preset value.

    .PARAMETER MaxDelaySeconds
        Cap applied to calculated backoff. Does not cap a delay the server
        explicitly asked for. Defaults to 60.

    .PARAMETER NoJitter
        Use exact exponential backoff. Jitter is on by default because
        synchronised clients retrying together is what keeps a service down.

    .PARAMETER FixedDelaySeconds
        Wait the same amount between every attempt instead of backing off, for
        polling. Cannot be combined with BaseDelaySeconds, MaxDelaySeconds or
        NoJitter. Aliased to IntervalSeconds. A delay the server asks for still
        takes precedence over this.

    .PARAMETER OnRetry
        Script block invoked before each wait, receiving attempt number, delay
        in seconds, and the ErrorRecord. Intended for logging, so anything it
        returns is discarded and anything it throws is reported as a warning
        and ignored. Use Write-Host or Write-Verbose inside it to produce output.

    .EXAMPLE
        Invoke-WithRetry -Preset Graph -ScriptBlock {
            Invoke-RestMethod -Uri $uri -Headers $headers
        }

    .EXAMPLE
        Invoke-WithRetry -Preset GitHub -MaxAttempts 8 -TimeoutSeconds 900 -ScriptBlock {
            Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Headers $h
        } -OnRetry { param($attempt, $delay, $err) Write-Host "attempt $attempt, waiting $delay s" }

    .EXAMPLE
        # Try 1000 times, 10 seconds apart. Remember to raise the budget too,
        # because 1000 x 10s is about 2.8 hours and the default budget is 5 min.
        Invoke-WithRetry -MaxAttempts 1000 -FixedDelaySeconds 10 -TimeoutSeconds 11000 `
            -RetryOn 404, 500, 502, 503, 504 -ScriptBlock {
                Invoke-RestMethod -Uri 'https://example.internal/healthz'
            }

    .EXAMPLE
        # Check every two hours for a week.
        Invoke-WithRetry -MaxAttempts 100 -FixedDelaySeconds 7200 -TimeoutSeconds 604800 -ScriptBlock {
            Invoke-RestMethod -Uri 'https://example.internal/status'
        }

    .LINK
        https://github.com/gvijaikumar9/PSRetryAfter
    #>
    [CmdletBinding(DefaultParameterSetName = 'Backoff')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [scriptblock] $ScriptBlock,

        [Parameter()]
        [Alias('Api')]
        [ValidateSet('Generic', 'Graph', 'SharePoint', 'GitHub', 'AWS', 'ServiceNow')]
        [string] $Preset = 'Generic',

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxAttempts = 5,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutSeconds = 300,

        [Parameter()]
        [int[]] $RetryOn,

        [Parameter(ParameterSetName = 'Backoff')]
        [ValidateRange(0.1, 600)]
        [double] $BaseDelaySeconds,

        [Parameter(ParameterSetName = 'Backoff')]
        [ValidateRange(0.1, 3600)]
        [double] $MaxDelaySeconds = 60,

        [Parameter(ParameterSetName = 'Backoff')]
        [switch] $NoJitter,

        [Parameter(Mandatory, ParameterSetName = 'FixedDelay')]
        [ValidateRange(0.1, 86400)]
        [Alias('IntervalSeconds')]
        [double] $FixedDelaySeconds,

        [Parameter()]
        [scriptblock] $OnRetry
    )

    $settings = $script:RetryPresets[$Preset]

    if (-not $PSBoundParameters.ContainsKey('RetryOn')) { $RetryOn = $settings.RetryOn }

    if ($PSCmdlet.ParameterSetName -eq 'FixedDelay') {
        # A flat interval is just backoff whose floor and ceiling are the same.
        $BaseDelaySeconds = $FixedDelaySeconds
        $MaxDelaySeconds = $FixedDelaySeconds
        $NoJitter = $true
    }
    elseif (-not $PSBoundParameters.ContainsKey('BaseDelaySeconds')) {
        $BaseDelaySeconds = $settings.BaseDelay
    }

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $result = & $ScriptBlock
            return $result
        }
        catch {
            $failure = $_
            $detail = Get-ResponseDetail -ErrorRecord $failure
            $status = $detail.StatusCode
            $label = if ($null -eq $status) { 'no response' } else { "HTTP $status" }

            $retryable = Test-RetryableFailure -StatusCode $status -Headers $detail.Headers `
                -RetryOn $RetryOn -RateLimit403:([bool] $settings.RateLimit403)

            if (-not $retryable) {
                Write-Verbose "PSRetryAfter: $label is not retryable, failing immediately on attempt $attempt."
                Add-RetryContext -ErrorRecord $failure -Attempts $attempt -ElapsedSeconds ((Get-Date) - $started).TotalSeconds
                $PSCmdlet.ThrowTerminatingError($failure)
            }

            if ($attempt -ge $MaxAttempts) {
                Write-Verbose "PSRetryAfter: $label on attempt $attempt, no attempts left."
                Add-RetryContext -ErrorRecord $failure -Attempts $attempt -ElapsedSeconds ((Get-Date) - $started).TotalSeconds
                $PSCmdlet.ThrowTerminatingError($failure)
            }

            $delay = Get-RetryDelay -Headers $detail.Headers -Attempt $attempt `
                -BaseDelaySeconds $BaseDelaySeconds -MaxDelaySeconds $MaxDelaySeconds -NoJitter:$NoJitter

            $remainingBudget = ($deadline - (Get-Date)).TotalSeconds
            if ($remainingBudget -le 0) {
                Write-Verbose 'PSRetryAfter: time budget exhausted.'
                Add-RetryContext -ErrorRecord $failure -Attempts $attempt -ElapsedSeconds ((Get-Date) - $started).TotalSeconds
                $PSCmdlet.ThrowTerminatingError($failure)
            }

            if ($delay.Seconds -gt $remainingBudget) {
                Write-Verbose ("PSRetryAfter: server asked for {0:N1}s via {1} but only {2:N1}s of budget remains." -f `
                        $delay.Seconds, $delay.Source, $remainingBudget)
                Add-RetryContext -ErrorRecord $failure -Attempts $attempt -ElapsedSeconds ((Get-Date) - $started).TotalSeconds
                $PSCmdlet.ThrowTerminatingError($failure)
            }

            if ($OnRetry) {
                # A broken logger must never break the retry loop, nor replace
                # the real failure with its own. Its output is discarded too,
                # or anything the callback emits would contaminate the result
                # the caller is waiting for.
                try { $null = & $OnRetry $attempt $delay.Seconds $failure }
                catch {
                    Write-Warning "PSRetryAfter: the OnRetry callback threw and was ignored. $($_.Exception.Message)"
                }
            }

            Write-Verbose ("PSRetryAfter: {0} on attempt {1}, waiting {2:N1}s ({3})." -f `
                    $label, $attempt, $delay.Seconds, $delay.Source)

            # Clamp so an absurd server instruction cannot overflow the cast.
            $sleepMs = [Math]::Min($delay.Seconds * 1000.0, [double] [int]::MaxValue)
            Start-Sleep -Milliseconds ([int] $sleepMs)
        }
    }
}

Export-ModuleMember -Function Invoke-WithRetry
