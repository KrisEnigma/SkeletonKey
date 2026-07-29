using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WindowsInjector;

/// <summary>
/// App brand icon, tray icons with a colored semaphore badge, and the small
/// status dots used in the settings window (red/orange/green).
/// </summary>
internal static class TrayIcons
{
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    private static Icon? cachedAppIcon;
    private static Bitmap? cachedBrandBitmap;

    public static Icon AppIcon
    {
        get
        {
            if (cachedAppIcon != null)
            {
                return cachedAppIcon;
            }

            // Comes from <ApplicationIcon> in the csproj once published /
            // run; falls back to a generated brand-colored mark if missing
            // (e.g. odd launch contexts during development).
            cachedAppIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
                ?? CreateDot(Color.FromArgb(0x7B, 0x5C, 0xBF));
            return cachedAppIcon;
        }
    }

    /// <summary>
    /// Brand mark with a corner semaphore (red / orange / green) so tray
    /// status stays glanceable without dropping the app icon.
    /// </summary>
    public static Icon CreateBadged(Color badgeColor)
    {
        using var bitmap = new Bitmap(32, 32);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.Clear(Color.Transparent);
            // Brand bitmap is already tightly cropped; draw edge-to-edge.
            graphics.DrawImage(BrandBitmap(), 0, 0, 32, 32);

            const int badgeSize = 8;
            // Bottom-left (GDI origin is top-left).
            var badgeRect = new Rectangle(0, 32 - badgeSize, badgeSize, badgeSize);
            using var outline = new SolidBrush(Color.FromArgb(180, 0, 0, 0));
            graphics.FillEllipse(outline, Rectangle.Inflate(badgeRect, 1, 1));
            using var badge = new SolidBrush(badgeColor);
            graphics.FillEllipse(badge, badgeRect);
        }

        return IconFromBitmap(bitmap);
    }

    public static Icon CreateDot(Color color)
    {
        using var bitmap = CreateDotBitmap(color, 32);
        return IconFromBitmap(bitmap);
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

    private static Bitmap BrandBitmap()
    {
        if (cachedBrandBitmap != null)
        {
            return cachedBrandBitmap;
        }

        // Do not `using` AppIcon — that would dispose the shared cache and
        // later blow up Form/tray icon use with ObjectDisposedException.
        cachedBrandBitmap = AppIcon.ToBitmap();
        return cachedBrandBitmap;
    }

    private static Icon IconFromBitmap(Bitmap bitmap)
    {
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
}
