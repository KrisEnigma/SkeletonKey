using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace WindowsInjector;

/// <summary>
/// Generates the small colored-dot tray icons (red/orange/green, mirroring
/// the Mac app's status pill) at runtime instead of shipping icon assets.
/// </summary>
internal static class TrayIcons
{
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    public static Icon CreateDot(Color color)
    {
        using var bitmap = CreateDotBitmap(color, 32);

        // Bitmap.GetHicon() hands back a raw GDI handle that isn't owned by
        // any managed object, so it'd leak if left alone. Icon.Clone() makes
        // an independent copy the Icon class does manage, then we can safely
        // destroy the original handle.
        var handle = bitmap.GetHicon();
        try
        {
            using var handleIcon = Icon.FromHandle(handle);
            return (Icon)handleIcon.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    /// <summary>
    /// Same colored-dot rendering, as a plain Bitmap for use inline in the
    /// settings window (a real circle, rather than a colored square Panel).
    /// </summary>
    public static Bitmap CreateDotBitmap(Color color, int size)
    {
        var bitmap = new Bitmap(size, size);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);
        using var brush = new SolidBrush(color);
        var inset = (int)(size * 0.125);
        graphics.FillEllipse(brush, inset, inset, size - inset * 2, size - inset * 2);
        return bitmap;
    }
}
