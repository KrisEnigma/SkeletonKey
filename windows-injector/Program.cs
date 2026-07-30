using System.Globalization;
using System.Windows.Forms;

namespace WindowsInjector;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        int? cliPortOverride = null;
        var startMinimized = false;
        foreach (var arg in args)
        {
            if (IsMinimizedFlag(arg))
            {
                startMinimized = true;
                continue;
            }

            if (int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedPort))
            {
                cliPortOverride = parsedPort;
            }
        }

        Application.Run(new TrayApplicationContext(cliPortOverride, startMinimized));
    }

    private static bool IsMinimizedFlag(string arg) =>
        arg is "--minimized" or "-minimized" or "/minimized"
            or "--tray" or "-tray" or "/tray";
}
