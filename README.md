# PSRetryAfter

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PSRetryAfter.svg)](https://www.powershellgallery.com/packages/PSRetryAfter)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Retry any command using the delay the server actually asked for.

No dependencies. Windows PowerShell 5.1 and PowerShell 7, on Windows, Linux and macOS.

```powershell
Invoke-WithRetry -Preset Graph -ScriptBlock {
    Invoke-MgGraphRequest -Method GET -Uri 'v1.0/users?$top=999'
}
```

## What it wraps

Anything you can put in a script block. Not just URLs.

```powershell
# Graph, which throttles hard on large tenants
Invoke-WithRetry -Preset Graph -ScriptBlock { Get-MgUser -All }

# PnP
Invoke-WithRetry -Preset SharePoint -ScriptBlock { Get-PnPListItem -List 'Documents' -PageSize 500 }

# several steps retried together as one unit
Invoke-WithRetry -ScriptBlock {
    $item = Get-PnPListItem -List 'Requests' -Id $id
    Set-PnPListItem -List 'Requests' -Identity $item -Values @{ Status = 'Done' }
}

# a flaky file share, nothing to do with HTTP at all
Invoke-WithRetry -ScriptBlock { Copy-Item \\server\share\report.xlsx C:\temp\ -ErrorAction Stop }
```

## The one rule that catches people

**The command has to fail loudly.** PowerShell has two kinds of failure and `try`/`catch` only sees one. Most cmdlets report problems quietly and carry on, so the retry never sees anything go wrong.

| | Result |
| --- | --- |
| `Get-Item 'C:\missing'` | ran **once**, not retried |
| `Get-Item 'C:\missing' -ErrorAction Stop` | ran **4 times**, retried |

Web and API cmdlets usually throw on their own, so `Invoke-RestMethod`, `Invoke-MgGraphRequest` and most Graph and PnP cmdlets just work. File, process and local cmdlets usually do not.

When in doubt add `-ErrorAction Stop`. It costs nothing and never hurts.

## Install

```powershell
Install-Module -Name PSRetryAfter -Scope CurrentUser
```

## When you do not need this

If you are on PowerShell 7 and calling a plain URL, the built-in retry is probably enough, and it already honours `Retry-After`:

```powershell
Invoke-RestMethod -Uri $uri -Headers $h -MaximumRetryCount 5 -RetryIntervalSec 2
```

Reach for this module when that is not available or not sufficient:

- **Windows PowerShell 5.1**, which has no retry at all
- **Any cmdlet that is not `Invoke-RestMethod` or `Invoke-WebRequest`**, since `-MaximumRetryCount` cannot wrap Graph, PnP, AWS or anything else
- **Fast-fail.** Native retried an unauthenticated Graph call for 15.49 seconds. This fails it in 0.05
- **A total time budget**, polling with a flat interval, GitHub's 403, and a logging hook

## The problem it solves

```powershell
# what ends up in every script, eventually
$attempt = 0
do {
    try   { $r = Invoke-RestMethod -Uri $uri -Headers $h; break }
    catch { $attempt++; Start-Sleep -Seconds 5 }
} while ($attempt -lt 5)
```

Four problems, the same four every time. It ignores what the server said, so sleeping 5 when Graph asked for 120 just gets you throttled again. It retries things that can never succeed, burning five attempts on a 404. It waits 5 seconds when the server said 2. And it has no overall budget, so a long server delay times five attempts can hang a scheduled job for an hour.

## What it reads

Checked in this order, first one present wins.

| Header | Used by | Notes |
| --- | --- | --- |
| `x-ms-retry-after-ms` | Graph, several Azure services | Milliseconds |
| `Retry-After` | Most APIs | Handles **both** RFC forms, delta-seconds and an HTTP-date. Most implementations only parse the first |
| `x-ratelimit-reset` | GitHub | Unix epoch, honoured only when `x-ratelimit-remaining` is `0` |
| none of the above | | Exponential backoff with equal jitter |

A delay the server explicitly asked for is never shortened. Shortening it is how a throttled client becomes a blocked one. If the requested wait exceeds the remaining budget, the call fails immediately rather than sleeping and then failing anyway.

## Waiting for something to come back

```powershell
# check every 5 seconds for up to 10 minutes, until the service answers
Invoke-WithRetry -MaxAttempts 1000 -FixedDelaySeconds 5 -TimeoutSeconds 600 `
                 -RetryOn 404, 500, 502, 503, 504 `
                 -ScriptBlock { Invoke-RestMethod -Uri 'https://example.internal/healthz' }
```

`-FixedDelaySeconds` replaces the growing backoff with the same gap every time.

| Want | Use |
| --- | --- |
| 1000 attempts, 10 seconds apart | `-MaxAttempts 1000 -FixedDelaySeconds 10 -TimeoutSeconds 11000` |
| 1000 attempts, 2 minutes apart | `-MaxAttempts 1000 -FixedDelaySeconds 120 -TimeoutSeconds 125000` |
| Every 2 hours for a week | `-MaxAttempts 100 -FixedDelaySeconds 7200 -TimeoutSeconds 604800` |

**Raise `-TimeoutSeconds` whenever you raise `-MaxAttempts`.** It defaults to 300 seconds, so asking for 1000 attempts without touching it gets you five minutes' worth and no more. Multiply attempts by interval and use a slightly larger number.

`-RetryOn` is taken literally. Listing 404 really does retry 404, which is what you want when waiting for something to be created. A connection refused outright has no status code at all and is always treated as transient, so a service that is not listening yet is covered without listing anything.

Retry stops at the first success. It is not a scheduler. To do something a fixed number of times regardless, use a loop.

## Try it

```powershell
# reads examples\sample.txt. Edit that file and run again to see your text
.\examples\poll-for-file.ps1

# removes the file, restores it after 12 seconds, so you can watch it wait
.\examples\poll-for-file.ps1 -Simulate -Attempts 6 -IntervalSeconds 3

# put sample.txt back if you deleted it
.\examples\poll-for-file.ps1 -Reset
```

## Before you wrap a write

Retrying is safe for reads. It is not automatically safe for writes.

A `POST` that times out may already have been processed, and retrying it can create the record twice. The module cannot tell the difference, because it only sees a script block.

Wrap writes when the operation is idempotent, such as a `PUT` to a known key, when the API supports an idempotency key and you are sending one, or when a duplicate is harmless in your context.

## When things fail

The original error is rethrown unchanged, so existing error handling keeps working. Retry context is attached for logging, without altering the message.

```powershell
try {
    Invoke-WithRetry -Preset Graph -ScriptBlock { Invoke-MgGraphRequest -Method GET -Uri 'v1.0/users' }
}
catch {
    $attempts = $_.Exception.Data['PSRetryAfter.Attempts']
    $elapsed  = $_.Exception.Data['PSRetryAfter.ElapsedSeconds']
    Write-Warning "gave up after $attempts attempts over $elapsed seconds: $($_.Exception.Message)"
}
```

`-OnRetry` is treated strictly as a side effect. Anything it throws becomes a warning and is ignored, and anything it returns is discarded, so a broken or chatty logger can neither break the retry loop nor contaminate the value you get back. Use `Write-Host` or `Write-Verbose` inside it.

## Presets

| Preset | Retries on | Notes |
| --- | --- | --- |
| `Generic` | 408, 429, 500, 502, 503, 504 | Default |
| `Graph` | 429, 500, 502, 503, 504 | |
| `SharePoint` | 429, 500, 503 | |
| `GitHub` | 429, 500, 502, 503 | Also treats **403 as throttling** when the rate-limit headers agree, because that is how GitHub signals a secondary rate limit |
| `AWS` | 429, 500, 502, 503, 504 | |
| `ServiceNow` | 429, 500, 502, 503 | |

No preset lists a code that a retry cannot fix, so 400, 401, 404, 409 and 422 fail immediately. If you genuinely want one retried, list it in `-RetryOn` and it will be.

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ScriptBlock` | required | The call to run. Output is returned unchanged |
| `-Preset` | `Generic` | Retry rules for an API family. Alias `-Api` |
| `-MaxAttempts` | 5 | Total attempts including the first |
| `-TimeoutSeconds` | 300 | Overall budget across all attempts and waits |
| `-RetryOn` | from preset | Status codes to retry. Taken literally |
| `-FixedDelaySeconds` | | Flat interval between attempts, for polling. Alias `-IntervalSeconds`. Cannot be combined with the three below |
| `-BaseDelaySeconds` | from preset | First backoff delay when the server says nothing |
| `-MaxDelaySeconds` | 60 | Caps calculated backoff only, never a server instruction |
| `-NoJitter` | off | Use exact backoff. Jitter is on by default because synchronised clients retrying together is what keeps a service down |
| `-OnRetry` | none | Script block receiving attempt, delay and the ErrorRecord |

`-Verbose` reports which header supplied each delay.

## Why 5.1 matters here

Windows PowerShell 5.1 and PowerShell 7 surface HTTP failures as completely different exception types carrying completely different header collections. Getting that right once, in a module with no dependencies of its own, is the point. A helper that demands PowerShell 7.2 is one no enterprise module author can take a dependency on.

## Not in scope

Circuit breakers, a logging framework, and an HTTP client of its own. Those are what turn a dependency into something nobody wants to depend on.

## Licence

MIT. See [LICENSE](LICENSE).
