# Create GitHub repo BatScheduler and push (requires: gh auth login)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$gh = "C:\Program Files\GitHub CLI\gh.exe"
$git = "C:\Program Files\Git\bin\git.exe"

if (-not (Test-Path $gh)) {
    throw "GitHub CLI not found. Install: winget install GitHub.cli"
}

& $gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to GitHub. Run:" -ForegroundColor Yellow
    Write-Host "  & `"$gh`" auth login --hostname github.com --git-protocol https --web" -ForegroundColor Cyan
    exit 1
}

Set-Location $Root

$remotes = & $git remote 2>$null
if ($remotes -contains "origin") {
    Write-Host "Remote 'origin' already exists. Pushing..." -ForegroundColor Yellow
    & $git push -u origin master
    if ($LASTEXITCODE -ne 0) { & $git push -u origin main }
    exit $LASTEXITCODE
}

Write-Host "Creating GitHub repository BatScheduler and pushing..." -ForegroundColor Green
& $gh repo create BatScheduler --public --source=. --remote=origin --description "Local web UI to schedule and run Windows bat files" --push
if ($LASTEXITCODE -ne 0) {
    Write-Host "If 'BatScheduler' already exists, try a different name or delete the empty repo on GitHub first." -ForegroundColor Yellow
    exit $LASTEXITCODE
}

$url = & $gh repo view --json url -q .url
Write-Host "Done: $url" -ForegroundColor Green
