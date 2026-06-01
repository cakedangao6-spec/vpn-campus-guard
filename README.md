# VPN Campus Guard

A Windows PowerShell sample that detects the current WiFi environment and controls a user-configured VPN client. It is designed for cases where a VPN client should be closed automatically when the computer connects to a protected campus-style WiFi network.

This repository does not include any VPN client, account, profile, node list, or private configuration. Install your own VPN client separately and fill in your own local settings.

## Files

- `CampusGuard.ps1` - main PowerShell script
- `config.example.json` - safe example configuration
- `.gitignore` - excludes local config, logs, profiles, and client binaries

## Setup

1. Install your VPN client on Windows.
2. Copy `config.example.json` to `config.json`.
3. Edit `config.json` with your own values:
   - `campus_wifi_prefix`: WiFi name prefix that should trigger protection
   - `vpn_exe_path`: local path to your VPN client executable
   - `vpn_process_name`: process name without `.exe`
   - `log_path`: log file path; relative paths are resolved from this project folder
   - `auto_start_vpn_when_off_campus`: whether to start the VPN client when protected WiFi is not detected

## Usage

Run a status check without starting or closing the VPN client:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1 -CheckOnly
```

Start the guard:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1
```

Show logs:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1 -CheckLog
```

## Notes

- `config.json` is intentionally ignored by git.
- Logs and VPN client files are intentionally ignored by git.
- The script uses `Get-NetConnectionProfile` first, then falls back to `netsh wlan show interfaces`.
- The script does not upload telemetry or contact any remote service.
