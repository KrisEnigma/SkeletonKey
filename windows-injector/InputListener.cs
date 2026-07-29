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
        0x5B, 0x5C              // LWin/RWin
    };

    private readonly object gate = new();
    private TcpListener? tcpListener;
    private CancellationTokenSource? cts;
    // Only inject while the Mac has explicitly said capture is on. The TCP
    // link itself stays up in the background; connection alone must never
    // move this PC's mouse.
    private volatile bool capturing;

    public int Port { get; private set; }

    public event Action<int>? Listening;
    public event Action? ClientConnected;
    public event Action? ClientDisconnected;
    public event Action<bool>? CapturingChanged;
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
                    ClientDisconnected?.Invoke();
                    StatusMessage?.Invoke("Client disconnected");
                }
            }
        }
    }

    private void HandleClient(TcpClient client, CancellationToken token)
    {
        using var stream = client.GetStream();
        using var reader = new StreamReader(stream, Encoding.UTF8);

        while (!token.IsCancellationRequested)
        {
            var line = reader.ReadLine();
            if (line is null)
            {
                break;
            }

            HandleLine(line);
        }
    }

    private void HandleLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0)
        {
            return;
        }

        try
        {
            switch (parts[0])
            {
                case "capturing" when parts.Length >= 2:
                    capturing = parts[1].Equals("on", StringComparison.OrdinalIgnoreCase);
                    CapturingChanged?.Invoke(capturing);
                    break;
                case "move" when parts.Length >= 3:
                    if (!capturing) break;
                    InjectMouseMove(ParseInt(parts[1]), ParseInt(parts[2]));
                    break;
                case "button" when parts.Length >= 3:
                    if (!capturing) break;
                    InjectMouseButton(ParseInt(parts[1]), parts[2].Equals("down", StringComparison.OrdinalIgnoreCase));
                    break;
                case "scroll" when parts.Length >= 3:
                    if (!capturing) break;
                    InjectMouseScroll(ParseInt(parts[1]), ParseInt(parts[2]));
                    break;
                case "text" when parts.Length >= 3:
                    if (!capturing) break;
                    InjectUnicodeText(parts[1], parts[2].Equals("down", StringComparison.OrdinalIgnoreCase));
                    break;
                case "vk" when parts.Length >= 3:
                    if (!capturing) break;
                    InjectVirtualKey(ParseUInt16(parts[1]), parts[2].Equals("down", StringComparison.OrdinalIgnoreCase));
                    break;
                case "heartbeat":
                    break;
                default:
                    StatusMessage?.Invoke($"Unhandled command: {line}");
                    break;
            }
        }
        catch (Exception ex)
        {
            StatusMessage?.Invoke($"Injection error: {ex.Message}");
        }
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
    /// </summary>
    private static void InjectUnicodeText(string hexCodeUnits, bool isDown)
    {
        var codeUnits = hexCodeUnits.Split(',', StringSplitOptions.RemoveEmptyEntries);
        var inputs = new INPUT[codeUnits.Length];

        for (var i = 0; i < codeUnits.Length; i++)
        {
            var codeUnit = ushort.Parse(codeUnits[i], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            inputs[i] = new INPUT
            {
                Type = InputType.Keyboard,
                Data = new InputUnion
                {
                    Keyboard = new KEYBDINPUT
                    {
                        WVk = 0,
                        WScan = codeUnit,
                        DwFlags = (uint)(KeyEventFlags.Unicode | (isDown ? 0 : KeyEventFlags.KeyUp)),
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
