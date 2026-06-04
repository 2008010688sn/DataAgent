# Forward a local port on Windows to a LAN PostgreSQL host so WSL backend can reach it.
# Usage (Admin PowerShell):
#   .\scripts\wsl-lan-db-proxy.ps1
#   .\scripts\wsl-lan-db-proxy.ps1 -ListenPort 15433 -RemoteHost 192.168.12.100 -RemotePort 15432
param(
    [string]$ListenAddress = '0.0.0.0',
    [int]$ListenPort = 15433,
    [string]$RemoteHost = '192.168.12.100',
    [int]$RemotePort = 15432
)

$ErrorActionPreference = 'Stop'
$ruleName = "DataAgent WSL LAN DB Proxy $ListenPort"

function Write-Step([string]$Message) {
    Write-Host "[lan-db-proxy] $Message"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this script in an elevated (Administrator) PowerShell.'
}

Write-Step 'Ensuring IP Helper service (iphlpsvc) is running for portproxy ...'
$ipHelper = Get-Service iphlpsvc
if ($ipHelper.Status -ne 'Running') {
    Set-Service iphlpsvc -StartupType Automatic
    Start-Service iphlpsvc
}
Write-Step "IP Helper status: $((Get-Service iphlpsvc).Status)"

Write-Step "Checking remote target ${RemoteHost}:${RemotePort} ..."
$remote = Test-NetConnection -ComputerName $RemoteHost -Port $RemotePort -WarningAction SilentlyContinue
if (-not $remote.TcpTestSucceeded) {
    throw "Windows cannot reach ${RemoteHost}:${RemotePort}. Fix VPN/firewall or remote DB first."
}

Write-Step 'Clearing old portproxy rules for this listen port ...'
netsh interface portproxy show all | Select-String ":$ListenPort\b" | ForEach-Object {
    if ($_ -match '(\S+)\s+(\S+)\s+(\S+)\s+(\S+)') {
        netsh interface portproxy delete v4tov4 listenaddress=$($Matches[1]) listenport=$($Matches[2]) | Out-Null
    }
}

Write-Step "Adding portproxy ${ListenAddress}:${ListenPort} -> ${RemoteHost}:${RemotePort}"
netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectaddress=$RemoteHost connectport=$RemotePort | Out-Null

$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
    Write-Step "Adding firewall rule for TCP $ListenPort"
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ListenPort | Out-Null
}

Write-Step 'Current portproxy entries:'
netsh interface portproxy show all

Write-Host ''
Write-Host "WSL datasource host/port should use: 127.0.0.1 / $ListenPort"
Write-Host "Then restart backend and re-test datasource connection."
