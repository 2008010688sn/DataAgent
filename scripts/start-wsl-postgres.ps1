param(
    [string]$WslDistro = 'Ubuntu-24.04',
    [string]$HostName = '127.0.0.1',
    [int]$Port = 5433,
    [string]$Database = 'saa_data_agent',
    [string]$Username = 'postgres',
    [string]$Password = 'postgres'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logDir = Join-Path $repoRoot '.local\logs'
$pidFile = Join-Path $logDir 'wsl-postgres-keepalive.pid'
$stdout = Join-Path $logDir 'wsl-postgres-keepalive.log'
$stderr = Join-Path $logDir 'wsl-postgres-keepalive.err.log'

function Test-TcpPortFast([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Wait-TcpPort([string]$HostName, [int]$Port, [int]$MaxAttempts = 60) {
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        if (Test-TcpPortFast $HostName $Port) {
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "TCP port ${HostName}:$Port is not reachable."
}

function Stop-OldKeepalive {
    if (-not (Test-Path $pidFile)) {
        return
    }
    $processIdText = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    if (-not ($processIdText -match '^\d+$')) {
        return
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processIdText" -ErrorAction SilentlyContinue
    if ($process -and $process.Name -ieq 'wsl.exe' -and $process.CommandLine -match 'agentscope-wsl-postgres-keepalive') {
        Stop-Process -Id ([int]$processIdText) -Force -ErrorAction SilentlyContinue
    }
}

function Start-WslKeepalive {
    Stop-OldKeepalive
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $process = Start-Process wsl.exe -ArgumentList @(
        '-d', $WslDistro,
        '--',
        'bash',
        '-lc',
        'printf "agentscope-wsl-postgres-keepalive\n"; while true; do sleep 3600; done'
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $process.Id | Set-Content -Path $pidFile
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

& wsl.exe -d $WslDistro -u root -- bash -lc 'systemctl start postgresql 2>/dev/null || service postgresql start'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start PostgreSQL in WSL distro '$WslDistro'."
}

Start-WslKeepalive
Wait-TcpPort $HostName $Port

$readyOutput = & wsl.exe -d $WslDistro -- bash -lc "PGPASSWORD='$Password' psql -h 127.0.0.1 -p $Port -U '$Username' -d '$Database' -w -tAc 'select 1' 2>/dev/null"
if ($LASTEXITCODE -ne 0 -or (($readyOutput | Select-Object -First 1) -ne '1')) {
    throw "PostgreSQL started, but database '$Database' is not reachable with user '$Username'."
}

Write-Host "[start-wsl-postgres] Ready: jdbc:postgresql://${HostName}:$Port/$Database"
