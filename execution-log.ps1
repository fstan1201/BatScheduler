$script:ExecutionsPath = $null
$script:ExecutionMutexName = "Global\BatSchedulerExecutions"
$script:MaxExecutionItems = 200

function Initialize-ExecutionLog {
    param([Parameter(Mandatory = $true)][string]$DataDir)

    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir | Out-Null
    }

    $script:ExecutionsPath = Join-Path $DataDir "executions.json"
    if (-not (Test-Path $script:ExecutionsPath)) {
        Set-Content -Path $script:ExecutionsPath -Value '{"items":[]}' -Encoding UTF8
    }
}

function Read-ExecutionStore {
    if (-not $script:ExecutionsPath) {
        throw "Execution log not initialized"
    }

    $raw = Get-Content -Path $script:ExecutionsPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ items = @() }
    }

    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj.items) {
        $obj | Add-Member -NotePropertyName items -NotePropertyValue @() -Force
    }
    if ($obj.items -isnot [System.Array]) {
        $obj.items = @($obj.items)
    }
    return $obj
}

function Write-ExecutionStore($store) {
    $json = $store | ConvertTo-Json -Depth 8
    Set-Content -Path $script:ExecutionsPath -Value $json -Encoding UTF8
}

function Add-ExecutionRecord($record) {
    $mutex = New-Object System.Threading.Mutex($false, $script:ExecutionMutexName)
    $locked = $false
    try {
        $locked = $mutex.WaitOne(15000)
        if (-not $locked) {
            throw "Execution log is busy"
        }

        $store = Read-ExecutionStore
        $items = @($record) + @($store.items)
        if ($items.Count -gt $script:MaxExecutionItems) {
            $items = $items[0..($script:MaxExecutionItems - 1)]
        }
        $store.items = $items
        Write-ExecutionStore $store
    } finally {
        if ($locked) {
            $mutex.ReleaseMutex() | Out-Null
        }
        $mutex.Dispose()
    }
}

function Get-ExecutionRecords {
    param([int]$Limit = 50)

    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt $script:MaxExecutionItems) { $Limit = $script:MaxExecutionItems }

    $store = Read-ExecutionStore
    return @($store.items | Select-Object -First $Limit)
}

function Invoke-BatWithLogging {
    param(
        [Parameter(Mandatory = $true)][string]$BatPath,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$ScheduleId = "",
        [string]$DisplayName = "",
        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    $startedAt = Get-Date
    $exitCode = -1
    $success = $false
    $message = ""
    $pidValue = $null

    $dir = Split-Path -Parent $BatPath
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $dir = $ProjectRoot
    }

    try {
        $proc = Start-Process -FilePath $BatPath -WorkingDirectory $dir -WindowStyle Hidden -PassThru -Wait
        if ($null -eq $proc) {
            throw "Failed to start bat process"
        }
        $pidValue = $proc.Id
        $exitCode = $proc.ExitCode
        $success = ($exitCode -eq 0)
        if (-not $success) {
            $message = "Exit code $exitCode"
        }
    } catch {
        $success = $false
        $message = $_.Exception.Message
        if ($exitCode -lt 0) {
            $exitCode = 1
        }
    }

    $finishedAt = Get-Date
    $durationMs = [int](($finishedAt - $startedAt).TotalMilliseconds)

    $record = [ordered]@{
        id          = [guid]::NewGuid().ToString("N")
        batPath     = $BatPath
        source      = $Source
        scheduleId  = $ScheduleId
        displayName = $DisplayName
        startedAt   = $startedAt.ToString("o")
        finishedAt  = $finishedAt.ToString("o")
        durationMs  = $durationMs
        success     = $success
        exitCode    = $exitCode
        message     = $message
        pid         = $pidValue
    }

    Add-ExecutionRecord $record
    return $record
}
