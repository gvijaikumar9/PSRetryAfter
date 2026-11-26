# Manual verification harness: proves header extraction works against real
# HTTP failures. Uses a raw TCP listener so there are no HttpListener URL-ACL
# quirks and the exact bytes on the wire are under our control.

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\module\PSRetryAfter\PSRetryAfter.psd1" -Force
$port = Get-Random -Minimum 21000 -Maximum 29000

# Windows PowerShell 5.1 has no ThreadJob, so fall back to a process job there.
$starter = 'Start-Job'
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { $starter = 'Start-ThreadJob' }

$job = & $starter -ArgumentList $port -ScriptBlock {
    param($port)
    $CRLF = "`r`n"
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $deadline = (Get-Date).AddSeconds(40)
    $throttleHits = 0
    try {
        while ((Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buf = New-Object byte[] 8192
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { continue }   # readiness probe, not a real request
                $request = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
                $path = '/'
                if ($request -match '^[A-Z]+\s+(\S+)') { $path = $Matches[1] }

                $lines = @()
                $body = ''
                if ($path -eq '/ratelimit') {
                    $reset = [datetimeoffset]::UtcNow.AddSeconds(1).ToUnixTimeSeconds()
                    $lines += 'HTTP/1.1 403 Forbidden'
                    $lines += 'x-ratelimit-remaining: 0'
                    $lines += "x-ratelimit-reset: $reset"
                }
                elseif ($path -eq '/forbidden') {
                    $lines += 'HTTP/1.1 403 Forbidden'
                }
                else {
                    $throttleHits++
                    if ($throttleHits -lt 3) {
                        $lines += 'HTTP/1.1 429 Too Many Requests'
                        $lines += 'Retry-After: 1'
                    }
                    else {
                        $lines += 'HTTP/1.1 200 OK'
                        $lines += 'Content-Type: application/json'
                        $body = '{"ok":true}'
                    }
                }
                $lines += "Content-Length: $($body.Length)"
                $lines += 'Connection: close'
                $payload = ($lines -join $CRLF) + $CRLF + $CRLF + $body
                $bytes = [Text.Encoding]::ASCII.GetBytes($payload)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            finally { $client.Close() }
        }
    }
    finally { $listener.Stop() }
}

# Wait for the listener to accept connections. A process job needs longer than
# a thread job, so poll rather than guess.
$ready = $false
for ($i = 0; $i -lt 150; $i++) {
    try {
        $probe = New-Object System.Net.Sockets.TcpClient
        $probe.Connect('127.0.0.1', $port)
        $probe.Close()
        $ready = $true
        break
    }
    catch { Start-Sleep -Milliseconds 100 }
}
if (-not $ready) { throw "listener did not come up on port $port" }

try {
    '--- real 429 carrying Retry-After: 1 (expect two ~1s waits) ---'
    $sw = [diagnostics.stopwatch]::StartNew()
    $all = Invoke-WithRetry -MaxAttempts 5 -ScriptBlock {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/api" -TimeoutSec 10
    } -Verbose 4>&1
    $sw.Stop()
    $all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { "   $_" }
    $data = $all | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }
    "   returned ok=$($data.ok)  elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,2))s"

    ''
    '--- GitHub 403 WITH rate-limit headers (expect one retry, then give up) ---'
    $sw2 = [diagnostics.stopwatch]::StartNew()
    try {
        Invoke-WithRetry -Preset GitHub -MaxAttempts 2 -ScriptBlock {
            Invoke-RestMethod -Uri "http://127.0.0.1:$port/ratelimit" -TimeoutSec 10
        } -Verbose 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            ForEach-Object { "   $_" }
    }
    catch { "   gave up after $([math]::Round($sw2.Elapsed.TotalSeconds,2))s" }

    ''
    '--- plain 403, no rate-limit headers (expect immediate failure) ---'
    $sw3 = [diagnostics.stopwatch]::StartNew()
    try {
        Invoke-WithRetry -Preset GitHub -MaxAttempts 5 -ScriptBlock {
            Invoke-RestMethod -Uri "http://127.0.0.1:$port/forbidden" -TimeoutSec 10
        } -Verbose 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            ForEach-Object { "   $_" }
    }
    catch { "   failed after $([math]::Round($sw3.Elapsed.TotalSeconds,2))s" }
}
finally {
    try { $job | Remove-Job -Force } catch { Write-Verbose "listener job cleanup: $_" }
}
