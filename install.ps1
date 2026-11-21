# Installs MacDesk for the current user: copies it to %LOCALAPPDATA%\MacDesk,
# adds it to Windows startup and starts it. No admin rights needed.
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'MacDesk'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'MacDesk.ps1'), (Join-Path $PSScriptRoot 'Snow.cs') -Destination $target -Force
# files from a downloaded ZIP carry a "came from the internet" mark that can block them; clear it
Get-ChildItem $target -File | Unblock-File

$script = Join-Path $target 'MacDesk.ps1'
# conhost --headless starts PowerShell with no console window at all
# (-WindowStyle Hidden is ignored when Windows Terminal is the default terminal)
$psArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'

# start at sign-in through a per-user scheduled task (no admin needed). The Run key and the
# Startup folder get skipped when an earlier startup entry never finishes.
$user = "$env:USERDOMAIN\$env:USERNAME"
Register-ScheduledTask -TaskName 'MacDesk' -Force -Description 'Starts MacDesk at sign-in' `
    -Action (New-ScheduledTaskAction -Execute $conhost -Argument $psArgs) `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew) | Out-Null
# older versions used a Startup-folder shortcut or the Run key
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'MacDesk.lnk') -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name MacDesk -ErrorAction SilentlyContinue

Start-Process -FilePath $conhost -ArgumentList $psArgs
Write-Host "MacDesk installed to $target and added to startup."
Write-Host "Right-click the dock and pick Settings... to change the snow, dock and widget."
