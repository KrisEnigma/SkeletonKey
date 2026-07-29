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

        // Kept for parity with the old console version / the Mac app's own
        // CLI-override behavior, but this is now just a one-time override —
        // the port persists via Settings after that.
        int? cliPortOverride = null;
        if (args.Length > 0 && int.TryParse(args[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedPort))
        {
            cliPortOverride = parsedPort;
        }

        Application.Run(new TrayApplicationContext(cliPortOverride));
    }
}
