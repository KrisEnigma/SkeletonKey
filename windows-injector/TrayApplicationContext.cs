using System.Drawing;
using System.Text;
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
    private readonly System.Windows.Forms.Timer clipboardTimer = new() { Interval = 300 };
    private string? suppressClipboardText;
    private string? lastSentClipboardText;
    private bool capturing;

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

        clipboardTimer.Tick += (_, _) => PollClipboard();

        listener.Listening += port =>
            RunOnUiThread(() => UpdateState(listening: true, connected: false, capturing: false, port: port));
        listener.ClientConnected += () =>
            RunOnUiThread(() => UpdateState(listening: true, connected: true, capturing: false, port: listener.Port));
        listener.ClientDisconnected += () =>
            RunOnUiThread(() => UpdateState(listening: true, connected: false, capturing: false, port: listener.Port));
        listener.CapturingChanged += capturing =>
            RunOnUiThread(() => UpdateState(listening: true, connected: true, capturing: capturing, port: listener.Port));
        listener.ClipboardReceived += text =>
            RunOnUiThread(() => ApplyRemoteClipboard(text));
        // Must be synchronous: Mac is waiting for the reply on the same socket.
        listener.ClipboardRequested += () =>
        {
            if (settingsForm.InvokeRequired)
            {
                settingsForm.Invoke(new Action(FlushClipboardToMac));
            }
            else
            {
                FlushClipboardToMac();
            }
        };
        listener.ErrorOccurred += message =>
            RunOnUiThread(() => UpdateState(listening: false, connected: false, capturing: false, port: listener.Port, error: message));

        var startPort = cliPortOverride ?? Settings.LoadPort();
        listener.Start(startPort);

        settingsForm.Show();
    }

    private void RunOnUiThread(Action action)
    {
        settingsForm.BeginInvoke((MethodInvoker)(() => action()));
    }

    private void UpdateState(bool listening, bool connected, bool capturing, int port, string? error = null)
    {
        var color = !listening ? Color.Red : capturing ? Color.LimeGreen : Color.Orange;
        var oldIcon = trayIcon.Icon;
        trayIcon.Icon = TrayIcons.CreateBadged(color);
        if (!ReferenceEquals(oldIcon, TrayIcons.AppIcon))
        {
            oldIcon?.Dispose();
        }

        var statusText = error
            ?? (capturing ? "Capturing" : connected ? "Connected (idle)" : listening ? $"Listening on {port}" : "Stopped");
        // Tray tooltip keeps the port; the window pill is state-only.
        trayIcon.Text = $"SkeletonKey: {statusText}";
        statusMenuItem.Text = statusText;

        settingsForm.UpdateStatus(listening, port, connected, capturing, error);
        SetClipboardWatchEnabled(capturing);
    }

    private void SetClipboardWatchEnabled(bool enabled)
    {
        var wasCapturing = capturing;
        capturing = enabled;
        if (enabled)
        {
            if (!clipboardTimer.Enabled)
            {
                clipboardTimer.Start();
            }
            if (!wasCapturing)
            {
                PollClipboard(force: true);
            }
        }
        else
        {
            clipboardTimer.Stop();
        }
    }

    private void ApplyRemoteClipboard(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        try
        {
            suppressClipboardText = text;
            lastSentClipboardText = text;
            Clipboard.SetText(text, TextDataFormat.UnicodeText);
        }
        catch (Exception)
        {
            suppressClipboardText = null;
        }
    }

    private void FlushClipboardToMac()
    {
        PollClipboard(force: true);
    }

    private void PollClipboard() => PollClipboard(force: false);

    private void PollClipboard(bool force)
    {
        try
        {
            if (!Clipboard.ContainsText(TextDataFormat.UnicodeText) && !Clipboard.ContainsText())
            {
                return;
            }

            var text = Clipboard.ContainsText(TextDataFormat.UnicodeText)
                ? Clipboard.GetText(TextDataFormat.UnicodeText)
                : Clipboard.GetText();
            if (string.IsNullOrEmpty(text))
            {
                return;
            }

            if (!force && (text == suppressClipboardText || text == lastSentClipboardText))
            {
                return;
            }

            // On an explicit flush/request, skip only if this is still the
            // text we just applied from the Mac (no local copy happened).
            if (force && text == suppressClipboardText)
            {
                return;
            }

            if (Encoding.UTF8.GetByteCount(text) > InputListener.MaxClipboardUtf8Bytes)
            {
                return;
            }

            lastSentClipboardText = text;
            suppressClipboardText = null;
            listener.SendClipboard(text);
        }
        catch (Exception)
        {
            // Clipboard busy / unavailable this tick.
        }
    }

    private void ShowSettings()
    {
        settingsForm.Present();
    }

    private void ExitApplication()
    {
        clipboardTimer.Stop();
        trayIcon.Visible = false;
        listener.Stop();
        Application.Exit();
    }
}
