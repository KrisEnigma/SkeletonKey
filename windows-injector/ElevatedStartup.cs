using System.Diagnostics;
using System.Windows.Forms;

namespace WindowsInjector;

/// <summary>
/// Logon Task Scheduler entry that runs SkeletonKey elevated without a UAC
/// prompt each boot. Creating the task requires one elevation.
/// </summary>
internal static class ElevatedStartup
{
    public const string TaskName = "SkeletonKey";

    public static bool IsInstalled()
    {
        var psi = NewSchtasks($"/Query /TN \"{TaskName}\" /FO LIST");
        using var process = Process.Start(psi);
        if (process == null)
        {
            return false;
        }

        process.WaitForExit(5000);
        return process.ExitCode == 0;
    }

    public static void Install()
    {
        var exe = Application.ExecutablePath;
        // /RL HIGHEST = run elevated at logon without a per-boot UAC prompt.
        var tr = $"\\\"{exe}\\\" --minimized";
        RunSchtasks(
            $"/Create /TN \"{TaskName}\" /TR \"{tr}\" /SC ONLOGON /RL HIGHEST /F",
            "Couldn't create the elevated startup task");
    }

    public static void Uninstall()
    {
        if (!IsInstalled())
        {
            return;
        }

        RunSchtasks($"/Delete /TN \"{TaskName}\" /F", "Couldn't remove the elevated startup task");
    }

    private static void RunSchtasks(string arguments, string failurePrefix)
    {
        using var process = Process.Start(NewSchtasks(arguments))
            ?? throw new InvalidOperationException($"{failurePrefix}: schtasks failed to start.");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        process.WaitForExit(15000);
        if (process.ExitCode != 0)
        {
            var detail = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
            throw new InvalidOperationException($"{failurePrefix}: {detail.Trim()}");
        }
    }

    private static ProcessStartInfo NewSchtasks(string arguments) => new()
    {
        FileName = "schtasks",
        Arguments = arguments,
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true
    };
}
