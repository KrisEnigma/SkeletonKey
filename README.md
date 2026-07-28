# KrisKVM

Outbound-only Mac-to-Windows remote input POC.

## Build the app

Mac app bundle:
```bash
sh build-mac-app.sh
```

Windows injector:
```powershell
dotnet run --project .\windows-injector -- 12653
```

## Run locally

1. Start the Windows injector:
```powershell
dotnet run --project .\windows-injector -- 12653
```

2. Build the Mac app and open the launcher bundle:
```bash
sh build-mac-app.sh
open build/KrisKVM.app
```

3. The launcher starts `mac-sender` in the background.

4. Press `Cmd+Option+K` in the running capture binary to toggle forwarding.

## Run with ngrok

Use this when the Mac cannot reach Windows directly:

1. Start the Windows injector:
```powershell
dotnet run --project .\windows-injector -- 12653
```

2. Expose it:
```powershell
ngrok tcp 12653
```

3. Open the Mac launcher and pass the ngrok host and port:
```bash
sh build-mac-app.sh
open build/KrisKVM.app --args <ngrok-host> <ngrok-port>
```

Example:
```bash
open build/KrisKVM.app --args 0.tcp.sa.ngrok.io 12653
```

## What the app does

- The launcher shows the only menu bar icon, not a Dock app.
- It starts and stops the working capture binary in the background.
- The capture binary is headless and stays out of the UI.
- Red means inactive.
- Orange means connecting.
- Green means connected and active.
- Mouse movement, clicks, and scroll are forwarded from the capture binary to Windows.

## Notes

- The Mac only initiates outbound TCP connections.
- The connection is unauthenticated and should stay private.
- Keyboard capture/injection is out of scope for this phase.
