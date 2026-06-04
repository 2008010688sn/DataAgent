# Start DataAgent locally on Windows with PostgreSQL initialized in WSL.
param(
    [int]$FrontendPort = 5174,
    [string]$WslDistro = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logDir = Join-Path $repoRoot '.local\logs'
$backendPort = 8065

function Write-Step([string]$Message) {
    Write-Host "[start-local] $Message"
}

function Get-WslDistroName {
    if ($WslDistro) {
        return $WslDistro
    }

    $tempFile = New-TemporaryFile
    try {
        & cmd.exe /d /s /c "wsl.exe -l -q > `"$($tempFile.FullName)`"" 2>$null
        $bytes = [System.IO.File]::ReadAllBytes($tempFile.FullName)
        $output = [System.Text.Encoding]::Unicode.GetString($bytes)
        $distros = $output -split "`r?`n" |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ }
    }
    finally {
        Remove-Item -LiteralPath $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }

    if (-not $distros -or $distros.Count -eq 0) {
        throw 'No WSL distro found. Install Ubuntu in WSL first, then rerun this script.'
    }
    return $distros[0]
}

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

function ConvertTo-PowerShellSingleQuotedLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) {
        return
    }

    foreach ($line in (Get-Content $Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $trimmed.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Get-EnvValue([string]$Name, [string]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Invoke-WslBash([string]$Distro, [string]$Command) {
    & wsl.exe -d $Distro -- bash -lc $Command
}

function Get-WslPostgresPort([string]$Distro) {
    $clusterLines = Invoke-WslBash $Distro 'pg_lsclusters --no-header 2>/dev/null || true'
    $port = $null
    foreach ($line in $clusterLines) {
        $parts = ($line -split '\s+') | Where-Object { $_ }
        if ($parts.Count -ge 4 -and $parts[3] -eq 'online') {
            $port = $parts[2]
            break
        }
        if (-not $port -and $parts.Count -ge 3) {
            $port = $parts[2]
        }
    }
    if (-not $port) {
        $port = '5432'
    }
    return $port
}

function Get-WslIPv4Addresses([string]$Distro) {
    $raw = Invoke-WslBash $Distro 'hostname -I 2>/dev/null || true'
    $addresses = @()
    foreach ($ip in (($raw -join ' ') -split '\s+')) {
        if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            continue
        }
        if ($ip -match '^169\.254\.') {
            continue
        }
        if ($ip -match '^(10\.255\.255\.254|172\.(1[6-9]|2\d|3[01])\.|172\.17\.|172\.18\.|172\.19\.)') {
            continue
        }
        $addresses += $ip
    }
    return $addresses | Select-Object -Unique
}

function Resolve-PostgresHost([string]$Distro, [int]$Port) {
    try {
        Wait-TcpPortStable 127.0.0.1 $Port 2 20
        return '127.0.0.1'
    }
    catch {
    }

    foreach ($candidate in (Get-WslIPv4Addresses $Distro)) {
        try {
            Wait-TcpPortStable $candidate $Port 2 6
            return $candidate
        }
        catch {
        }
    }

    Wait-TcpPortStable 127.0.0.1 $Port
    return '127.0.0.1'
}

function Get-MavenCommand {
    $wrapper = Join-Path $repoRoot 'mvnw.cmd'
    if (Test-Path $wrapper) {
        return $wrapper
    }

    $cached = Get-ChildItem -Path "$env:USERPROFILE\.m2\wrapper\dists" -Recurse -Filter mvn.cmd -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -First 1
    if ($cached) {
        return $cached.FullName
    }
    throw 'Maven wrapper was not found.'
}

function Get-NpmCommand {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($candidate in @('D:\Program Files\nodejs\npm.cmd', 'C:\Program Files\nodejs\npm.cmd')) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Stop-PortListener([int]$Port) {
    $processIds = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($processId in $processIds) {
        if ($processId -gt 0) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            Write-Step "Stopped Windows process $processId on port $Port"
        }
    }
}

function Stop-WslPortListeners([string]$Distro, [int[]]$Ports) {
    $portArgs = ($Ports | ForEach-Object { "$_/tcp" }) -join ' '
    $command = @"
if command -v fuser >/dev/null 2>&1; then
  fuser -k $portArgs >/dev/null 2>&1 || true
fi
pkill -f 'spring-boot:run.*data-agent-managemen[t]' >/dev/null 2>&1 || true
pkill -f 'DataAgentApplicatio[n]' >/dev/null 2>&1 || true
"@
    $job = Start-Job -ScriptBlock {
        param($DistroName, $BashCommand)
        & wsl.exe -d $DistroName -- bash -lc $BashCommand
    } -ArgumentList $Distro, $command
    if (-not (Wait-Job $job -Timeout 20)) {
        Stop-Job $job -Force
        Write-Warning 'Timed out while cleaning WSL backend/frontend listeners; continuing with Windows listener cleanup.'
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

function Stop-WslKeepalive {
    $pidFile = Join-Path $logDir 'wsl-keepalive.pid'
    if (-not (Test-Path $pidFile)) {
        return
    }

    $processIdText = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    if (-not ($processIdText -match '^\d+$')) {
        return
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processIdText" -ErrorAction SilentlyContinue
    if ($process -and $process.Name -ieq 'wsl.exe' -and $process.CommandLine -match 'agentscope-start-local-keepalive') {
        Stop-Process -Id ([int]$processIdText) -Force -ErrorAction SilentlyContinue
        Write-Step "Stopped old WSL keepalive process $processIdText"
    }
}

function Start-WslKeepalive([string]$Distro) {
    Stop-WslKeepalive

    $stdout = Join-Path $logDir 'wsl-keepalive.log'
    $stderr = Join-Path $logDir 'wsl-keepalive.err.log'
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    $process = Start-Process wsl.exe -ArgumentList @(
        '-d', $Distro,
        '--',
        'bash',
        '-lc',
        'printf "agentscope-start-local-keepalive\n"; while true; do sleep 3600; done'
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru

    $process.Id | Set-Content -Path (Join-Path $logDir 'wsl-keepalive.pid')
    Write-Step "WSL keepalive PID: $($process.Id)"
    Start-Sleep -Seconds 2
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

function Wait-TcpPortStable([string]$HostName, [int]$Port, [int]$StableChecks = 5, [int]$MaxAttempts = 120) {
    $stable = 0
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $ok = Test-TcpPortFast $HostName $Port
        if ($ok) {
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
    throw "TCP port ${HostName}:$Port did not stay reachable after $MaxAttempts attempts."
}

function Start-HiddenPowerShell([string]$Command, [string]$StdOutPath, [string]$StdErrPath) {
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    Start-Process powershell -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded
    ) -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath -WindowStyle Hidden -PassThru
}

function Wait-Backend([string]$LogPath, [string]$ErrPath) {
    for ($i = 0; $i -lt 240; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$backendPort/api/agent/list" -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return $true
            }
        }
        catch {
            if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern 'BUILD FAILURE|APPLICATION FAILED' -Quiet -ErrorAction SilentlyContinue)) {
                return $false
            }
            if ((Test-Path $ErrPath) -and (Select-String -Path $ErrPath -Pattern 'BUILD FAILURE|APPLICATION FAILED' -Quiet -ErrorAction SilentlyContinue)) {
                return $false
            }
            if ($i -gt 0 -and $i % 30 -eq 0) {
                Write-Step "Still waiting for backend health... attempt $i"
            }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Wait-Frontend([int]$Port, [string]$LogPath, [string]$ErrPath) {
    for ($i = 0; $i -lt 90; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return $true
            }
        }
        catch {
            if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern 'Error|EADDRINUSE|failed' -Quiet -ErrorAction SilentlyContinue)) {
                return $false
            }
            if ((Test-Path $ErrPath) -and (Select-String -Path $ErrPath -Pattern 'Error|EADDRINUSE|failed' -Quiet -ErrorAction SilentlyContinue)) {
                return $false
            }
            if ($i -gt 0 -and $i % 15 -eq 0) {
                Write-Step "Still waiting for frontend health... attempt $i"
            }
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Import-DotEnv (Join-Path $repoRoot '.env')

$wslDistroName = Get-WslDistroName
$wslRepoRoot = ConvertTo-WslPath $repoRoot
Write-Step "Using WSL distro: $wslDistroName"

Write-Step "Stopping old backend/frontend listeners on $backendPort and $FrontendPort..."
Stop-WslPortListeners $wslDistroName @($backendPort, $FrontendPort)
Start-Sleep -Seconds 2
Stop-PortListener $backendPort
Stop-PortListener $FrontendPort
Start-Sleep -Seconds 2

Write-Step 'Keeping WSL alive for PostgreSQL localhost forwarding...'
Start-WslKeepalive $wslDistroName

Write-Step 'Ensuring WSL PostgreSQL and importing converted PostgreSQL seed data...'
$wslRepoRootArg = ConvertTo-BashLiteral $wslRepoRoot
$deployCommand = "cd $wslRepoRootArg && sed -i 's/\r$//' scripts/wsl-deploy-env.sh 2>/dev/null || true; bash scripts/wsl-deploy-env.sh"
Invoke-WslBash $wslDistroName $deployCommand | Write-Host

$wslPgPort = Get-WslPostgresPort $wslDistroName
Write-Step "Detecting Windows-reachable WSL PostgreSQL address on port $wslPgPort..."
$wslPgHost = Resolve-PostgresHost $wslDistroName $wslPgPort
Write-Step "Using WSL PostgreSQL from Windows: ${wslPgHost}:$wslPgPort"

$jdbc = "jdbc:postgresql://${wslPgHost}:${wslPgPort}/saa_data_agent"
$mavenCmd = Get-MavenCommand
$npmCmd = Get-NpmCommand
$langfuseEnabled = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'LANGFUSE_ENABLED' 'true')
$langfuseHost = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'LANGFUSE_HOST' 'http://127.0.0.1:3000')
$langfusePublicKey = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'LANGFUSE_PUBLIC_KEY' '')
$langfuseSecretKey = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'LANGFUSE_SECRET_KEY' '')
$agentscopeObservabilityEnabled = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'AGENTSCOPE_OBSERVABILITY_ENABLED' 'true')
$agentscopeUseLangfuseTracer = ConvertTo-PowerShellSingleQuotedLiteral (Get-EnvValue 'AGENTSCOPE_OBSERVABILITY_USE_LANGFUSE_TRACER' 'true')

$backendLog = Join-Path $logDir 'backend-windows.log'
$backendErr = Join-Path $logDir 'backend-windows.err.log'
$frontendLog = Join-Path $logDir 'frontend-windows.log'
$frontendErr = Join-Path $logDir 'frontend-windows.err.log'
Remove-Item -LiteralPath $backendLog, $backendErr, $frontendLog, $frontendErr -Force -ErrorAction SilentlyContinue

$backendCmd = @"
`$ErrorActionPreference = 'Stop'
`$env:DATA_AGENT_DATASOURCE_URL = '$jdbc'
`$env:DATA_AGENT_DATASOURCE_USERNAME = 'postgres'
`$env:DATA_AGENT_DATASOURCE_PASSWORD = 'postgres'
`$env:DATA_AGENT_DATASOURCE_SQL_INIT = 'never'
`$env:LANGFUSE_ENABLED = $langfuseEnabled
`$env:LANGFUSE_HOST = $langfuseHost
`$env:LANGFUSE_PUBLIC_KEY = $langfusePublicKey
`$env:LANGFUSE_SECRET_KEY = $langfuseSecretKey
`$env:AGENTSCOPE_OBSERVABILITY_ENABLED = $agentscopeObservabilityEnabled
`$env:AGENTSCOPE_OBSERVABILITY_USE_LANGFUSE_TRACER = $agentscopeUseLangfuseTracer
`$env:SERVER_ADDRESS = '127.0.0.1'
Set-Location '$repoRoot'
& '$mavenCmd' -pl data-agent-management spring-boot:run '-Dmaven.test.skip=true' '-Dspotless.skip=true' '-Dcheckstyle.skip=true' '-Djacoco.skip=true'
"@

Write-Step 'Starting backend on Windows...'
$backendProcess = Start-HiddenPowerShell $backendCmd $backendLog $backendErr
$backendProcess.Id | Set-Content -Path (Join-Path $logDir 'backend-windows.pid')
Write-Step "Backend launcher PID: $($backendProcess.Id)"

if ($npmCmd -and (Test-Path (Join-Path $repoRoot 'data-agent-frontend\package.json'))) {
    $frontendCmd = @"
`$ErrorActionPreference = 'Stop'
Set-Location '$repoRoot\data-agent-frontend'
& '$npmCmd' run dev -- --port $FrontendPort --host 127.0.0.1
"@
    Write-Step 'Starting frontend on Windows...'
    $frontendProcess = Start-HiddenPowerShell $frontendCmd $frontendLog $frontendErr
    $frontendProcess.Id | Set-Content -Path (Join-Path $logDir 'frontend-windows.pid')
    Write-Step "Frontend launcher PID: $($frontendProcess.Id)"
}
else {
    Write-Warning 'npm or data-agent-frontend/package.json was not found; backend startup will continue without frontend.'
}

Write-Step 'Waiting for backend health...'
if (-not (Wait-Backend $backendLog $backendErr)) {
    Write-Warning "Backend did not become ready. Last backend log lines:"
    if (Test-Path $backendLog) {
        Get-Content $backendLog -Tail 80
    }
    if (Test-Path $backendErr) {
        Get-Content $backendErr -Tail 80
    }
    throw "Backend startup failed or timed out. Logs: $backendLog, $backendErr"
}

Write-Step 'Backend ready.'

if ($npmCmd -and (Test-Path (Join-Path $repoRoot 'data-agent-frontend\package.json'))) {
    Write-Step 'Waiting for frontend health...'
    if (-not (Wait-Frontend $FrontendPort $frontendLog $frontendErr)) {
        Write-Warning "Frontend did not become ready. Last frontend log lines:"
        if (Test-Path $frontendLog) {
            Get-Content $frontendLog -Tail 80
        }
        if (Test-Path $frontendErr) {
            Get-Content $frontendErr -Tail 80
        }
        throw "Frontend startup failed or timed out. Logs: $frontendLog, $frontendErr"
    }
    Write-Step 'Frontend ready.'
}

Write-Host ''
Write-Host "Frontend: http://127.0.0.1:$FrontendPort/"
Write-Host "Backend : http://127.0.0.1:$backendPort/"
Write-Host "Swagger : http://127.0.0.1:$backendPort/swagger-ui.html"
Write-Host "Logs    : $logDir"
