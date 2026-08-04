<p align="center">
  <img src="assets/icon-1024.png" alt="SkeletonKey" width="128">
</p>

# SkeletonKey

Share a Mac keyboard and mouse with a Windows PC on your desk. The PC runs a
small listener; the Mac connects out. No installer, no account, no inbound
holes on the Mac. Handy when the work laptop won't let you install a real
KVM or remote-desktop agent.

## Quick start

```bash
sh build-mac-app.sh
# -> build/SkeletonKey.app
```

```powershell
powershell -ExecutionPolicy Bypass -File build-windows-app.ps1
# -> windows-injector\publish\SkeletonKey.exe
```

1. Run `SkeletonKey.exe` on the PC (listens on `12653` by default).
2. Open `SkeletonKey.app` on the Mac. Grant **Accessibility** and **Input
   Monitoring**. Input Monitoring has no prompt; turn it on under Privacy &
   Security if keys don't forward.
3. Set **Endpoint** to `pc-hostname-or-ip:12653`, then **Start Forwarding**
   (or **⌘⌥K**).

While forwarding, Mac input drives the PC. Stop with the same button or
hotkey. Status colors: orange = idle / connecting, green = active, red =
error.

## Day to day

| | |
| --- | --- |
| Hotkey | Default **⌘⌥K**. Unlock the row to record a new combo (needs ⌘ ⌥ ⌃ or ⇧). |
| ⌘ as Ctrl | Enable **Invert ⌘ and ⌃** for Mac-style copy/paste on Windows. |
| Clipboard | Plain text both ways while forwarding; flushed on Start/Stop. |
| Remote PC | `ngrok tcp 12653`, then point the Mac at the ngrok `host:port`. |
| Windows tray | Close hides to tray. Port is under Edit / Apply. |
| Login (tray) | Shortcut target: `"...\SkeletonKey.exe" --minimized` |
| Login (admin) | Tray → **Enable elevated startup at login...** (one UAC, then silent). Needed for elevated apps; still can't click the UAC dialog itself. |

## Limits

- Letter keys are sent as typed characters so Mac layouts work, not as physical
  key presses. That breaks games that bind WASD, jump, and similar. Enter,
  Space, and arrows are real keys, but many games still ignore injected input
  (Raw Input, anti-cheat, or an elevated game without an elevated listener).
- Option/Alt isn't a Windows shortcut modifier (kept so punctuation still
  types).
- No media / Mission Control / brightness keys.
- Unauthenticated TCP. Use a LAN or a tunnel you trust; don't expose the port.

## Build notes

Mac builds use a stable local **SkeletonKey Dev** cert so TCC grants survive
rebuilds. Icons: edit `assets/icon-1024.png`, then
`sh scripts/generate-icons.sh`. Windows day-to-day: `dotnet run --project .\windows-injector`.
