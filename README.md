# MacDesk

A macOS-style dock and a clean desktop widget for Windows 11. It's one PowerShell script with nothing to install and no dependencies.

![MacDesk screenshot](docs/screenshot.png)

## Features

**Dock**
- Icons magnify when you hover, neighbours included, like the macOS dock
- An app name bubble appears above the hovered icon
- A dot under the icon shows apps that are running
- Click to launch an app, or switch to it if it's already open
- Works with classic apps, Microsoft Store apps and Steam games
- **Hides automatically while a game or video runs fullscreen**

**Widget**
- Large clock and date in your system language
- Live CPU, RAM, GPU usage with temperature (NVIDIA) and disk space bars
- Sits on the desktop, so it never covers your windows

**Other**
- Builds the dock from your installed apps on first run
- Text in English, or Czech on Czech systems
- Light on resources: one PowerShell process, no background services

## Install

1. Download or clone this repository.
2. Right-click `install.ps1` and choose **Run with PowerShell**.

MacDesk is copied to `%LOCALAPPDATA%\MacDesk` and added to startup. Admin rights aren't needed.

For the full macOS look, also:
- turn on **Settings → Personalization → Taskbar → Taskbar behaviors → Automatically hide the taskbar**
- right-click the desktop and choose **View → uncheck Show desktop icons**

## Configure the dock

Right-click the dock and pick **Edit dock apps…**. This opens `apps.json`. Each entry looks like this:

```json
{ "name": "Discord", "appid": "com.squirrel.Discord.Discord", "proc": "Discord" }
```

| Field | Meaning |
|---|---|
| `name` | Label shown on hover |
| `appid` | App ID from `Get-StartApps` in PowerShell, or a full path to an `.exe` |
| `proc` | Process name, used for the running dot and for switching to the app (optional) |
| `icon` + `run` | For games and URLs: an icon source (`.exe`) and what to launch (e.g. `steam://rungameid/...`) |

See [`apps.example.json`](apps.example.json). After editing, right-click the dock and pick **Restart MacDesk**.

To find app IDs, run:

```powershell
Get-StartApps | Sort-Object Name
```

## Uninstall

Run `uninstall.ps1`. It stops MacDesk, removes it from startup and deletes `%LOCALAPPDATA%\MacDesk`.

## Notes

- The script starts with `-ExecutionPolicy Bypass`, which lets this one local script run without changing your system-wide PowerShell policy. Read the code before running it, as you should with any script.
- GPU stats need an NVIDIA card (`nvidia-smi` ships with the driver). Without one, the GPU row is hidden.
- Tested on Windows 11 24H2 with Windows PowerShell 5.1.

## License

[MIT](LICENSE)
