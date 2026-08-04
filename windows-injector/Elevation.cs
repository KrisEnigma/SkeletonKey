using System.Diagnostics;
using System.Security.Principal;
using System.Windows.Forms;

namespace WindowsInjector;

internal static class Elevation
{
    public static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    /// <summary>
    /// Starts a new elevated process with the given arguments. Returns false
    /// if the user cancelled UAC or elevation failed.
    /// </summary>
    public static bool TryRelaunchElevated(IEnumerable<string> args)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = Application.ExecutablePath,
                UseShellExecute = true,
                Verb = "runas",
                Arguments = QuoteArgs(args)
            };
            Process.Start(psi);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string QuoteArgs(IEnumerable<string> args) =>
        string.Join(' ', args.Select(arg =>
            arg.Contains(' ') || arg.Contains('"')
                ? "\"" + arg.Replace("\"", "\\\"") + "\""
                : arg));
}
