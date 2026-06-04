param(
    [string]$WslDistro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logDir = Join-Path $repoRoot '.local\logs'

function ConvertTo-WslPath([string]$Path) {
    $resolved = (Resolve-Path $Path).Path
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$tail"
    }
    throw "Cannot convert Windows path to WSL path: $resolved"
}

function ConvertTo-BashLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Stop-OldKeepalive {
    $pidFile = Join-Path $logDir 'wsl-keepalive.pid'
    if (-not (Test-Path $pidFile)) {
        return
    }

    $processIdText = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    if (-not ($processIdText -match '^\d+$')) {
        return
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processIdText" -ErrorAction SilentlyContinue
    if ($process -and $process.Name -ieq 'wsl.exe' -and $process.CommandLine -match 'agentscope-start-local-keepalive') {
        Stop-Process -Id ([int]$processIdText) -Force -ErrorAction SilentlyContinue
    }
}

function Start-WslKeepalive {
    Stop-OldKeepalive

    $stdout = Join-Path $logDir 'wsl-keepalive.log'
    $stderr = Join-Path $logDir 'wsl-keepalive.err.log'
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    $process = Start-Process wsl.exe -ArgumentList @(
        '-d', $WslDistro,
        '--',
        'bash',
        '-lc',
        'printf "agentscope-start-local-keepalive\n"; while true; do sleep 3600; done'
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru

    $process.Id | Set-Content -Path (Join-Path $logDir 'wsl-keepalive.pid')
    Write-Host "[prepare-wsl-postgres] WSL keepalive PID: $($process.Id)"
}

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

function Wait-TcpPortStable([string]$HostName, [int]$Port, [int]$StableChecks = 3, [int]$MaxAttempts = 60) {
    $stable = 0
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        if (Test-TcpPortFast $HostName $Port) {
            $stable++
            if ($stable -ge $StableChecks) {
                return
            }
        }
        else {
            $stable = 0
        }
        Start-Sleep -Seconds 1
    }
    throw "TCP port ${HostName}:$Port did not stay reachable."
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-WslKeepalive

$wslRepoRoot = ConvertTo-BashLiteral (ConvertTo-WslPath $repoRoot)
$command = "cd $wslRepoRoot && sed -i 's/\r$//' scripts/wsl-deploy-env.sh 2>/dev/null || true; bash scripts/wsl-deploy-env.sh"
& wsl.exe -d $WslDistro -- bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "WSL PostgreSQL preparation failed with exit code $LASTEXITCODE"
}

Wait-TcpPortStable 127.0.0.1 5433
Write-Host '[prepare-wsl-postgres] Ready: jdbc:postgresql://127.0.0.1:5433/saa_data_agent'
