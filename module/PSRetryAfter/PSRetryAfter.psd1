@{
    RootModule            = 'PSRetryAfter.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = 'f4dcc42c-3b8a-43c6-b6f2-6ceca8911ae0'
    Author                = 'Vijay Kumar G'
    CompanyName           = 'Unknown'
    Copyright             = '(c) Vijay Kumar G. All rights reserved.'

    Description           = 'Retries any command using the delay the server actually asked for. Wraps a script block, so it works with Graph, PnP, AWS and any other cmdlet, not only Invoke-RestMethod. Reads Retry-After in both its seconds and HTTP-date forms, plus x-ms-retry-after-ms and x-ratelimit-reset, and falls back to exponential backoff with jitter only when the server says nothing. Fails fast on errors a retry cannot fix, enforces a total time budget, and supports a flat interval for polling. No dependencies, Windows PowerShell 5.1 and PowerShell 7 on Windows, Linux and macOS.'

    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')

    RequiredModules       = @()
    RequiredAssemblies    = @()

    FunctionsToExport     = @('Invoke-WithRetry')
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData = @{
        PSData = @{
            Tags         = @(
                'Retry', 'RetryAfter', 'Backoff', 'Throttling', 'RateLimit',
                'HTTP', 'REST', 'Resilience', 'Graph', 'GitHub',
                'PSEdition_Core', 'PSEdition_Desktop', 'Windows', 'Linux', 'MacOS'
            )
            LicenseUri   = 'https://github.com/gvijaikumar9/PSRetryAfter/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/gvijaikumar9/PSRetryAfter'
            ReleaseNotes = @'
0.1.0 - first release

Invoke-WithRetry runs any script block with server-directed retry, so it wraps
Graph, PnP, AWS and ordinary cmdlets, not only Invoke-RestMethod.

Delays
- Honours Retry-After as delta-seconds and as an HTTP-date. Most
  implementations only parse the first form.
- Honours x-ms-retry-after-ms (Graph and Azure) and x-ratelimit-reset (GitHub).
- A delay the server asked for is never shortened.
- Exponential backoff with equal jitter when the server gives no instruction.
- -FixedDelaySeconds gives a flat interval for polling.

Stopping
- Fails fast on status codes a retry cannot fix.
- Total time budget via -TimeoutSeconds, not just an attempt count.
- Transport failures such as a refused connection are always treated as
  transient and retried.
- -RetryOn is taken literally, so listing 404 really does retry 404.

Presets for Generic, Graph, SharePoint, GitHub, AWS and ServiceNow. The GitHub
preset treats 403 as throttling only when the rate-limit headers agree.

Diagnostics
- The original error is rethrown unchanged, with attempt count and elapsed
  time attached to Exception.Data.
- -OnRetry is isolated. What it throws becomes a warning, what it returns is
  discarded, so a broken logger cannot break the retry or corrupt the result.

Requires no other modules. Tested on Windows PowerShell 5.1 and PowerShell 7.
'@
        }
    }
}
