using System.ComponentModel;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace WindowsInjector;

internal static class Program
{
    private const int DefaultPort = 12653;
    private const int WheelDelta = 120;
    private const int XButton1 = 1;
    private const int XButton2 = 2;

    public static void Main(string[] args)
    {
        var port = args.Length > 0 && int.TryParse(args[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedPort)
            ? parsedPort
            : DefaultPort;

        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        Console.WriteLine($"Listening on 0.0.0.0:{port}");

        try
        {
            while (true)
            {
                using var client = listener.AcceptTcpClient();
                Console.WriteLine("Client connected");

                try
                {
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.UTF8);

                    while (true)
                    {
                        var line = reader.ReadLine();
                        if (line is null)
                        {
                            break;
                        }

                        Console.WriteLine($"{DateTimeOffset.Now:O} {line}");
                        HandleLine(line);
                    }
                }
                finally
                {
                    Console.WriteLine("Client disconnected");
                }
            }
        }
        finally
        {
            listener.Stop();
        }
    }

    private static void HandleLine(string line)
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
                case "move" when parts.Length >= 3:
                    InjectMouseMove(ParseInt(parts[1]), ParseInt(parts[2]));
                    break;
                case "button" when parts.Length >= 3:
                    InjectMouseButton(ParseInt(parts[1]), parts[2].Equals("down", StringComparison.OrdinalIgnoreCase));
                    break;
                case "scroll" when parts.Length >= 3:
                    InjectMouseScroll(ParseInt(parts[1]), ParseInt(parts[2]));
                    break;
                case "heartbeat":
                    break;
                default:
                    Console.WriteLine($"Unhandled command: {line}");
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Injection error: {ex.Message}");
        }
    }

    private static int ParseInt(string value) => int.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);

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
            default:
                Console.WriteLine($"Ignoring unsupported mouse button: {buttonNumber}");
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

        var inputs = new[] { input };
        var sent = SendInput(1, inputs, Marshal.SizeOf<INPUT>());
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

    private enum InputType
    {
        Mouse = 0
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
