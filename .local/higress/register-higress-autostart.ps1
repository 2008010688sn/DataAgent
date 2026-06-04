$ErrorActionPreference = "Stop"

$taskName = "Agentscope Higress Autostart"
$scriptPath = Join-Path $PSScriptRoot "autostart-higress.ps1"

if (-not (Test-Path $scriptPath)) {
  throw "Missing autostart script: $scriptPath"
}

$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal `
  -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive `
  -RunLevel Limited

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "Start the local Agentscope Higress AI Gateway stack in WSL after Windows logon." `
  -Force | Out-Null

Write-Host "Registered scheduled task: $taskName"
