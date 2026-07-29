using System.Drawing;
using System.Media;
using System.Windows.Forms;

namespace WindowsInjector;

/// <summary>
/// The small status/settings window, SkeletonKey's counterpart to the Mac
/// app's control panel. Shows connection/capture state and lets you change
/// the listening port. Closing it just hides it; the tray icon and listener
/// keep running until "Quit" is chosen, same as the Mac app's window.
///
/// Laid out with FlowLayoutPanel rows that auto-size to their own content,
/// rather than hand-placed pixel coordinates. That's what caused the
/// clipped subtitle text before (a guessed Y offset didn't leave enough
/// room for the actual font metrics).
/// </summary>
internal sealed class SettingsForm : Form
{
    private readonly InputListener listener;
    private readonly PictureBox statusDot = new();
    private readonly Label statusLabel = new();
    private readonly TextBox portBox = new();
    private readonly Button applyButton = new();
    private readonly Button quitButton = new();

    public SettingsForm(InputListener listener)
    {
        this.listener = listener;

        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "SkeletonKey";
        Icon = TrayIcons.AppIcon;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = false;
        // Size to whatever the content actually needs instead of a guessed
        // fixed size. That guess was wrong last time and clipped the Quit
        // button off the bottom of the window.
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        var titleLabel = new Label
        {
            Text = "SkeletonKey",
            Font = new Font(Font.FontFamily, 20, FontStyle.Bold),
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 6)
        };

        var subtitleLabel = new Label
        {
            Text = "Receives forwarded mouse and keyboard input.",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 20)
        };

        statusDot.Size = new Size(16, 16);
        statusDot.SizeMode = PictureBoxSizeMode.StretchImage;
        statusDot.Image = TrayIcons.CreateDotBitmap(Color.Red, 32);
        statusDot.Margin = new Padding(0, 3, 10, 0);

        statusLabel.AutoSize = true;
        statusLabel.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        statusLabel.Text = "Starting…";
        statusLabel.Margin = new Padding(0);

        var statusRow = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 20)
        };
        statusRow.Controls.Add(statusDot);
        statusRow.Controls.Add(statusLabel);

        var divider = new Panel
        {
            Height = 1,
            Width = 350,
            BackColor = SystemColors.ControlDark,
            Margin = new Padding(0, 0, 0, 20)
        };

        var portCaption = new Label
        {
            Text = "PORT",
            Font = new Font(Font.FontFamily, 8, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 8)
        };

        portBox.Width = 150;
        portBox.Font = new Font(Font.FontFamily, 12);
        portBox.Margin = new Padding(0, 0, 12, 0);

        applyButton.Text = "Apply";
        applyButton.AutoSize = true;
        applyButton.Padding = new Padding(16, 6, 16, 6);
        applyButton.Margin = new Padding(0);
        applyButton.Click += OnApplyClicked;

        var portRow = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 8)
        };
        portRow.Controls.Add(portBox);
        portRow.Controls.Add(applyButton);

        var hintLabel = new Label
        {
            Text = "Changing the port restarts the listener.",
            AutoSize = true,
            Font = new Font(Font.FontFamily, 8),
            ForeColor = SystemColors.GrayText
        };

        quitButton.Text = "Quit";
        quitButton.AutoSize = true;
        quitButton.Padding = new Padding(18, 6, 18, 6);
        quitButton.Margin = new Padding(0, 20, 0, 0);
        quitButton.Click += (_, _) => Application.Exit();

        var mainStack = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(28, 26, 28, 26)
        };
        mainStack.Controls.Add(titleLabel);
        mainStack.Controls.Add(subtitleLabel);
        mainStack.Controls.Add(statusRow);
        mainStack.Controls.Add(divider);
        mainStack.Controls.Add(portCaption);
        mainStack.Controls.Add(portRow);
        mainStack.Controls.Add(hintLabel);
        mainStack.Controls.Add(quitButton);

        Controls.Add(mainStack);

        FormClosing += OnFormClosing;
    }

    private void OnApplyClicked(object? sender, EventArgs e)
    {
        if (int.TryParse(portBox.Text, out var port) && port is > 0 and <= 65535)
        {
            Settings.SavePort(port);
            listener.Start(port);
        }
        else
        {
            SystemSounds.Beep.Play();
        }
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }
    }

    public void UpdateStatus(bool listening, int port, bool connected, bool capturing, string? error)
    {
        if (!portBox.Focused)
        {
            var portText = port.ToString();
            if (portBox.Text != portText)
            {
                portBox.Text = portText;
            }
        }

        var color = !listening ? Color.Red : capturing ? Color.LimeGreen : Color.Orange;
        var oldImage = statusDot.Image;
        statusDot.Image = TrayIcons.CreateDotBitmap(color, 32);
        oldImage?.Dispose();

        statusLabel.Text = error
            ?? (capturing ? "Capturing" : connected ? "Connected (idle)" : listening ? $"Listening on {port}" : "Stopped");
    }
}
