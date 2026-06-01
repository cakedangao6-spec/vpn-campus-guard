<#
.SYNOPSIS
    Campus VPN Guard - Windows WiFi environment detection and VPN auto-control sample.
.DESCRIPTION
    Reads config.json from the script directory, detects the current WiFi profile,
    and closes a configured VPN client when the WiFi name starts with the configured
    campus_wifi_prefix. On non-campus networks, it can optionally start the VPN client.

    Copy config.example.json to config.json before running.
#>

#Requires -Version 5.0

param(
    [switch]$CheckOnly,
    [switch]$CheckLog
)

Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config.json'
$exampleConfigPath = Join-Path $scriptRoot 'config.example.json'

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $scriptRoot $PathValue
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host 'Missing config.json.' -ForegroundColor Yellow
        Write-Host "Copy config.example.json to config.json, then fill in your local values." -ForegroundColor Yellow
        Write-Host "Example file: $exampleConfigPath" -ForegroundColor Gray
        exit 2
    }

    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json
    } catch {
        Write-Error "Failed to read config.json: $($_.Exception.Message)"
        exit 2
    }

    $required = @('campus_wifi_prefix', 'vpn_exe_path', 'vpn_process_name')
    foreach ($name in $required) {
        if (-not ($config.PSObject.Properties.Name -contains $name) -or [string]::IsNullOrWhiteSpace([string]$config.$name)) {
            Write-Error "Missing required config value: $name"
            exit 2
        }
    }

    if (-not ($config.PSObject.Properties.Name -contains 'poll_interval_seconds') -or $null -eq $config.poll_interval_seconds) {
        $config | Add-Member -NotePropertyName poll_interval_seconds -NotePropertyValue 2
    }
    if (-not ($config.PSObject.Properties.Name -contains 'log_path') -or [string]::IsNullOrWhiteSpace([string]$config.log_path)) {
        $config | Add-Member -NotePropertyName log_path -NotePropertyValue 'logs\campus-guard.log'
    }
    if (-not ($config.PSObject.Properties.Name -contains 'mutex_name') -or [string]::IsNullOrWhiteSpace([string]$config.mutex_name)) {
        $config | Add-Member -NotePropertyName mutex_name -NotePropertyValue 'Global\CampusVpnGuard'
    }
    if (-not ($config.PSObject.Properties.Name -contains 'auto_start_vpn_when_off_campus') -or $null -eq $config.auto_start_vpn_when_off_campus) {
        $config | Add-Member -NotePropertyName auto_start_vpn_when_off_campus -NotePropertyValue $true
    }

    return $config
}

$config = Read-Config
$campusWifiPrefix = [string]$config.campus_wifi_prefix
$vpnExePath = Resolve-ProjectPath ([string]$config.vpn_exe_path)
$vpnProcessName = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.vpn_process_name)
$logFile = Resolve-ProjectPath ([string]$config.log_path)
$pollIntervalSec = [int]$config.poll_interval_seconds
$mutexName = [string]$config.mutex_name
$autoStartVpnWhenOffCampus = [bool]$config.auto_start_vpn_when_off_campus
$logMaxSizeBytes = 1MB

function Get-CurrentSSID {
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        if ($profiles) {
            foreach ($profile in $profiles) {
                $alias = $profile.InterfaceAlias
                if ($alias -like '*WiFi*' -or $alias -like '*WLAN*' -or $alias -like '*Wireless*') {
                    $name = $profile.Name
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        return $name.Trim()
                    }
                }
            }
        }
    } catch {
    }

    try {
        $wlanInfo = netsh wlan show interfaces 2>&1
        $ssidLine = $wlanInfo | Select-String 'SSID\s*:\s(.+)$' | Select-Object -First 1
        if ($ssidLine) {
            return $ssidLine.Matches[0].Groups[1].Value.Trim()
        }
    } catch {
    }

    return $null
}

function Test-IsCampusNetwork {
    param([string]$Ssid)

    if ([string]::IsNullOrWhiteSpace($Ssid)) {
        return $false
    }

    return $Ssid -like "$campusWifiPrefix*"
}

function Write-GuardLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Color = 'Gray'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor $Color

    try {
        $logDir = Split-Path -Parent $logFile
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }

        if (Test-Path -LiteralPath $logFile) {
            $fileInfo = Get-Item -LiteralPath $logFile
            if ($fileInfo.Length -gt $logMaxSizeBytes) {
                Set-Content -LiteralPath $logFile -Value $line -Encoding UTF8
                return
            }
        }

        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch {
    }
}

function Stop-VpnClient {
    $closed = $false
    $processes = Get-Process -Name $vpnProcessName -ErrorAction SilentlyContinue

    if ($processes) {
        foreach ($process in $processes) {
            try {
                $process.Kill()
                $closed = $true
                Write-GuardLog "Closed VPN client process (PID: $($process.Id))." 'Yellow'
            } catch {
                Write-GuardLog "Failed to close PID $($process.Id): $($_.Exception.Message)" 'DarkYellow'
            }
        }
    }

    try {
        $imageName = "$vpnProcessName.exe"
        $taskkillResult = taskkill /f /im $imageName 2>&1 | Out-String
        if ($taskkillResult -match 'SUCCESS|成功') {
            $closed = $true
        }
    } catch {
    }

    return $closed
}

function Start-VpnClientIfNeeded {
    if (-not $autoStartVpnWhenOffCampus) {
        Write-GuardLog 'Auto-start is disabled by config.' 'Cyan'
        return
    }

    $existing = Get-Process -Name $vpnProcessName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-GuardLog 'VPN client is already running.' 'Cyan'
        return
    }

    if (-not (Test-Path -LiteralPath $vpnExePath)) {
        Write-GuardLog "VPN executable not found. Check vpn_exe_path in config.json." 'Red'
        return
    }

    try {
        Start-Process -FilePath $vpnExePath -WindowStyle Normal
        Write-GuardLog 'Started VPN client.' 'Green'
    } catch {
        Write-GuardLog "Failed to start VPN client: $($_.Exception.Message)" 'Red'
    }
}

function Write-DiagnosticReport {
    $currentSSID = Get-CurrentSSID
    $isCampus = Test-IsCampusNetwork -Ssid $currentSSID
    $vpnProcess = Get-Process -Name $vpnProcessName -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  Campus VPN Guard - Status' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host "Config file: $configPath" -ForegroundColor Gray
    Write-Host "Log file: $logFile" -ForegroundColor Gray
    Write-Host "WiFi prefix: $campusWifiPrefix" -ForegroundColor Gray

    if ([string]::IsNullOrWhiteSpace($currentSSID)) {
        Write-Host 'Current network: no WiFi profile detected' -ForegroundColor Gray
    } else {
        Write-Host "Current WiFi: $currentSSID" -ForegroundColor White
        if ($isCampus) {
            Write-Host 'Network type: protected campus network' -ForegroundColor Yellow
        } else {
            Write-Host 'Network type: other network' -ForegroundColor Green
        }
    }

    if ($vpnProcess) {
        Write-Host "VPN client status: running (PID: $($vpnProcess.Id -join ', '))" -ForegroundColor Yellow
    } else {
        Write-Host 'VPN client status: not running' -ForegroundColor Gray
    }

    Write-Host '==========================================' -ForegroundColor Cyan
}

if ($CheckOnly) {
    Write-DiagnosticReport
    exit 0
}

if ($CheckLog) {
    if (Test-Path -LiteralPath $logFile) {
        Get-Content -LiteralPath $logFile
    } else {
        Write-Host 'No log file found.' -ForegroundColor Gray
    }
    exit 0
}

$mutex = $null
$mutexOwned = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexOwned = $mutex.WaitOne(0)

    if (-not $mutexOwned) {
        Write-Host 'Campus VPN Guard is already running.' -ForegroundColor Yellow
        exit 0
    }
} catch {
    Write-Error "Failed to initialize single-instance guard: $($_.Exception.Message)"
    exit 1
}

try {
    Write-GuardLog '========================================' 'Green'
    Write-GuardLog 'Campus VPN Guard started.' 'Green'
    Write-GuardLog "Monitoring WiFi prefix from config." 'Cyan'
    Write-GuardLog "Poll interval: $pollIntervalSec seconds" 'Cyan'

    $currentSSID = Get-CurrentSSID
    $onCampus = Test-IsCampusNetwork -Ssid $currentSSID

    if ($onCampus) {
        Write-GuardLog 'Protected WiFi detected. Closing VPN client and exiting.' 'Yellow'
        $null = Stop-VpnClient
        exit 0
    }

    Write-GuardLog 'Protected WiFi not detected.' 'Green'
    Start-VpnClientIfNeeded
    Write-GuardLog 'Monitoring network changes.' 'Cyan'

    while ($true) {
        $ssid = Get-CurrentSSID
        if (Test-IsCampusNetwork -Ssid $ssid) {
            Write-GuardLog 'Protected WiFi detected. Closing VPN client and exiting.' 'Yellow'
            $null = Stop-VpnClient
            break
        }

        Start-Sleep -Seconds $pollIntervalSec
    }
} catch {
    Write-GuardLog "Main loop error: $($_.Exception.Message)" 'Red'
} finally {
    if ($mutexOwned -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }

    Write-GuardLog 'Campus VPN Guard stopped.' 'Yellow'
}

