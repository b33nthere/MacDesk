# Installs MacDesk for the current user: copies it to %LOCALAPPDATA%\MacDesk,
# adds it to Windows startup and starts it. No admin rights needed.
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'MacDesk'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'MacDesk.ps1') -Destination $target -Force

$script = Join-Path $target 'MacDesk.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'MacDesk.lnk'))
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = $psArgs
$lnk.WindowStyle = 7
$lnk.Description = 'MacDesk dock and widget'
$lnk.Save()

Start-Process -FilePath $lnk.TargetPath -ArgumentList $psArgs
Write-Host "MacDesk installed to $target and added to startup."
Write-Host "Right-click the dock to edit apps, restart or quit."
