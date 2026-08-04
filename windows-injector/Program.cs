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
        var requireAdmin = false;
        string? startupAction = null;

        foreach (var arg in args)
        {
            if (arg is "--minimized" or "-minimized" or "/minimized" or "--tray" or "-tray" or "/tray")
            {
                startMinimized = true;
            }
            else if (arg is "--admin" or "-admin" or "/admin" or "--elevated" or "-elevated" or "/elevated")
            {
                requireAdmin = true;
            }
            else if (arg is "--install-startup" or "-install-startup" or "/install-startup")
            {
                startupAction = "install";
            }
            else if (arg is "--uninstall-startup" or "-uninstall-startup" or "/uninstall-startup")
            {
                startupAction = "uninstall";
            }
            else if (int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedPort))
            {
                cliPortOverride = parsedPort;
            }
        }

        if (startupAction != null)
        {
            RunStartupAction(startupAction);
            return;
        }

        if (requireAdmin && !Elevation.IsElevated())
        {
            // Exit this unelevated instance after relaunch (or UAC cancel).
            _ = Elevation.TryRelaunchElevated(args);
            return;
        }

        Application.Run(new TrayApplicationContext(cliPortOverride, startMinimized));
    }

    private static void RunStartupAction(string action)
    {
        if (!Elevation.IsElevated())
        {
            Elevation.TryRelaunchElevated(new[]
            {
                action == "install" ? "--install-startup" : "--uninstall-startup"
            });
            return;
        }

        try
        {
            if (action == "install")
            {
                ElevatedStartup.Install();
                MessageBox.Show(
                    "SkeletonKey will start elevated at login (tray-only), with no UAC prompt each time.\n\n"
                    + "Remove any shell:startup shortcut that uses --admin so you don't get two copies.",
                    "Elevated startup enabled",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            else
            {
                ElevatedStartup.Uninstall();
                MessageBox.Show(
                    "Elevated login startup was removed.",
                    "Elevated startup disabled",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "SkeletonKey startup", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
