param(
    [Parameter(Mandatory = $true)]
    [string]$BatPath,

    [string]$Source = "scheduled",
    [string]$ScheduleId = "",
    [string]$DisplayName = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root "data"

. (Join-Path $Root "execution-log.ps1")
Initialize-ExecutionLog -DataDir $DataDir

Invoke-BatWithLogging `
    -BatPath $BatPath `
    -Source $Source `
    -ScheduleId $ScheduleId `
    -DisplayName $DisplayName `
    -ProjectRoot $Root | Out-Null
