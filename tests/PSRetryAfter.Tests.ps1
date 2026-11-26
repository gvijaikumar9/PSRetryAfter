BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..\module\PSRetryAfter\PSRetryAfter.psd1'
    Import-Module $manifest -Force
}

Describe 'ConvertFrom-RetryAfterValue' {

    It 'parses the delta-seconds form' {
        InModuleScope PSRetryAfter { ConvertFrom-RetryAfterValue '120' } | Should -Be 120
    }

    It 'parses zero' {
        InModuleScope PSRetryAfter { ConvertFrom-RetryAfterValue '0' } | Should -Be 0
    }

    It 'rejects a negative delta' {
        InModuleScope PSRetryAfter { ConvertFrom-RetryAfterValue '-5' } | Should -BeNullOrEmpty
    }

    It 'parses the HTTP-date form, which most implementations ignore' {
        $result = InModuleScope PSRetryAfter {
            $future = ([datetime]::UtcNow.AddSeconds(60)).ToString('R')
            ConvertFrom-RetryAfterValue $future
        }
        $result | Should -BeGreaterThan 55
        $result | Should -BeLessOrEqual 60
    }

    It 'treats an HTTP-date already in the past as no wait' {
        InModuleScope PSRetryAfter {
            $past = ([datetime]::UtcNow.AddSeconds(-30)).ToString('R')
            ConvertFrom-RetryAfterValue $past
        } | Should -Be 0
    }

    It 'returns nothing for an unparseable value' {
        InModuleScope PSRetryAfter { ConvertFrom-RetryAfterValue 'not-a-date' } | Should -BeNullOrEmpty
    }

    It 'returns nothing for an empty value' {
        InModuleScope PSRetryAfter { ConvertFrom-RetryAfterValue '' } | Should -BeNullOrEmpty
    }
}

Describe 'Get-RetryDelay' {

    It 'prefers x-ms-retry-after-ms and converts milliseconds to seconds' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{ 'x-ms-retry-after-ms' = '5000' } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60
        }
        $d.Seconds | Should -Be 5
        $d.Source  | Should -Be 'x-ms-retry-after-ms'
    }

    It 'uses Retry-After when present' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{ 'Retry-After' = '7' } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60
        }
        $d.Seconds | Should -Be 7
        $d.Source  | Should -Be 'Retry-After'
    }

    It 'looks headers up without regard to case' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{ 'RETRY-AFTER' = '9' } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60
        }
        $d.Seconds | Should -Be 9
    }

    It 'gives x-ms-retry-after-ms precedence over Retry-After' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{ 'x-ms-retry-after-ms' = '2000'; 'Retry-After' = '99' } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60
        }
        $d.Seconds | Should -Be 2
    }

    It 'honours x-ratelimit-reset only when the remaining count is zero' {
        $d = InModuleScope PSRetryAfter {
            $reset = [datetimeoffset]::UtcNow.AddSeconds(30).ToUnixTimeSeconds()
            Get-RetryDelay -Headers @{ 'x-ratelimit-remaining' = '0'; 'x-ratelimit-reset' = "$reset" } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60
        }
        $d.Source  | Should -Be 'x-ratelimit-reset'
        $d.Seconds | Should -BeGreaterThan 25
    }

    It 'ignores x-ratelimit-reset while requests remain' {
        $d = InModuleScope PSRetryAfter {
            $reset = [datetimeoffset]::UtcNow.AddSeconds(30).ToUnixTimeSeconds()
            Get-RetryDelay -Headers @{ 'x-ratelimit-remaining' = '57'; 'x-ratelimit-reset' = "$reset" } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 60 -NoJitter
        }
        $d.Source | Should -Be 'backoff'
    }

    It 'falls back to exponential backoff when the server says nothing' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{} -Attempt 3 -BaseDelaySeconds 1 -MaxDelaySeconds 60 -NoJitter
        }
        $d.Seconds | Should -Be 4     # 1 * 2^(3-1)
        $d.Source  | Should -Be 'backoff'
    }

    It 'caps calculated backoff at MaxDelaySeconds' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{} -Attempt 10 -BaseDelaySeconds 1 -MaxDelaySeconds 30 -NoJitter
        }
        $d.Seconds | Should -Be 30
    }

    It 'keeps jitter between half the cap and the cap' {
        $values = InModuleScope PSRetryAfter {
            1..40 | ForEach-Object {
                (Get-RetryDelay -Headers @{} -Attempt 3 -BaseDelaySeconds 1 -MaxDelaySeconds 60).Seconds
            }
        }
        ($values | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 2
        ($values | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 4
    }

    It 'does not cap a delay the server explicitly asked for' {
        $d = InModuleScope PSRetryAfter {
            Get-RetryDelay -Headers @{ 'Retry-After' = '600' } `
                -Attempt 1 -BaseDelaySeconds 1 -MaxDelaySeconds 30
        }
        $d.Seconds | Should -Be 600
    }
}

Describe 'Test-RetryableFailure' {

    It 'retries when no response arrived at all' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode $null -Headers @{} -RetryOn @(429)
        } | Should -BeTrue
    }

    It 'retries a status code in the retry list' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 429 -Headers @{} -RetryOn @(429, 503)
        } | Should -BeTrue
    }

    It 'does not retry a status code outside the retry list' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 418 -Headers @{} -RetryOn @(429)
        } | Should -BeFalse
    }

    It 'does not retry 404 under any preset' {
        InModuleScope PSRetryAfter {
            $codes = $script:RetryPresets.Keys | ForEach-Object { $script:RetryPresets[$_].RetryOn }
            Test-RetryableFailure -StatusCode 404 -Headers @{} -RetryOn ($codes | Sort-Object -Unique)
        } | Should -BeFalse
    }

    It 'does not retry 401 under any preset' {
        InModuleScope PSRetryAfter {
            $codes = $script:RetryPresets.Keys | ForEach-Object { $script:RetryPresets[$_].RetryOn }
            Test-RetryableFailure -StatusCode 401 -Headers @{} -RetryOn ($codes | Sort-Object -Unique)
        } | Should -BeFalse
    }

    It 'honours an explicit request to retry 404, for polling a resource into existence' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 404 -Headers @{} -RetryOn @(404, 503)
        } | Should -BeTrue
    }

    It 'keeps every preset clear of codes a retry cannot fix' {
        InModuleScope PSRetryAfter {
            $codes = $script:RetryPresets.Keys | ForEach-Object { $script:RetryPresets[$_].RetryOn } | Sort-Object -Unique
            @($codes | Where-Object { $script:NotWorthRetrying -contains $_ })
        } | Should -BeNullOrEmpty
    }

    It 'treats 403 as throttling when rate-limit headers agree' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 403 -Headers @{ 'x-ratelimit-remaining' = '0' } `
                -RetryOn @(429) -RateLimit403
        } | Should -BeTrue
    }

    It 'treats 403 as a real permission failure when requests remain' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 403 -Headers @{ 'x-ratelimit-remaining' = '42' } `
                -RetryOn @(429) -RateLimit403
        } | Should -BeFalse
    }

    It 'never treats 403 as throttling without the GitHub preset' {
        InModuleScope PSRetryAfter {
            Test-RetryableFailure -StatusCode 403 -Headers @{ 'x-ratelimit-remaining' = '0' } `
                -RetryOn @(429)
        } | Should -BeFalse
    }
}

Describe 'Invoke-WithRetry' {

    It 'returns the value on first success without retrying' {
        $script:calls = 0
        $result = Invoke-WithRetry -ScriptBlock { $script:calls++; 'done' }
        $result | Should -Be 'done'
        $script:calls | Should -Be 1
    }

    It 'passes multiple output objects through unchanged' {
        $result = Invoke-WithRetry -ScriptBlock { 1, 2, 3 }
        $result.Count | Should -Be 3
        $result[1] | Should -Be 2
    }

    It 'retries a transient failure then succeeds' {
        $script:calls = 0
        $result = Invoke-WithRetry -MaxAttempts 4 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw 'connection reset' }
            'recovered'
        }
        $result | Should -Be 'recovered'
        $script:calls | Should -Be 3
    }

    It 'stops at MaxAttempts and rethrows the original error' {
        $script:calls = 0
        { Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
                $script:calls++; throw 'always broken'
            } } | Should -Throw -ExpectedMessage 'always broken'
        $script:calls | Should -Be 3
    }

    It 'invokes the OnRetry callback with attempt, delay and error' {
        $script:seen = @()
        $script:calls = 0
        Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw 'transient' }
            'ok'
        } -OnRetry {
            param($attempt, $delay, $err)
            $script:seen += [pscustomobject]@{ Attempt = $attempt; Delay = $delay; Message = $err.Exception.Message }
        } | Out-Null

        $script:seen.Count | Should -Be 2
        $script:seen[0].Attempt | Should -Be 1
        $script:seen[0].Message | Should -Be 'transient'
        $script:seen[1].Delay | Should -BeGreaterThan 0
    }

    It 'gives up once the time budget is spent' {
        $script:calls = 0
        $sw = [diagnostics.stopwatch]::StartNew()
        { Invoke-WithRetry -MaxAttempts 50 -TimeoutSeconds 1 -BaseDelaySeconds 0.3 -NoJitter -ScriptBlock {
                $script:calls++; throw 'still broken'
            } } | Should -Throw
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
        $script:calls | Should -BeLessThan 50
    }

    It 'exposes the documented presets' {
        $cmd = Get-Command Invoke-WithRetry
        $values = $cmd.Parameters['Preset'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            Select-Object -ExpandProperty ValidValues
        $values | Should -Contain 'Graph'
        $values | Should -Contain 'GitHub'
        $values | Should -Contain 'Generic'
    }
}

Describe 'Transport failures' {

    It 'treats a missing status code as no status, not as zero' {
        InModuleScope PSRetryAfter { ConvertTo-StatusCode $null } | Should -BeNullOrEmpty
        InModuleScope PSRetryAfter { ConvertTo-StatusCode 0 }     | Should -BeNullOrEmpty
        InModuleScope PSRetryAfter { ConvertTo-StatusCode 429 }   | Should -Be 429
    }

    It 'retries a refused connection, which is the most retryable failure there is' {
        # Port 1 on loopback refuses immediately. This is a real network failure,
        # not a synthetic exception, which is how the original bug slipped past.
        $script:calls = 0
        $caught = $null
        try {
            Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
                $script:calls++
                Invoke-RestMethod -Uri 'http://127.0.0.1:1/' -TimeoutSec 5
            }
        }
        catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $script:calls | Should -Be 3
        $caught.Exception.Data['PSRetryAfter.Attempts'] | Should -Be 3
    }
}

Describe 'Caller-defined retry shape' {

    It 'holds a flat interval with -FixedDelaySeconds' {
        $script:calls = 0
        $script:observed = @()
        try {
            Invoke-WithRetry -MaxAttempts 4 -FixedDelaySeconds 0.4 -TimeoutSeconds 30 -ScriptBlock {
                $script:calls++; throw 'nope'
            } -OnRetry {
                param($attempt, $delay, $err)
                $script:observed += [pscustomobject]@{
                    Attempt = $attempt
                    Delay   = $delay
                    Message = $err.Exception.Message
                }
            }
        }
        catch { Write-Verbose "expected final failure: $($_.Exception.Message)" }

        $script:calls | Should -Be 4
        $script:observed.Count | Should -Be 3
        ($script:observed.Delay | Sort-Object -Unique) | Should -Be 0.4
        $script:observed[0].Message | Should -Be 'nope'
    }

    It 'refuses to mix a fixed interval with backoff settings' {
        { Invoke-WithRetry -FixedDelaySeconds 5 -BaseDelaySeconds 2 -ScriptBlock { 'x' } } |
            Should -Throw
    }

    It 'allows very large attempt counts and budgets' {
        $cmd = Get-Command Invoke-WithRetry
        $attempts = $cmd.Parameters['MaxAttempts'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
        $budget = $cmd.Parameters['TimeoutSeconds'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }

        $attempts.MaxRange | Should -BeGreaterThan 100000
        $budget.MaxRange   | Should -BeGreaterThan 604800   # more than a week
    }

    It 'runs many attempts when the budget allows it' {
        $script:calls = 0
        try {
            Invoke-WithRetry -MaxAttempts 1000 -FixedDelaySeconds 0.1 -TimeoutSeconds 3 -ScriptBlock {
                $script:calls++; throw 'nope'
            }
        }
        catch { Write-Verbose "expected final failure: $($_.Exception.Message)" }

        $script:calls | Should -BeGreaterThan 10
        $script:calls | Should -BeLessThan 1000
    }
}

Describe 'Production hardening' {

    It 'survives a throwing OnRetry callback and keeps retrying' {
        $script:calls = 0
        $result = Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -WarningAction SilentlyContinue -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw 'transient' }
            'recovered'
        } -OnRetry { throw 'logging blew up' }

        $result | Should -Be 'recovered'
        $script:calls | Should -Be 3
    }

    It 'warns, rather than fails, when the OnRetry callback throws' {
        $script:calls = 0
        Invoke-WithRetry -MaxAttempts 2 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 2) { throw 'transient' }
            'ok'
        } -OnRetry { throw 'boom' } -WarningVariable captured -WarningAction SilentlyContinue | Out-Null

        $captured.Count | Should -BeGreaterThan 0
        "$captured" | Should -BeLike '*OnRetry callback threw*'
    }

    It 'discards callback output so it cannot contaminate the result' {
        $script:calls = 0
        $result = Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw 'transient' }
            'REAL-RESULT'
        } -OnRetry { 'noise from the logger' }

        @($result).Count | Should -Be 1
        $result | Should -Be 'REAL-RESULT'
    }

    It 'never lets the callback error replace the real failure' {
        $script:calls = 0
        try {
            Invoke-WithRetry -MaxAttempts 2 -BaseDelaySeconds 0.1 -NoJitter -WarningAction SilentlyContinue -ScriptBlock {
                $script:calls++; throw 'the real api error'
            } -OnRetry { throw 'logging blew up' }
        }
        catch { $_.Exception.Message | Should -Be 'the real api error' }
    }

    It 'records attempts and elapsed time on the thrown error' {
        $caught = $null
        try { Invoke-WithRetry -MaxAttempts 3 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock { throw 'always broken' } }
        catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['PSRetryAfter.Attempts'] | Should -Be 3
        $caught.Exception.Data['PSRetryAfter.ElapsedSeconds'] | Should -BeGreaterThan 0
    }

    It 'preserves the original message when giving up' {
        try { Invoke-WithRetry -MaxAttempts 2 -BaseDelaySeconds 0.1 -NoJitter -ScriptBlock { throw 'upstream exploded' } }
        catch { $_.Exception.Message | Should -Be 'upstream exploded' }
    }

    It 'does not impose its own strict mode on the caller script block' {
        Set-StrictMode -Off
        $script:calls = 0
        $result = Invoke-WithRetry -MaxAttempts 2 -ScriptBlock {
            $script:calls++
            # Reading an unset variable throws under StrictMode Latest. The
            # module sets that for itself, and it must not reach the caller.
            $null = $aVariableThatWasNeverDefined
            'fine'
        }
        $result | Should -Be 'fine'
        $script:calls | Should -Be 1
    }
}

Describe 'Module surface' {

    It 'exports exactly one command' {
        (Get-Module PSRetryAfter).ExportedFunctions.Keys | Should -Be 'Invoke-WithRetry'
    }

    It 'declares no required modules, so it is safe to depend on' {
        $data = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\module\PSRetryAfter\PSRetryAfter.psd1')
        $data.RequiredModules.Count | Should -Be 0
    }

    It 'supports Windows PowerShell 5.1' {
        $data = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\module\PSRetryAfter\PSRetryAfter.psd1')
        $data.PowerShellVersion | Should -Be '5.1'
        $data.CompatiblePSEditions | Should -Contain 'Desktop'
    }
}
