using System.Drawing;
using System.Windows.Forms;

namespace WindowsInjector;

/// <summary>
/// Owns the tray icon, the settings window, and the listener's lifecycle.
/// Using ApplicationContext instead of a normal Form-based Main means the
/// app has no primary window that, if closed, would quit the whole app.
/// Same tray-icon-persists model as the Mac app's menu bar item.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly InputListener listener = new();
    private readonly NotifyIcon trayIcon;
    private readonly SettingsForm settingsForm;
    private readonly ToolStripMenuItem statusMenuItem;

    public TrayApplicationContext(int? cliPortOverride)
    {
        settingsForm = new SettingsForm(listener);
        // Force handle creation now so BeginInvoke below is safe even before
        // the window has ever been shown.
        _ = settingsForm.Handle;

        statusMenuItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        var openItem = new ToolStripMenuItem("Open SkeletonKey", null, (_, _) => ShowSettings());
        var quitItem = new ToolStripMenuItem("Quit", null, (_, _) => ExitApplication());

        var menu = new ContextMenuStrip();
        menu.Items.Add(statusMenuItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(openItem);
        menu.Items.Add(quitItem);

        trayIcon = new NotifyIcon
        {
            Icon = TrayIcons.CreateBadged(Color.Red),
            Text = "SkeletonKey",
            Visible = true,
            ContextMenuStrip = menu
        };
        trayIcon.DoubleClick += (_, _) => ShowSettings();

        listener.Listening += port =>
            RunOnUiThread(() => UpdateState(listening: true, connected: false, capturing: false, port: port));
        listener.ClientConnected += () =>
            RunOnUiThread(() => UpdateState(listening: true, connected: true, capturing: false, port: listener.Port));
        listener.ClientDisconnected += () =>
            // A fresh reconnect starts idle until the Mac says otherwise.
            RunOnUiThread(() => UpdateState(listening: true, connected: false, capturing: false, port: listener.Port));
        listener.CapturingChanged += capturing =>
            RunOnUiThread(() => UpdateState(listening: true, connected: true, capturing: capturing, port: listener.Port));
        listener.ErrorOccurred += message =>
            RunOnUiThread(() => UpdateState(listening: false, connected: false, capturing: false, port: listener.Port, error: message));

        var startPort = cliPortOverride ?? Settings.LoadPort();
        listener.Start(startPort);

        // Shown on launch, same as the Mac app's control window. Closing it
        // just hides it (see SettingsForm.OnFormClosing).
        settingsForm.Show();
    }

    private void RunOnUiThread(Action action)
    {
        settingsForm.BeginInvoke((MethodInvoker)(() => action()));
    }

    private void UpdateState(bool listening, bool connected, bool capturing, int port, string? error = null)
    {
        // Brand icon + semaphore badge: red when stopped/error, orange when
        // idle/waiting, green only while the Mac is actively capturing.
        var color = !listening ? Color.Red : capturing ? Color.LimeGreen : Color.Orange;
        var oldIcon = trayIcon.Icon;
        trayIcon.Icon = TrayIcons.CreateBadged(color);
        if (!ReferenceEquals(oldIcon, TrayIcons.AppIcon))
        {
            oldIcon?.Dispose();
        }

        var statusText = error
            ?? (capturing ? "Capturing" : connected ? "Connected (idle)" : listening ? $"Listening on {port}" : "Stopped");
        trayIcon.Text = $"SkeletonKey: {statusText}";
        statusMenuItem.Text = statusText;

        settingsForm.UpdateStatus(listening, port, connected, capturing, error);
    }

    private void ShowSettings()
    {
        settingsForm.Show();
        settingsForm.WindowState = FormWindowState.Normal;
        settingsForm.Activate();
    }

    private void ExitApplication()
    {
        trayIcon.Visible = false;
        listener.Stop();
        Application.Exit();
    }
}
