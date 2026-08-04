using System.ComponentModel;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace WindowsInjector;

/// <summary>
/// Listens for SkeletonKey's line-based protocol and injects the corresponding
/// mouse/keyboard input via SendInput. Runs its accept loop on a background
/// thread and raises events so the tray UI can reflect connection state.
/// </summary>
internal sealed class InputListener
{
    private const int WheelDelta = 120;
    private const int XButton1 = 1;
    private const int XButton2 = 2;

    // Virtual-key codes that need the "extended key" flag set to behave
    // correctly when injected (matches how a real extended keyboard reports
    // them). See KEYBDINPUT docs.
    private static readonly HashSet<ushort> ExtendedVirtualKeys = new()
    {
        0x21, 0x22, 0x23, 0x24, // Prior/Next/End/Home
        0x25, 0x26, 0x27, 0x28, // Left/Up/Right/Down
        0x2D, 0x2E,             // Insert/Delete
        0x5B, 0x5C,             // LWin/RWin
        0xA5                    // RMENU (AltGr)
    };

    private readonly object gate = new();
    private readonly object writeGate = new();
    private TcpListener? tcpListener;
    private CancellationTokenSource? cts;
    private NetworkStream? activeStream;
    private TcpClient? activeClient;
    // Only inject while the Mac has explicitly said capture is on. The TCP
    // link itself stays up in the background; connection alone must never
    // move this PC's mouse.
    private volatile bool capturing;

    public const int MaxClipboardUtf8Bytes = 512 * 1024;

    public int Port { get; private set; }

    public event Action<int>? Listening;
    public event Action? ClientConnected;
    public event Action? ClientDisconnected;
    public event Action<bool>? CapturingChanged;
    public event Action<string>? ClipboardReceived;
    /// <summary>Mac asked for the PC clipboard right now (Stop handoff).</summary>
    public event Action? ClipboardRequested;
    public event Action<string>? StatusMessage;
    public event Action<string>? ErrorOccurred;

    public void Start(int port)
    {
        lock (gate)
        {
            StopLocked();

            Port = port;
            var localCts = new CancellationTokenSource();
            cts = localCts;

            TcpListener server;
            try
            {
                server = new TcpListener(IPAddress.Any, port);
                server.Start();
            }
            catch (Exception ex)
            {
                ErrorOccurred?.Invoke($"Couldn't listen on port {port}: {ex.Message}");
                return;
            }

            tcpListener = server;
            Listening?.Invoke(port);
            Task.Run(() => AcceptLoop(server, localCts.Token));
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            StopLocked();
        }
    }

    private void StopLocked()
    {
        cts?.Cancel();
        cts = null;
        try
        {
            tcpListener?.Stop();
        }
        catch
        {
            // Listener may already be stopped/disposed, fine to ignore.
        }
        tcpListener = null;
    }

    private void AcceptLoop(TcpListener server, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = server.AcceptTcpClient();
            }
            catch
            {
                break; // Listener was stopped or replaced.
            }

            using (client)
            {
                // Nagle batches small writes waiting for an ACK; disabling it
                // avoids delayed-ACK/Nagle interaction stalls that showed up
                // as choppy mouse movement.
                client.NoDelay = true;
                capturing = false;
                ClientConnected?.Invoke();
                StatusMessage?.Invoke("Client connected");

                try
                {
                    HandleClient(client, token);
                }
                catch (Exception ex)
                {
                    StatusMessage?.Invoke($"Connection error: {ex.Message}");
                }
                finally
                {
                    capturing = false;
                    lock (writeGate)
                    {
                        activeStream = null;
                        activeClient = null;
                    }
                    ClientDisconnected?.Invoke();
                    StatusMessage?.Invoke("Client disconnected");
                }
            }
        }
    }

    private void HandleClient(TcpClient client, CancellationToken token)
    {
        var stream = client.GetStream();
        lock (writeGate)
        {
            activeClient = client;
            activeStream = stream;
        }

        var buffer = new byte[8192];
        var pending = new MemoryStream();

        try
        {
            while (!token.IsCancellationRequested)
            {
                int read;
                try
                {
                    read = stream.Read(buffer, 0, buffer.Length);
                }
                catch
                {
                    break;
                }

                if (read <= 0)
                {
                    break;
                }

                for (var i = 0; i < read; i++)
                {
                    var b = buffer[i];
                    if (b == (byte)'\n')
                    {
                        var lineBytes = pending.ToArray();
                        pending.SetLength(0);
                        if (lineBytes.Length == 0)
                        {
                            continue;
                        }
                        // Trim optional CR from CRLF.
                        var length = lineBytes.Length;
                        if (lineBytes[length - 1] == (byte)'\r')
                        {
                            length--;
                        }
                        var line = Encoding.UTF8.GetString(lineBytes, 0, length);
                        HandleLine(line);
                    }
                    else
                    {
                        pending.WriteByte(b);
                        if (pending.Length > MaxClipboardUtf8Bytes * 2)
                        {
                            pending.SetLength(0);
                            StatusMessage?.Invoke("clipboard: discarded oversized inbound line");
                        }
                    }
                }
            }
        }
        finally
        {
            lock (writeGate)
            {
                if (ReferenceEquals(activeStream, stream))
                {
                    activeStream = null;
                    activeClient = null;
                }
            }
        }
    }

    /// <summary>
    /// Push local clipboard text to the Mac. No-op if nobody is connected.
    /// Uses the socket Send path so it is safe while the reader loop is blocked.
    /// </summary>
    public void SendClipboard(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        var utf8 = Encoding.UTF8.GetBytes(text);
        if (utf8.Length > MaxClipboardUtf8Bytes)
        {
            StatusMessage?.Invoke($"clipboard: skipped oversized local paste ({utf8.Length} bytes)");
            return;
        }

        var line = "clipboard " + Convert.ToBase64String(utf8) + "\n";
        var payload = Encoding.UTF8.GetBytes(line);
        SendRaw(payload);
        StatusMessage?.Invoke($"clipboard: sent {utf8.Length} bytes to Mac");
    }

    private void SendRaw(byte[] payload)
    {
        lock (writeGate)
        {
            var client = activeClient;
            if (client is null || !client.Connected)
            {
                StatusMessage?.Invoke("clipboard: send skipped (no client)");
                return;
            }

            try
            {
                client.Client.Send(payload, SocketFlags.None);
            }
            catch (Exception ex)
            {
                StatusMessage?.Invoke($"clipboard send error: {ex.Message}");
            }
        }
    }

    private void HandleLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        var space = line.IndexOf(' ');
        var command = space < 0 ? line : line[..space];
        var rest = space < 0 ? "" : line[(space + 1)..].TrimStart();

        try
        {
            switch (command)
            {
                case "capturing":
                {
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 1)
                    {
                        capturing = parts[0].Equals("on", StringComparison.OrdinalIgnoreCase);
                        CapturingChanged?.Invoke(capturing);
                    }
                    break;
                }
                case "clipboard-request":
                    // Mac is stopping / asking for a flush. Raise synchronously so
                    // the tray can Invoke and write the reply before we continue.
                    ClipboardRequested?.Invoke();
                    break;
                case "clipboard":
                    if (!string.IsNullOrEmpty(rest))
                    {
                        HandleClipboardCommand(rest);
                    }
                    break;
                case "move":
                {
                    if (!capturing) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 2)
                    {
                        InjectMouseMove(ParseInt(parts[0]), ParseInt(parts[1]));
                    }
                    break;
                }
                case "button":
                {
                    if (!capturing) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 2)
                    {
                        InjectMouseButton(ParseInt(parts[0]), parts[1].Equals("down", StringComparison.OrdinalIgnoreCase));
                    }
                    break;
                }
                case "scroll":
                {
                    if (!capturing) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 2)
                    {
                        InjectMouseScroll(ParseInt(parts[0]), ParseInt(parts[1]));
                    }
                    break;
                }
                case "text":
                {
                    if (!capturing) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 2)
                    {
                        InjectUnicodeText(parts[0], parts[1].Equals("down", StringComparison.OrdinalIgnoreCase));
                    }
                    break;
                }
                case "vk":
                {
                    if (!capturing) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    if (parts.Length >= 2)
                    {
                        InjectVirtualKey(ParseUInt16(parts[0]), parts[1].Equals("down", StringComparison.OrdinalIgnoreCase));
                    }
                    break;
                }
                case "heartbeat":
                    break;
                default:
                    StatusMessage?.Invoke($"Unhandled command: {command}");
                    break;
            }
        }
        catch (Exception ex)
        {
            StatusMessage?.Invoke($"Injection error: {ex.Message}");
        }
    }

    private void HandleClipboardCommand(string encoded)
    {
        byte[] payload;
        try
        {
            payload = Convert.FromBase64String(encoded);
        }
        catch (FormatException)
        {
            StatusMessage?.Invoke("clipboard: ignored invalid payload");
            return;
        }

        if (payload.Length == 0 || payload.Length > MaxClipboardUtf8Bytes)
        {
            StatusMessage?.Invoke("clipboard: ignored empty/oversized payload");
            return;
        }

        string text;
        try
        {
            text = Encoding.UTF8.GetString(payload);
        }
        catch (DecoderFallbackException)
        {
            StatusMessage?.Invoke("clipboard: ignored non-utf8 payload");
            return;
        }

        ClipboardReceived?.Invoke(text);
    }

    private static int ParseInt(string value) => int.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);

    private static ushort ParseUInt16(string value) => ushort.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);

    private static void InjectMouseMove(int dx, int dy)
    {
        SendMouseInput(dx, dy, 0, MouseEventFlags.Move);
    }

    private static void InjectMouseButton(int buttonNumber, bool isDown)
    {
        switch (buttonNumber)
        {
            case 0:
                SendMouseInput(0, 0, 0, isDown ? MouseEventFlags.LeftDown : MouseEventFlags.LeftUp);
                break;
            case 1:
                SendMouseInput(0, 0, 0, isDown ? MouseEventFlags.RightDown : MouseEventFlags.RightUp);
                break;
            case 2:
                SendMouseInput(0, 0, 0, isDown ? MouseEventFlags.MiddleDown : MouseEventFlags.MiddleUp);
                break;
            case 3:
                SendMouseInput(0, 0, XButton1, isDown ? MouseEventFlags.XDown : MouseEventFlags.XUp);
                break;
            case 4:
                SendMouseInput(0, 0, XButton2, isDown ? MouseEventFlags.XDown : MouseEventFlags.XUp);
                break;
        }
    }

    private static void InjectMouseScroll(int horizontal, int vertical)
    {
        if (vertical != 0)
        {
            SendMouseInput(0, 0, vertical * WheelDelta, MouseEventFlags.Wheel);
        }

        if (horizontal != 0)
        {
            SendMouseInput(0, 0, horizontal * WheelDelta, MouseEventFlags.HWheel);
        }
    }

    /// <summary>
    /// Types the exact character(s) the Mac's own keyboard layout resolved
    /// (e.g. ñ from a Spanish LatAm layout), regardless of this PC's active
    /// keyboard layout. KEYEVENTF_UNICODE bypasses the local layout entirely.
    ///
    /// Down+up are sent together on key-down only. Splitting them across
    /// separate Mac key-down / key-up events confuses Telegram (and other Qt
    /// apps): the previous character sticks and replaces the next one
    /// ("la dani" → "ll ddnn").
    /// </summary>
    private static void InjectUnicodeText(string hexCodeUnits, bool isDown)
    {
        if (!isDown)
        {
            return;
        }

        var codeUnits = hexCodeUnits.Split(',', StringSplitOptions.RemoveEmptyEntries);
        var inputs = new INPUT[codeUnits.Length * 2];

        for (var i = 0; i < codeUnits.Length; i++)
        {
            var codeUnit = ushort.Parse(codeUnits[i], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            inputs[i * 2] = new INPUT
            {
                Type = InputType.Keyboard,
                Data = new InputUnion
                {
                    Keyboard = new KEYBDINPUT
                    {
                        WVk = 0,
                        WScan = codeUnit,
                        DwFlags = (uint)KeyEventFlags.Unicode,
                        Time = 0,
                        DwExtraInfo = IntPtr.Zero
                    }
                }
            };
            inputs[i * 2 + 1] = new INPUT
            {
                Type = InputType.Keyboard,
                Data = new InputUnion
                {
                    Keyboard = new KEYBDINPUT
                    {
                        WVk = 0,
                        WScan = codeUnit,
                        DwFlags = (uint)(KeyEventFlags.Unicode | KeyEventFlags.KeyUp),
                        Time = 0,
                        DwExtraInfo = IntPtr.Zero
                    }
                }
            };
        }

        SendInputChecked(inputs);
    }

    /// <summary>
    /// Injects a real virtual-key press/release, for keys that must be
    /// recognized as that specific key (Enter, arrows, modifiers, and
    /// letters/numbers used in Ctrl/Cmd shortcuts) rather than typed text.
    /// </summary>
    private static void InjectVirtualKey(ushort virtualKey, bool isDown)
    {
        var flags = isDown ? (KeyEventFlags)0 : KeyEventFlags.KeyUp;
        if (ExtendedVirtualKeys.Contains(virtualKey))
        {
            flags |= KeyEventFlags.ExtendedKey;
        }

        var input = new INPUT
        {
            Type = InputType.Keyboard,
            Data = new InputUnion
            {
                Keyboard = new KEYBDINPUT
                {
                    WVk = virtualKey,
                    WScan = 0,
                    DwFlags = (uint)flags,
                    Time = 0,
                    DwExtraInfo = IntPtr.Zero
                }
            }
        };

        SendInputChecked(new[] { input });
    }

    private static void SendMouseInput(int dx, int dy, int mouseData, MouseEventFlags flags)
    {
        var input = new INPUT
        {
            Type = InputType.Mouse,
            Data = new InputUnion
            {
                Mouse = new MOUSEINPUT
                {
                    Dx = dx,
                    Dy = dy,
                    MouseData = mouseData,
                    DwFlags = (int)flags,
                    Time = 0,
                    DwExtraInfo = IntPtr.Zero
                }
            }
        };

        SendInputChecked(new[] { input });
    }

    private static void SendInputChecked(INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [Flags]
    private enum MouseEventFlags
    {
        Move = 0x0001,
        LeftDown = 0x0002,
        LeftUp = 0x0004,
        RightDown = 0x0008,
        RightUp = 0x0010,
        MiddleDown = 0x0020,
        MiddleUp = 0x0040,
        XDown = 0x0080,
        XUp = 0x0100,
        Wheel = 0x0800,
        HWheel = 0x1000
    }

    [Flags]
    private enum KeyEventFlags : uint
    {
        ExtendedKey = 0x0001,
        KeyUp = 0x0002,
        Unicode = 0x0004
    }

    private enum InputType
    {
        Mouse = 0,
        Keyboard = 1
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public InputType Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MOUSEINPUT Mouse;

        [FieldOffset(0)]
        public KEYBDINPUT Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int Dx;
        public int Dy;
        public int MouseData;
        public int DwFlags;
        public int Time;
        public IntPtr DwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort WVk;
        public ushort WScan;
        public uint DwFlags;
        public int Time;
        public IntPtr DwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
