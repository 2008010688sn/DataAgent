$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\\..")).Path
$bashScript = "/mnt/d/workspace/agentscope/.local/higress/autostart-higress.sh"
$logDir = Join-Path $PSScriptRoot "logs"
$logFile = Join-Path $logDir "autostart-windows.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
"[$(Get-Date -Format o)] Invoking WSL Higress autostart" | Out-File -FilePath $logFile -Append -Encoding utf8

$args = @("-d", "Ubuntu-24.04", "-u", "root", "-e", "bash", "-lc", "cd /mnt/d/workspace/agentscope && chmod +x '$bashScript' && '$bashScript'")
$process = Start-Process -FilePath "wsl.exe" -ArgumentList $args -WindowStyle Hidden -Wait -PassThru

"[$(Get-Date -Format o)] WSL Higress autostart exited with code $($process.ExitCode)" | Out-File -FilePath $logFile -Append -Encoding utf8
exit $process.ExitCode
