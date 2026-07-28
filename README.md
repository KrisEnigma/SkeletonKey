# KrisKVM

Outbound-only Mac-to-Windows remote input POC.

## Build

Mac:
```bash
swiftc mac-sender.swift -o mac-sender -framework AppKit -framework Carbon -framework CoreGraphics -framework Network
```

Windows:
```powershell
dotnet run --project .\windows-injector -- 12653
```

## Local LAN test

1. Start the Windows injector:
```powershell
dotnet run --project .\windows-injector -- 12653
```

2. Start the Mac app:
```bash
./mac-sender 192.168.0.100 12653
```

3. Press `Cmd+Option+K` to toggle forwarding.

## Ngrok test

Use this when the Mac cannot reach Windows directly:

1. Start the Windows injector:
```powershell
dotnet run --project .\windows-injector -- 12653
```

2. Expose it:
```powershell
ngrok tcp 12653
```

3. Launch the Mac app with the ngrok host and port:
```bash
./mac-sender <ngrok-host> <ngrok-port>
```

Example:
```bash
./mac-sender 0.tcp.sa.ngrok.io 12653
```

## Expected behavior

- Menu bar icon is red when off.
- Icon turns orange while connecting.
- Icon turns green when connected and remote mode is on.
- Mouse movement, clicks, and scroll are forwarded from Mac to Windows.

## Notes

- The Mac only initiates outbound TCP connections.
- The connection is unauthenticated and should stay private.
- Keyboard capture/injection is out of scope for this phase.
