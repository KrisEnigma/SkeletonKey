<p align="center">
  <img src="assets/MenuBarIcon.png" alt="SkeletonKey" width="128">
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

## Limits

- UAC: the Yes/No elevation prompt can't be clicked remotely. Windows puts
  it on a secure desktop; use the PC's own mouse/keyboard for that dialog.
- Games: letter keys arrive as typed text, not physical presses, so WASD and
  similar binds don't work. Many titles also ignore injected input entirely.
- Option+letter types Mac punctuation; it doesn't do Windows Alt+letter menu
  shortcuts. Alt+Tab / Alt+F4 still work.
- No media / Mission Control / brightness keys.
- Unauthenticated TCP. Use a LAN or a tunnel you trust; don't expose the port.

## Build notes

Mac builds use a stable local **SkeletonKey Dev** cert so TCC grants survive
rebuilds. Windows day-to-day: `dotnet run --project .\windows-injector`.
