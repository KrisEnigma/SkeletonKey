# KrisKVM feasibility POC

Minimal outbound-only proof of concept:

- `mac-sender.swift`: macOS menu-bar app with global hotkey, mouse capture, and outbound TCP send
- `windows-injector/`: Windows listener that prints received lines and injects mouse input with `SendInput`

## What we confirmed

- `Input Monitoring` works on the MDM-managed Mac for a locally built binary.
- The Mac can capture global mouse movement with `CGEventTap`.
- The Mac can act as an outbound-only client; it does not need to listen for inbound connections.
- The Windows side can receive newline-delimited events from the Mac and inject mouse input when the network path is reachable.

## Current limits

- No authentication or encryption.
- Keyboard capture/injection is still out of scope.
- The Mac keeps the TCP connection alive across toggle-off; toggle-off only stops forwarding.
- `ngrok tcp` was used only as a temporary transport for validation; it is not the intended final path.

## Mac

Build and run on the Mac:

```bash
swiftc mac-sender.swift -o mac-sender -framework AppKit -framework Carbon -framework CoreGraphics -framework Network
./mac-sender 192.168.0.100 12653
```

Use `Cmd+Option+K` to toggle remote forwarding.
The Mac CLI is `./mac-sender <host> [port]`.

If `CGEvent.tapCreate` fails, grant `Input Monitoring` to the built binary in `System Settings > Privacy & Security`.

## Windows

Run the injector from the project folder:

```powershell
dotnet run --project .\windows-injector -- 12653
```

## Expected result

- With remote mode on, moving/clicking/scrolling on the Mac prints and injects matching events on Windows.
- The Mac only initiates an outbound TCP connection; nothing listens on the Mac.

## Test notes

- The Mac menu bar icon turns red when inactive, orange while connecting, and green when active and connected.
- Toggle-off stops forwarding but leaves the socket alive; this avoids reconnect churn and was the more reliable choice for the POC.
- If the Mac shows `Connection state: connecting` for too long, the TCP path is blocked or the target host/port is wrong.
- The Windows app logs each received line before injecting it.
