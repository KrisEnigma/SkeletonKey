using System.Text.Json;

namespace WindowsInjector;

/// <summary>
/// Persists the listener port across runs, mirroring the Mac app remembering
/// its last-used host/port instead of requiring CLI args every launch.
/// </summary>
internal static class Settings
{
    private const int DefaultPort = 12653;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "KrisKVM",
        "settings.json");

    public static int LoadPort()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                using var stream = File.OpenRead(FilePath);
                var document = JsonDocument.Parse(stream);
                if (document.RootElement.TryGetProperty("port", out var portElement)
                    && portElement.TryGetInt32(out var port)
                    && port is > 0 and <= 65535)
                {
                    return port;
                }
            }
        }
        catch
        {
            // Corrupt or unreadable settings file — fall back to default.
        }

        return DefaultPort;
    }

    public static void SavePort(int port)
    {
        try
        {
            var directory = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(FilePath, JsonSerializer.Serialize(new { port }));
        }
        catch
        {
            // Non-fatal — the port just won't persist to the next launch.
        }
    }
}
