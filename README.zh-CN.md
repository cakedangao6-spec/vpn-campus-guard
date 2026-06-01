# VPN Campus Guard

[English](README.md) | 简体中文

这是一个 Windows PowerShell 示例脚本，用于检测当前 WiFi 环境，并控制用户自行配置的 VPN 客户端。它适用于这样的场景：当电脑连接到指定前缀的受保护校园类 WiFi 时，自动关闭 VPN 客户端。

本仓库不包含任何 VPN 客户端、账号、配置文件、节点列表或私有配置。请自行安装 VPN 客户端，并填写自己的本地配置。

## 文件

- `CampusGuard.ps1` - 主 PowerShell 脚本
- `config.example.json` - 安全的示例配置
- `.gitignore` - 排除本地配置、日志、配置目录和客户端二进制文件

## 设置

1. 在 Windows 上安装你的 VPN 客户端。
2. 将 `config.example.json` 复制为 `config.json`。
3. 编辑 `config.json`，填写你自己的配置：
   - `campus_wifi_prefix`：触发保护的 WiFi 名称前缀
   - `vpn_exe_path`：你的 VPN 客户端可执行文件路径
   - `vpn_process_name`：不带 `.exe` 的进程名
   - `log_path`：日志文件路径；相对路径会从项目目录解析
   - `auto_start_vpn_when_off_campus`：未检测到受保护 WiFi 时，是否自动启动 VPN 客户端

## 使用

只检查状态，不启动或关闭 VPN 客户端：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1 -CheckOnly
```

启动保护脚本：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1
```

查看日志：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CampusGuard.ps1 -CheckLog
```

## 说明

- `config.json` 会被 git 忽略。
- 日志和 VPN 客户端文件会被 git 忽略。
- 脚本会优先使用 `Get-NetConnectionProfile`，然后回退到 `netsh wlan show interfaces`。
- 脚本不会上传遥测数据，也不会联系任何远程服务。
