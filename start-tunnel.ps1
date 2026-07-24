# Cloudflare Quick Tunnel for Bat Scheduler (http://localhost:8787)
# First run downloads cloudflared.exe into .\tools\

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir = Join-Path $Root "tools"
$Cloudflared = Join-Path $ToolsDir "cloudflared.exe"
$LogPath = Join-Path $Root "data\tunnel.log"
$UrlPath = Join-Path $Root "data\tunnel-url.txt"
$Port = 8787

New-Item -ItemType Directory -Path (Join-Path $Root "data") -Force | Out-Null
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null

function Test-LocalServer {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 3
        return $r.StatusCode -eq 200
    } catch {
        return $false
    }
}

if (-not (Test-LocalServer)) {
    Write-Host "Local server not running on port $Port. Starting server.ps1..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-Command", "& '$Root\server.ps1' *> '$Root\data\server-start.log'"
    ) -WindowStyle Hidden
    Start-Sleep -Seconds 3
    if (-not (Test-LocalServer)) {
        Write-Host "Failed to reach http://localhost:$Port/ — run start.bat first." -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $Cloudflared)) {
    Write-Host "Downloading cloudflared..." -ForegroundColor Cyan
    $dl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Invoke-WebRequest -Uri $dl -OutFile $Cloudflared -UseBasicParsing
}

Write-Host ""
Write-Host "Starting Cloudflare Quick Tunnel -> http://localhost:$Port" -ForegroundColor Green
Write-Host "Log: $LogPath" -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop the tunnel (local server keeps running)." -ForegroundColor DarkGray
Write-Host ""

$proc = Start-Process -FilePath $Cloudflared -ArgumentList @(
    "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:$Port", "--http-host-header", "localhost:$Port"
) -RedirectStandardOutput $LogPath -RedirectStandardError (Join-Path $Root "data\tunnel.err.log") -PassThru -NoNewWindow

Start-Sleep -Seconds 10

foreach ($file in @($LogPath, (Join-Path $Root "data\tunnel.err.log"))) {
    if (-not (Test-Path $file)) { continue }
    $log = Get-Content $file -Raw -ErrorAction SilentlyContinue
    if ($log -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
        $public = $Matches[0]
        Set-Content -Path $UrlPath -Value $public -Encoding UTF8
        Write-Host "Public URL:" -ForegroundColor Green
        Write-Host "  $public" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Saved to: $UrlPath" -ForegroundColor DarkGray
        break
    }
}

if (-not (Test-Path $UrlPath)) {
    Write-Host "Tunnel starting... check these logs for trycloudflare.com URL:" -ForegroundColor Yellow
    Write-Host "  $LogPath" -ForegroundColor DarkGray
    Write-Host "  $(Join-Path $Root 'data\tunnel.err.log')" -ForegroundColor DarkGray
}

try {
    Wait-Process -Id $proc.Id
} finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}
