# SkeletonKey

Outbound-only Mac-to-Windows remote input tool. Control your Windows PC's
mouse and keyboard from your Mac over the local network (or over the
internet via ngrok), toggled with a global hotkey.

## Why this exists

Most remote-desktop/KVM tools (TeamViewer, AnyDesk, Chrome Remote Desktop,
VNC, [Deskflow](https://github.com/deskflow/deskflow), the actively
maintained successor to Synergy/Barrier and my go-to before it got blocked,
etc.) work by installing and running a background *server* process on the
machine you're connecting to. That usually means admin rights to install,
often a firewall exception, and sometimes an account or license. On a
locked-down enterprise machine with limited permissions, that's often either
impossible or something IT ends up blocking outright. Not exactly what you
want just to share a mouse and keyboard between your own two machines
sitting next to each other.

SkeletonKey flips that. The Windows side is a small, self-contained `.exe`
you just run. No installer, no admin rights, no service, no account. It only
listens on a single TCP port and injects input locally; the Mac is the one
initiating the outbound connection. Nothing is exposed to the internet
unless you deliberately tunnel it out (e.g. via ngrok), and there's no
third-party server in the loop at all. It's a direct, private,
unauthenticated link between your own two machines. One key, any door.

## How to use it

### 1. Build both apps

Mac app bundle:
```bash
sh build-mac-app.sh
```

Windows app. Publish it once as a standalone `.exe` (no dotnet CLI or
console needed to actually run it afterwards):
```powershell
powershell -ExecutionPolicy Bypass -File build-windows-app.ps1
```
This produces `windows-injector\publish\SkeletonKey.exe`. From then on,
just double-click it, or make a shortcut on the Desktop, or in
`shell:startup` (Win+R, then `shell:startup`) to have it launch
automatically whenever you log in. Re-run the script any time you change
`windows-injector`'s code to republish it.

During development you can use `dotnet run --project .\windows-injector`
instead. It's faster than publishing but needs a terminal each time.

### 2. Start the Windows side

Double-click the published `.exe` (or `dotnet run` during development). A
small status window opens and a tray icon appears; it listens on port
`12653` by default. The status dot is orange ("Listening") until a Mac
connects and starts forwarding, then turns green ("Capturing"). Closing the
window just hides it back to the tray. Use the tray icon's right-click menu
to reopen it or quit.

To change the port: open the window, edit the **Port** field, click
**Apply**. This restarts the listener and remembers the new port for next
launch (stored in `%AppData%\SkeletonKey\settings.json`). Passing a port as
a command line argument (`SkeletonKey.exe 12653`) works too, as a
one-time override for that launch.

### 3. Start the Mac side

```bash
open build/SkeletonKey.app
```

A small window opens with an endpoint field (defaulting to
`192.168.0.100:12653` — edit it to your Windows PC's IP and port, or pick a
previously-used one from the dropdown) and a hotkey control (defaults to
**⌘⌥K**; click it and press a new shortcut to change). The app lives in the
menu bar; the Dock icon appears only while the control window is open.
Closing the window hides the Dock icon again but leaves the app running.
Double-click the menu bar icon to reopen the window, or single-click /
right-click for the status menu.

The first time it runs, grant `Accessibility` and `Input Monitoring` to
`SkeletonKey.app` if macOS prompts. Input Monitoring specifically doesn't
show an alert dialog, so if keyboard forwarding doesn't seem to work, check
System Settings > Privacy & Security > Input Monitoring and confirm it's
enabled there.

### 4. Take control

Enter the endpoint, then click **Start Forwarding** (or press the hotkey).
That both connects to the written/selected address and starts forwarding
once the link is up. Your Mac's mouse and keyboard then drive the Windows
PC instead of the Mac itself. The Mac's own cursor freezes and local input
is suppressed while this is active. Click **Stop Forwarding** or press the
hotkey again to hand control back to the Mac. The hotkey works globally, so
it doesn't matter which app is focused on the Mac when you press it.

### Connecting over the internet (ngrok)

Use this when the Mac can't reach the Windows PC directly (different
networks):

1. Start the Windows app (see above), noting its port.
2. Expose it: `ngrok tcp 12653`
3. On the Mac, enter the ngrok host and port in the endpoint field (e.g.
   `0.tcp.sa.ngrok.io:12653`) and click **Start Forwarding**.

## What gets forwarded

- Mouse movement, clicks, and scroll.
- Keyboard input, including international characters. Plain character keys
  (anything Shift or Option/AltGr produces, like `ñ` on a Spanish LatAm
  keyboard, or `\`/`|`/`@` which live behind AltGr on many non-US layouts)
  are translated using the Mac's current keyboard layout and typed on
  Windows as literal Unicode text, so they come through correctly regardless
  of the PC's own keyboard layout.
- Enter/Tab/arrows/function keys and Ctrl/Cmd shortcuts (copy/paste, etc.)
  are sent as real key presses rather than typed text, since those need to
  be recognized as that specific key. Cmd and Ctrl are forwarded as their
  own distinct Windows modifiers (Cmd to Windows key, Ctrl to Ctrl) rather
  than remapped to each other.

## Known limitations

- Alt/Option is deliberately not treated as a shortcut modifier, so Alt+F
  won't open a Windows menu. Option is too often used for typing ordinary
  characters on non-US Mac layouts to safely repurpose it.
- Raw media/system keys (brightness, volume, Mission Control, Dictation,
  etc.) aren't forwarded. Those arrive via a different macOS event mechanism
  the current capture doesn't listen to.
- Dead-key accent sequences (e.g. an acute-accent dead key followed by a
  vowel) are threaded through macOS's own composition state and should
  compose correctly, but this hasn't been exhaustively tested across
  layouts.
- The connection is unauthenticated. It's meant for a private link between
  two machines you own. Don't expose the listening port to an untrusted
  network without something like the ngrok approach above, which at least
  keeps the port off the open internet.

## Notes

- The Mac only initiates outbound TCP connections; the Windows side never
  connects out anywhere.
- The Mac build signs with a local `SkeletonKey Dev` certificate (created
  once into `~/Library/Keychains/skeletonkey.keychain-db`) so Accessibility
  and Input Monitoring grants survive rebuilds. Ad-hoc signing is not enough
  — macOS pins those grants to a per-build cdhash unless a real cert anchors
  the designated requirement. After the first signed build, grant both
  permissions once; later rebuilds should keep them.
- App icons live under `assets/` (`icon-1024.png` master, plus generated
  transparent `icon-mark-1024.png`, `AppIcon.icns`, and `SkeletonKey.ico`).
  Regenerate with `sh scripts/generate-icons.sh` after changing the master.
