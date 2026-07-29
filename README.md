# KrisKVM

Outbound-only Mac-to-Windows remote input tool: control your Windows PC's
mouse and keyboard from your Mac over the local network (or over the
internet via ngrok), toggled with a global hotkey.

## Why this exists

Most remote-desktop/KVM tools (TeamViewer, AnyDesk, Chrome Remote Desktop,
VNC, etc.) work by installing and running a background *server* process on
the machine you're connecting to, usually requiring admin rights to install,
often needing a firewall exception, and sometimes needing an account/license.
On a locked-down enterprise machine with limited permissions, that's often
either impossible or something you don't want to ask IT to approve just to
share a mouse and keyboard between your own two machines sitting next to
each other.

KrisKVM flips that: the Windows side is a small, self-contained `.exe` you
can just run — no installer, no admin rights, no service, no account. It
only ever listens on a single TCP port and injects input locally; the Mac
is the one initiating the outbound connection. Nothing is exposed to the
internet unless you deliberately tunnel it out (e.g. via ngrok), and there's
no third-party server involved in the connection at all — it's a direct,
private, unauthenticated link between your own two machines.

## How to use it

### 1. Build both apps

Mac app bundle:
```bash
sh build-mac-app.sh
```

Windows app — publish it once as a standalone `.exe` (no dotnet CLI or
console needed to actually run it afterwards):
```powershell
powershell -ExecutionPolicy Bypass -File build-windows-app.ps1
```
This produces `windows-injector\publish\WindowsInjector.exe`. From then on,
just double-click it — or make a shortcut on the Desktop, or in
`shell:startup` (Win+R → `shell:startup`) to have it launch automatically
whenever you log in. Re-run the script any time you change
`windows-injector`'s code to republish it.

During development you can use `dotnet run --project .\windows-injector`
instead, which is faster than publishing but requires a terminal each time.

### 2. Start the Windows side

Double-click the published `.exe` (or `dotnet run` during development). A
small status window opens and a tray icon appears; it listens on port
`12653` by default. The status dot is orange ("Listening") until a Mac
connects and starts forwarding, then turns green ("Capturing"). Closing the
window just hides it back to the tray — use the tray icon's right-click menu
to reopen it or quit.

To change the port: open the window, edit the **Port** field, click
**Apply** — this restarts the listener and remembers the new port for next
launch (stored in `%AppData%\KrisKVM\settings.json`). Passing a port as a
command line argument (`WindowsInjector.exe 12653`) works too, as a
one-time override for that launch.

### 3. Start the Mac side

```bash
open build/KrisKVM.app
```

A small window opens showing an endpoint field (defaulting to
`192.168.0.100:12653` — edit it to your Windows PC's actual local IP and
port, or pick a previously-used one from the dropdown) and an Apply button.
The app connects to that endpoint automatically in the background and shows
"Connected" once it's up — this connection is independent of forwarding, so
it stays alive whether or not you're actively controlling the PC.

The first time it runs, grant `Accessibility` and `Input Monitoring` to
`KrisKVM.app` if macOS prompts — Input Monitoring specifically doesn't show
an alert dialog, so if keyboard forwarding doesn't seem to work, check
System Settings → Privacy & Security → Input Monitoring and confirm it's
enabled there.

### 4. Take control

Press **⌘⌥K** (or click **Start Forwarding**) once connected. Your Mac's
mouse and keyboard now drive the Windows PC instead of the Mac itself — the
Mac's own cursor freezes and local input is suppressed while this is active.
Press **⌘⌥K** again to hand control back to the Mac. The hotkey works
globally, so it doesn't matter which app is focused on the Mac when you
press it.

### Connecting over the internet (ngrok)

Use this when the Mac can't reach the Windows PC directly (different
networks):

1. Start the Windows app (see above), noting its port.
2. Expose it: `ngrok tcp 12653`
3. On the Mac, enter the ngrok host and port in the endpoint field (e.g.
   `0.tcp.sa.ngrok.io:12653`) and click Apply.

## What gets forwarded

- Mouse movement, clicks, and scroll.
- Keyboard input, including international characters. Plain character keys
  (anything Shift or Option/AltGr produces — like `ñ` on a Spanish LatAm
  keyboard, or `\`/`|`/`@` which live behind AltGr on many non-US layouts)
  are translated using the Mac's *current keyboard layout* and typed on
  Windows as literal Unicode text, so they come through correctly regardless
  of the PC's own keyboard layout.
- Enter/Tab/arrows/function keys and Ctrl/Cmd shortcuts (copy/paste, etc.)
  are sent as real key presses rather than typed text, since those need to
  be recognized as that specific key. Cmd and Ctrl are forwarded as their
  own distinct Windows modifiers (Cmd → Windows key, Ctrl → Ctrl) rather
  than remapped to each other.

## Known limitations

- Alt/Option is deliberately *not* treated as a shortcut modifier (so
  Alt+F won't open a Windows menu) — Option is too often used for typing
  ordinary characters on non-US Mac layouts to safely repurpose it.
- Raw media/system keys (brightness, volume, Mission Control, Dictation,
  etc.) aren't forwarded — those arrive via a different macOS event
  mechanism the current capture doesn't listen to.
- Dead-key accent sequences (e.g. an acute-accent dead key followed by a
  vowel) are threaded through macOS's own composition state and should
  compose correctly, but this hasn't been exhaustively tested across
  layouts.
- The connection is unauthenticated. It's meant for a private link between
  two machines you own — don't expose the listening port to an untrusted
  network without something like the ngrok approach above, which at least
  keeps the port off the open internet.

## Notes

- The Mac only initiates outbound TCP connections; the Windows side never
  connects out anywhere.
- The Mac build is ad-hoc code-signed with a fixed identifier so
  Accessibility and Input Monitoring grants survive rebuilds instead of
  needing to be re-added every time (unsigned executables get tracked by
  raw content hash, which changes on every recompile).
