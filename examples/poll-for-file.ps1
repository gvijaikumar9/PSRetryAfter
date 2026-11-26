<#
.SYNOPSIS
    Reads examples\sample.txt with Invoke-WithRetry, waiting for it if it is missing.

.DESCRIPTION
    Edit sample.txt and run this again to see your own content read back.

    Delete sample.txt and run this, and it will poll for the file every few
    seconds. Create it from another window while it waits and it picks it up.

    The point of the demo: retry means "keep trying until it works, then stop".
    It is not a scheduler. A file that is already readable is read once.

.EXAMPLE
    .\examples\poll-for-file.ps1
    Reads sample.txt. If it is missing, polls for it.

.EXAMPLE
    .\examples\poll-for-file.ps1 -Simulate
    Moves sample.txt aside, puts it back after 12 seconds, so you can watch the
    retry work without touching anything. Your file is restored afterwards.

.EXAMPLE
    .\examples\poll-for-file.ps1 -Reset
    Puts sample.txt back with its default content, if you deleted it.

.EXAMPLE
    .\examples\poll-for-file.ps1 -Attempts 10 -IntervalSeconds 3
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive example. Printing to the host is the whole point.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
    Justification = 'Values are passed with -ArgumentList and received by param().')]
[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot 'sample.txt'),
    [switch] $Simulate,
    [switch] $Reset,
    [int] $Attempts = 4,
    [int] $IntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\module\PSRetryAfter\PSRetryAfter.psd1" -Force

$DefaultContent = 'Edit this line and run poll-for-file.ps1 again to see your change read back.'
$budget = ($Attempts * $IntervalSeconds) + 30
$restorer = $null

if ($Reset) {
    Set-Content -LiteralPath $Path -Value $DefaultContent
    Write-Host ''
    Write-Host "  sample.txt restored to its default content." -ForegroundColor Green
}

Write-Host ''
Write-Host "  file   : $Path"
Write-Host "  policy : up to $Attempts attempts, $IntervalSeconds seconds apart"

if ($Simulate) {
    if (-not (Test-Path $Path)) {
        Set-Content -LiteralPath $Path -Value $DefaultContent
        Write-Host '  note   : sample.txt was missing, so I created it to have something to simulate.' -ForegroundColor DarkGray
    }
    $saved = Get-Content -LiteralPath $Path -Raw
    Remove-Item $Path -Force
    Write-Host '  mode   : simulating. File removed, a background job restores it in 12s.' -ForegroundColor Yellow
    $restorer = Start-ThreadJob -ArgumentList $Path, $saved -ScriptBlock {
        param($Path, $saved)
        Start-Sleep -Seconds 12
        Set-Content -LiteralPath $Path -Value $saved -NoNewline
    }
}
elseif (-not (Test-Path $Path)) {
    Write-Host ''
    Write-Host '  The file is missing, so this will poll for it.' -ForegroundColor Yellow
    Write-Host '  Create it from another window while this waits:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "      Set-Content -LiteralPath '$Path' -Value 'hello from me'" -ForegroundColor White
    Write-Host ''
    Write-Host '  Or press Ctrl+C and run this to put the original back:' -ForegroundColor DarkGray
    Write-Host '      .\examples\poll-for-file.ps1 -Reset' -ForegroundColor DarkGray
}

Write-Host ''
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$reads = 0

try {
    $content = Invoke-WithRetry -MaxAttempts $Attempts -FixedDelaySeconds $IntervalSeconds -TimeoutSeconds $budget -ScriptBlock {
        $script:reads++
        # -ErrorAction Stop matters. Get-Content reports a missing file quietly
        # by default, and a quiet failure is one this module never sees.
        Get-Content -LiteralPath $Path -ErrorAction Stop
    } -OnRetry {
        param($attempt, $delay, $err)
        Write-Host ("  attempt {0} failed ({1}), waiting {2}s" -f `
                $attempt, $err.Exception.GetType().Name, $delay) -ForegroundColor DarkYellow
    }

    $stopwatch.Stop()
    $reads = $script:reads
    Write-Host ("  SUCCESS after {0} attempt(s) in {1:N1}s" -f $reads, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ''
    Write-Host '  --- file content ---' -ForegroundColor Cyan
    $content | ForEach-Object { Write-Host "  $_" }
    Write-Host '  --------------------' -ForegroundColor Cyan

    if ($reads -eq 1) {
        Write-Host ''
        Write-Host '  Read once, because it worked first time.' -ForegroundColor Yellow
        Write-Host '  Retry stops at the first success. To read N times regardless, use a loop.' -ForegroundColor Yellow
    }
}
catch {
    $stopwatch.Stop()
    Write-Host ("  GAVE UP after {0} attempts over {1:N1}s" -f `
            $_.Exception.Data['PSRetryAfter.Attempts'], $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Red
    Write-Host "  reason: $($_.Exception.Message)"
}
finally {
    if ($restorer) {
        $restorer | Wait-Job -Timeout 20 | Out-Null
        try { $restorer | Remove-Job -Force } catch { Write-Verbose "cleanup: $_" }
        if (-not (Test-Path $Path)) { Set-Content -LiteralPath $Path -Value $saved -NoNewline }
        Write-Host ''
        Write-Host '  sample.txt restored.' -ForegroundColor DarkGray
    }
}

Write-Host ''
