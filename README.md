<p align="center">
  <img src="assets/icon-1024.png" alt="SkeletonKey" width="128">
</p>

# SkeletonKey

Outbound-only Mac-to-Windows remote input. Control your PC mouse and keyboard
from your Mac over the local network (or over the internet with ngrok),
toggled with a global hotkey.

## Why this exists

Most remote-desktop and KVM tools (TeamViewer, AnyDesk, Chrome Remote
Desktop, VNC, [Deskflow](https://github.com/deskflow/deskflow), etc.) install
a background server on the machine you want to control. That usually means
admin rights, a firewall exception, and sometimes an account. On a
locked-down work PC, IT often blocks that, which is a lot of friction just to
share a keyboard and mouse between two machines on your desk.

SkeletonKey works the other way around. The Windows side is a small
self-contained `.exe` you run: no installer, no admin, no service, no
account. It listens on one TCP port and injects input locally. The Mac opens
the outbound connection. Nothing hits the internet unless you tunnel it
yourself (for example with ngrok), and there is no third-party relay.

## How to use it

### 1. Build both apps

**Mac**
```bash
sh build-mac-app.sh
```
Builds `build/SkeletonKey.app`, signed with a local `SkeletonKey Dev`
certificate so Accessibility and Input Monitoring grants survive rebuilds.

**Windows** (standalone `.exe`; no .NET runtime or console needed afterward):
```powershell
powershell -ExecutionPolicy Bypass -File build-windows-app.ps1
```
Builds `windows-injector\publish\SkeletonKey.exe`. Double-click it, or put a
shortcut in `shell:startup` for tray-only login start:

```text
"C:\path\to\SkeletonKey.exe" --minimized
```

For elevated login **without** a UAC prompt every boot (needed for clicks
into elevated Windows apps): open the tray menu and choose **Enable
elevated startup at login…** (one UAC prompt). That registers a Task
Scheduler logon task which starts `SkeletonKey.exe --minimized` with
highest privileges. Remove any `shell:startup` shortcut afterward so you
don't get two instances. Disable later from the same tray menu.

`--admin` still works for a one-shot elevate (UAC each launch). Prefer the
startup task for day-to-day.

Re-run the script after changing Windows code.

For day-to-day development, `dotnet run --project .\windows-injector` is
faster but needs a terminal each time.

### 2. Start the Windows side

Run `SkeletonKey.exe`. A small status window opens and a tray icon appears.
It listens on port `12653` by default.

| Color | Meaning |
| --- | --- |
| Orange | Listening, or connected but idle |
| Green | Capturing (Mac is actively forwarding) |
| Red | Stopped or error |

Closing the window hides it to the tray. Use the tray menu to reopen or quit.

To change the port: edit **Port**, click **Apply**. The new port is saved in
`%AppData%\SkeletonKey\settings.json`. You can also pass a one-shot override:
`SkeletonKey.exe 12653`.

### 3. Start the Mac side

```bash
open build/SkeletonKey.app
```

The app lives in the menu bar. The Dock icon only shows while the control
window is open. Double-click the menu bar icon to reopen the window;
single-click or right-click for the status menu.

**Permissions (first launch).** Grant Accessibility and Input Monitoring to
`SkeletonKey.app`. Input Monitoring does not show a system alert. If
keyboard forwarding fails, check System Settings > Privacy & Security >
Input Monitoring, enable it, then relaunch.

### 4. Connect and take control

In the control window:

1. Set **Endpoint** to your PC's `host:port` (default
   `192.168.0.100:12653`), or pick a recent one from the dropdown.
2. Optionally lock the endpoint so you do not edit it by accident.
3. Click **Start Forwarding** (or press the hotkey). That connects to the
   endpoint and starts forwarding once the link is up.

While forwarding, the Mac cursor freezes and local input is suppressed; the
PC is driven instead. **Stop Forwarding** or the hotkey again returns
control to the Mac.

| Color | Meaning |
| --- | --- |
| Orange | Off, connecting, or reconnecting |
| Green | Forwarding |

The Mac has no separate "connected but idle" mode. Connect and forward are
the same action.

### Hotkey

Default: **⌘⌥K**. Works globally, no matter which app is focused.

To change it: unlock the hotkey row, click the shortcut field, then press a
new combination that includes at least one modifier (⌘ ⌥ ⌃ or ⇧). Esc
cancels. After a successful change it locks again.

### Connecting over the internet (ngrok)

When the Mac cannot reach the PC directly:

1. Start the Windows app and note its port.
2. `ngrok tcp 12653`
3. On the Mac, set the endpoint to the ngrok host/port (for example
   `0.tcp.sa.ngrok.io:12653`) and click **Start Forwarding**.

## What gets forwarded

- Mouse movement, clicks, and scroll
- Keyboard input, including international characters. Plain character keys
  (Shift / Option / AltGr output such as `ñ`, `\`, `|`, `@`) are translated
  with the Mac's layout and typed on Windows as Unicode text.
- Enter, Tab, arrows, function keys, and Ctrl/Cmd shortcuts as real key
  events. By default Cmd becomes the Windows key and Ctrl stays Ctrl. Check
  **Invert ⌘ and ⌃** on the Mac if you prefer Mac-style shortcuts (⌘C copy)
  while forwarding.
- Plain text clipboard both ways while forwarding. On Stop, the Mac
  explicitly requests the PC clipboard so you can paste after you return.
  On Start, the Mac clipboard is pushed to the PC. Text only (not images
  or files).

## Known limitations

- Option/Alt is not treated as a shortcut modifier, so Alt+F will not open a
  Windows menu. On many Mac layouts Option is needed for ordinary characters.
- Media and system keys (brightness, volume, Mission Control, Dictation,
  etc.) are not forwarded.
- Dead-key accent sequences should compose via macOS's own state, but this
  is not exhaustively tested across every layout.
- The Windows listener cannot click the UAC consent dialog (secure desktop).
  Clicks into elevated apps need SkeletonKey elevated too — use tray
  **Enable elevated startup at login…** (one UAC, then silent elevated
  starts) rather than `--admin` on every boot.
- The link is unauthenticated. Keep it on a private network, or use
  something like ngrok so the port is not open to the public internet.
  Clipboard text crosses that same link during forwarding and the
  Start/Stop handoff.

## Notes

- The Mac only opens outbound TCP. Windows never connects out.
- Mac builds sign with `SkeletonKey Dev` in
  `~/Library/Keychains/skeletonkey.keychain-db`. Ad-hoc signing is not
  enough: macOS pins TCC grants to a per-build cdhash unless a real cert
  anchors the designated requirement. Grant Accessibility and Input
  Monitoring once after the first signed build; later rebuilds should keep
  them.
- Icons live under `assets/` (`icon-1024.png` master, plus generated
  `icon-mark-1024.png`, `AppIcon.icns`, `SkeletonKey.ico`). Regenerate with
  `sh scripts/generate-icons.sh` after changing the master.
