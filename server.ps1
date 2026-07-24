# Bat Scheduler - local web UI + Windows Task Scheduler
# Usage: powershell -ExecutionPolicy Bypass -File .\server.ps1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublicDir = Join-Path $Root "public"
$DataDir = Join-Path $Root "data"
$StorePath = Join-Path $DataDir "schedules.json"
$TaskFolder = "BatScheduler"
$Port = 8787
$Prefix = "http://localhost:$Port/"

if (-not (Test-Path $PublicDir)) {
    throw "public folder not found: $PublicDir"
}

if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
}

if (-not (Test-Path $StorePath)) {
    Set-Content -Path $StorePath -Value '{"items":[]}' -Encoding UTF8
}

. (Join-Path $Root "execution-log.ps1")
Initialize-ExecutionLog -DataDir $DataDir

. (Join-Path $Root "auth.ps1")
Initialize-Auth -DataDir $DataDir

function Read-Store {
    $raw = Get-Content -Path $StorePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ items = @() }
    }
    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj.items) {
        $obj | Add-Member -NotePropertyName items -NotePropertyValue @() -Force
    }
    if ($obj.items -isnot [System.Array]) {
        if ($null -eq $obj.items) {
            $obj.items = @()
        } else {
            $obj.items = @($obj.items)
        }
    }
    return $obj
}

function Write-Store($store) {
    $json = $store | ConvertTo-Json -Depth 6
    Set-Content -Path $StorePath -Value $json -Encoding UTF8
}

function Send-Json($response, $statusCode, $obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Send-Text($response, $statusCode, $contentType, $text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $response.StatusCode = $statusCode
    $response.ContentType = $contentType
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Send-File($response, $filePath) {
    $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
    $map = @{
        ".html" = "text/html; charset=utf-8"
        ".css"  = "text/css; charset=utf-8"
        ".js"   = "application/javascript; charset=utf-8"
        ".json" = "application/json; charset=utf-8"
        ".svg"  = "image/svg+xml"
        ".ico"  = "image/x-icon"
        ".png"  = "image/png"
    }
    $contentType = if ($map.ContainsKey($ext)) { $map[$ext] } else { "application/octet-stream" }
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $response.StatusCode = 200
    $response.ContentType = $contentType
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Get-RequestBody($request) {
    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }
}

function New-SafeTaskName([string]$displayName) {
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $rand = Get-Random -Minimum 1000 -Maximum 9999
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return "task_$stamp`_$rand"
    }
    $safe = ($displayName -replace '[^\w\-]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "task"
    }
    if ($safe.Length -gt 40) {
        $safe = $safe.Substring(0, 40)
    }
    return "${safe}_$stamp`_$rand"
}

function Test-BatPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return "Please enter a bat file path"
    }
    if ($path -match '[;&|<>]') {
        return "Path contains invalid characters"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return "File not found: $path"
    }
    if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -ne ".bat") {
        return "Only .bat files are allowed"
    }
    return $null
}

function New-ScheduledBatTask($item) {
    $fullTaskName = "\$TaskFolder\$($item.taskName)"
    $runner = Join-Path $Root "run-bat.ps1"
    $safeDisplay = ([string]$item.displayName).Replace('"', "'")
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`" -BatPath `"$($item.batPath)`" -Source scheduled -ScheduleId `"$($item.id)`" -DisplayName `"$safeDisplay`""

    if ($item.daily) {
        $argList = @(
            "/Create",
            "/TN", $fullTaskName,
            "/TR", $tr,
            "/SC", "DAILY",
            "/ST", $item.time,
            "/RL", "LIMITED",
            "/F"
        )
    } else {
        $dateObj = [datetime]::ParseExact($item.date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        # zh-TW schtasks expects yyyy/MM/dd (zero-padded). en-US often wants MM/dd/yyyy.
        $cultureName = [System.Globalization.CultureInfo]::CurrentCulture.Name
        if ($cultureName -like "zh*") {
            $sd = $dateObj.ToString("yyyy/MM/dd")
        } else {
            $sd = $dateObj.ToString("MM/dd/yyyy")
        }
        $argList = @(
            "/Create",
            "/TN", $fullTaskName,
            "/TR", $tr,
            "/SC", "ONCE",
            "/SD", $sd,
            "/ST", $item.time,
            "/RL", "LIMITED",
            "/F"
        )
    }

    $output = & schtasks.exe @argList 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = "schtasks create failed (exit $LASTEXITCODE)"
        }
        throw $msg
    }
}

function Remove-ScheduledBatTask([string]$taskName) {
    $fullTaskName = "\$TaskFolder\$taskName"
    $output = & schtasks.exe /Delete /TN $fullTaskName /F 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        $msg = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = "schtasks delete failed (exit $LASTEXITCODE)"
        }
        throw $msg
    }
}

function Handle-RunBat($response, [string]$batPath, [string]$source = "manual", [string]$scheduleId = "", [string]$displayName = "") {
    $pathError = Test-BatPath $batPath
    if ($pathError) {
        Send-Json $response 400 @{ error = $pathError }
        return
    }

    try {
        $record = Invoke-BatWithLogging `
            -BatPath $batPath `
            -Source $source `
            -ScheduleId $scheduleId `
            -DisplayName $displayName `
            -ProjectRoot $Root
        Send-Json $response 200 @{ ok = $true; run = $record }
    } catch {
        Send-Json $response 500 @{ error = "Failed to run bat: $($_.Exception.Message)" }
    }
}

function Handle-Api($request, $response) {
    $method = $request.HttpMethod.ToUpperInvariant()
    $path = $request.Url.AbsolutePath.TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }

    if ($method -eq "GET" -and $path -eq "/api/executions") {
        $limit = 50
        $q = $request.Url.Query
        if ($q -match '[?&]limit=(\d+)') {
            $limit = [int]$Matches[1]
        }
        $items = Get-ExecutionRecords -Limit $limit
        Send-Json $response 200 @{ items = @($items) }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/schedules") {
        $store = Read-Store
        Send-Json $response 200 @{ items = @($store.items) }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/run") {
        $bodyText = Get-RequestBody $request
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            Send-Json $response 400 @{ error = "Missing request body" }
            return
        }
        $body = $bodyText | ConvertFrom-Json
        Handle-RunBat $response ([string]$body.batPath)
        return
    }

    if ($method -eq "POST" -and $path -match '^/api/schedules/([A-Za-z0-9]+)/run$') {
        $id = $Matches[1]
        $store = Read-Store
        $target = @($store.items) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $target) {
            Send-Json $response 404 @{ error = "Schedule not found" }
            return
        }
        Handle-RunBat $response ([string]$target.batPath) "schedule-run" ([string]$target.id) ([string]$target.displayName)
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/schedules") {
        $bodyText = Get-RequestBody $request
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            Send-Json $response 400 @{ error = "Missing request body" }
            return
        }

        $body = $bodyText | ConvertFrom-Json
        $batPath = [string]$body.batPath
        $date = [string]$body.date
        $time = [string]$body.time
        $daily = [bool]$body.daily
        $displayName = [string]$body.taskName

        $pathError = Test-BatPath $batPath
        if ($pathError) {
            Send-Json $response 400 @{ error = $pathError }
            return
        }

        if ([string]::IsNullOrWhiteSpace($date) -or $date -notmatch '^\d{4}-\d{2}-\d{2}$') {
            Send-Json $response 400 @{ error = "Invalid date format" }
            return
        }
        if ([string]::IsNullOrWhiteSpace($time) -or $time -notmatch '^\d{2}:\d{2}$') {
            Send-Json $response 400 @{ error = "Invalid time format" }
            return
        }

        $timeParts = $time.Split(":")
        $time = "{0:D2}:{1:D2}" -f [int]$timeParts[0], [int]$timeParts[1]

        if (-not $daily) {
            $runAt = [datetime]::ParseExact("$date $time", "yyyy-MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
            if ($runAt -le (Get-Date)) {
                Send-Json $response 400 @{ error = "Scheduled time must be in the future" }
                return
            }
        }

        $taskName = New-SafeTaskName $displayName
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = "Bat task $time"
        }

        $item = [ordered]@{
            id          = [guid]::NewGuid().ToString("N")
            taskName    = $taskName
            displayName = $displayName
            batPath     = $batPath
            date        = $date
            time        = $time
            daily       = $daily
            createdAt   = (Get-Date).ToString("o")
        }

        try {
            New-ScheduledBatTask $item
        } catch {
            Send-Json $response 500 @{ error = "Failed to create scheduled task: $($_.Exception.Message)" }
            return
        }

        $store = Read-Store
        $items = @($store.items) + @($item)
        $store.items = $items
        Write-Store $store

        Send-Json $response 201 @{ item = $item }
        return
    }

    if ($method -eq "DELETE" -and $path -match '^/api/schedules/([A-Za-z0-9\-]+)$') {
        $id = $Matches[1]
        $store = Read-Store
        $target = @($store.items) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $target) {
            Send-Json $response 404 @{ error = "Schedule not found" }
            return
        }

        try {
            Remove-ScheduledBatTask $target.taskName
        } catch {
            Send-Json $response 500 @{ error = "Failed to delete scheduled task: $($_.Exception.Message)" }
            return
        }

        $store.items = @($store.items | Where-Object { $_.id -ne $id })
        Write-Store $store
        Send-Json $response 200 @{ ok = $true }
        return
    }

    Send-Json $response 404 @{ error = "API not found" }
}

function Handle-Static($request, $response) {
    $rel = $request.Url.AbsolutePath
    if ($rel -eq "/" -or [string]::IsNullOrWhiteSpace($rel)) {
        $rel = "/index.html"
    }

    $rel = $rel.Replace("/", [IO.Path]::DirectorySeparatorChar).TrimStart([IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $PublicDir $rel))
    $publicRoot = [IO.Path]::GetFullPath($PublicDir)

    if (-not $candidate.StartsWith($publicRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text $response 403 "text/plain; charset=utf-8" "Forbidden"
        return
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Send-Text $response 404 "text/plain; charset=utf-8" "Not Found"
        return
    }

    Send-File $response $candidate
}

function Ensure-UrlAcl {
    $existing = netsh http show urlacl url=$Prefix 2>$null
    if ($existing -match [regex]::Escape($Prefix)) {
        return
    }
    Write-Host "Registering URL ACL for current user..." -ForegroundColor Yellow
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $out = netsh http add urlacl url=$Prefix user="$user" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $out
        Write-Host ""
        Write-Host "If startup fails, run as Administrator:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=$Prefix user=`"$user`"" -ForegroundColor Cyan
    }
}

Ensure-UrlAcl

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)

try {
    $listener.Start()
} catch {
    Write-Host "Failed to start server: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run as Administrator once:" -ForegroundColor Yellow
    Write-Host "  netsh http add urlacl url=$Prefix user=`"$env:USERDOMAIN\$env:USERNAME`"" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "Bat Scheduler is running" -ForegroundColor Green
Write-Host "Open in browser: $Prefix" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("Cache-Control", "no-store")

        try {
            $path = $request.Url.AbsolutePath
            if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }
            $method = $request.HttpMethod.ToUpperInvariant()

            if ($path.StartsWith("/api/auth/")) {
                Handle-AuthApi $request $response
            }
            elseif (Test-AuthPublicStatic $path) {
                Handle-Static $request $response
            }
            else {
                $session = Get-RequestSession $request
                if (-not $session) {
                    if ($path.StartsWith("/api/")) {
                        Send-Json $response 401 @{ error = "Unauthorized" }
                    }
                    else {
                        Send-Redirect $response "/login.html"
                    }
                    continue
                }

                if ($path.StartsWith("/api/users")) {
                    Handle-UsersApi $request $response $session
                }
                elseif ($path.StartsWith("/api/")) {
                    Handle-Api $request $response
                }
                else {
                    Handle-Static $request $response
                }
            }
        } catch {
            try {
                Send-Json $response 500 @{ error = $_.Exception.Message }
            } catch {
            }
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
