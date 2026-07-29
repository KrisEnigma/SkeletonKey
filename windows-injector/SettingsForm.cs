using System.Drawing;
using System.Drawing.Drawing2D;
using System.Media;
using System.Windows.Forms;

namespace WindowsInjector;

/// <summary>
/// Status/settings window — SkeletonKey's counterpart to the Mac control
/// panel. Dark charcoal layout with centered brand, status pill, and a
/// port card. Port is locked until Edit; Apply saves and locks again.
/// Close hides to tray; minimize goes to the taskbar.
/// </summary>
internal sealed class SettingsForm : Form
{
    private const int ContentWidth = 320;
    private const int FieldHeight = 32;
    private const int ActionButtonWidth = 72;

    private static readonly Color Bg = Color.FromArgb(0x1C, 0x1C, 0x1E);
    private static readonly Color CardBg = Color.FromArgb(0x2C, 0x2C, 0x2E);
    private static readonly Color FieldBg = Color.FromArgb(0x3A, 0x3A, 0x3C);
    private static readonly Color TextPrimary = Color.FromArgb(0xF5, 0xF5, 0xF7);
    private static readonly Color TextMuted = Color.FromArgb(0x8E, 0x8E, 0x93);
    private static readonly Color DividerColor = Color.FromArgb(0x3A, 0x3A, 0x3C);
    private static readonly Color Accent = Color.FromArgb(0x30, 0xD1, 0x58);
    private static readonly Color StatusOrange = Color.FromArgb(0xFF, 0x9F, 0x0A);
    private static readonly Color StatusGreen = Color.FromArgb(0x30, 0xD1, 0x58);
    private static readonly Color StatusRed = Color.FromArgb(0xFF, 0x45, 0x3A);

    private readonly InputListener listener;
    private readonly RoundedPanel statusPill = new() { CornerRadius = 12 };
    private readonly PictureBox statusDot = new();
    private readonly Label statusLabel = new();
    private readonly TextBox portBox = new();
    private readonly Button portActionButton = new();
    private readonly Button quitButton = new();
    private bool portEditing;
    private bool portDirty;
    private bool syncingPortText;

    public SettingsForm(InputListener listener)
    {
        this.listener = listener;

        // Clone so WinForms disposing Form.Icon (e.g. ShowInTaskbar toggles)
        // never tears down the shared tray brand icon.
        Icon = (Icon)TrayIcons.AppIcon.Clone();

        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "SkeletonKey";
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        MinimizeBox = true;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        BackColor = Bg;
        ForeColor = TextPrimary;
        Font = new Font("Segoe UI", 9f);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(0);

        var brandLabel = new Label
        {
            Text = "SKELETONKEY",
            Font = new Font("Segoe UI", 9f, FontStyle.Bold),
            ForeColor = TextMuted,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 10),
            TextAlign = ContentAlignment.MiddleCenter
        };

        statusDot.Size = new Size(10, 10);
        statusDot.SizeMode = PictureBoxSizeMode.StretchImage;
        statusDot.Image = TrayIcons.CreateDotBitmap(StatusOrange, 32);
        statusDot.Margin = new Padding(0, 2, 0, 0);
        statusDot.BackColor = Color.Transparent;

        statusLabel.AutoSize = true;
        statusLabel.Font = new Font("Segoe UI", 11f, FontStyle.Bold);
        statusLabel.ForeColor = StatusOrange;
        statusLabel.Text = "Starting…";
        statusLabel.Margin = new Padding(0);
        statusLabel.BackColor = Color.Transparent;

        var pillInner = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.Transparent,
            Margin = new Padding(0),
            Padding = new Padding(12, 6, 12, 6)
        };
        pillInner.Controls.Add(statusDot);
        pillInner.Controls.Add(statusLabel);

        statusPill.AutoSize = true;
        statusPill.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        statusPill.BackColor = BlendTint(StatusOrange);
        statusPill.Margin = new Padding(0, 0, 0, 18);
        statusPill.Controls.Add(pillInner);

        var divider = new Panel
        {
            Height = 1,
            Width = ContentWidth,
            BackColor = DividerColor,
            Margin = new Padding(0, 0, 0, 18)
        };

        var portCard = new RoundedPanel
        {
            CornerRadius = 12,
            BackColor = CardBg,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Margin = new Padding(0, 0, 0, 8),
            MinimumSize = new Size(ContentWidth, 0)
        };

        var portCaption = new Label
        {
            Text = "Port",
            Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
            ForeColor = TextMuted,
            AutoSize = false,
            Width = ContentWidth - 32,
            Height = 18,
            TextAlign = ContentAlignment.MiddleCenter,
            Margin = new Padding(0, 0, 0, 8),
            BackColor = Color.Transparent
        };

        const int rowInnerWidth = ContentWidth - 32;
        portBox.Width = rowInnerWidth - ActionButtonWidth - 8;
        portBox.Height = FieldHeight;
        portBox.MinimumSize = new Size(portBox.Width, FieldHeight);
        portBox.MaximumSize = new Size(portBox.Width, FieldHeight);
        portBox.Font = new Font("Segoe UI", 11f);
        portBox.BackColor = FieldBg;
        portBox.ForeColor = TextPrimary;
        portBox.BorderStyle = BorderStyle.FixedSingle;
        portBox.Margin = new Padding(0, 0, 8, 0);
        portBox.Multiline = false;
        portBox.TextAlign = HorizontalAlignment.Left;
        portBox.TextChanged += OnPortTextChanged;

        portActionButton.Size = new Size(ActionButtonWidth, FieldHeight);
        portActionButton.Margin = new Padding(0);
        portActionButton.Cursor = Cursors.Hand;
        portActionButton.FlatStyle = FlatStyle.Flat;
        portActionButton.FlatAppearance.BorderSize = 0;
        portActionButton.Click += OnPortActionClicked;

        var portRow = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.Transparent,
            Margin = new Padding(0),
            Padding = new Padding(0)
        };
        portRow.Controls.Add(portBox);
        portRow.Controls.Add(portActionButton);

        var cardStack = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.Transparent,
            Margin = new Padding(0),
            Padding = new Padding(16, 16, 16, 16)
        };
        cardStack.Controls.Add(portCaption);
        cardStack.Controls.Add(portRow);
        portCard.Controls.Add(cardStack);

        var hintLabel = new Label
        {
            Text = "Changing the port restarts the listener.",
            AutoSize = true,
            Font = new Font("Segoe UI", 8.5f),
            ForeColor = TextMuted,
            Margin = new Padding(0, 0, 0, 14),
            MaximumSize = new Size(ContentWidth, 0)
        };

        StyleQuietButton(quitButton, "Quit");
        quitButton.Margin = new Padding(0);
        quitButton.Click += (_, _) => Application.Exit();

        // Quit alone on its own row, trailing edge.
        var quitRow = new Panel
        {
            Width = ContentWidth,
            Height = quitButton.PreferredSize.Height,
            Margin = new Padding(0),
            BackColor = Color.Transparent
        };
        quitButton.Location = new Point(
            Math.Max(0, ContentWidth - quitButton.PreferredSize.Width),
            0);
        quitRow.Controls.Add(quitButton);
        quitRow.SizeChanged += (_, _) =>
        {
            quitButton.Left = Math.Max(0, quitRow.ClientSize.Width - quitButton.Width);
        };

        var mainStack = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Bg,
            Padding = new Padding(28, 28, 28, 24)
        };
        mainStack.Controls.Add(Centered(brandLabel));
        mainStack.Controls.Add(Centered(statusPill));
        mainStack.Controls.Add(divider);
        mainStack.Controls.Add(portCard);
        mainStack.Controls.Add(hintLabel);
        mainStack.Controls.Add(quitRow);

        Controls.Add(mainStack);

        // Clicking chrome (not the textbox) clears focus so the caret
        // doesn't stick when the port is locked or after leaving the field.
        MouseDown += (_, _) => ClearPortFocus();
        mainStack.MouseDown += (_, _) => ClearPortFocus();
        AttachClearFocus(brandLabel);
        AttachClearFocus(statusPill);
        AttachClearFocus(pillInner);
        AttachClearFocus(statusLabel);
        AttachClearFocus(statusDot);
        AttachClearFocus(divider);
        AttachClearFocus(portCard);
        AttachClearFocus(portCaption);
        AttachClearFocus(cardStack);
        AttachClearFocus(portRow);
        AttachClearFocus(hintLabel);
        AttachClearFocus(quitRow);

        SetPortEditing(false);

        FormClosing += OnFormClosing;
        VisibleChanged += OnVisibleChanged;
        Shown += (_, _) => ClearPortFocus();
    }

    /// <summary>
    /// Restore a normal, taskbar-visible window when opened from the tray.
    /// </summary>
    public void Present()
    {
        ShowInTaskbar = true;
        if (WindowState == FormWindowState.Minimized)
        {
            WindowState = FormWindowState.Normal;
        }
        Show();
        Activate();
        BringToFront();
        ClearPortFocus();
    }

    private void OnVisibleChanged(object? sender, EventArgs e)
    {
        if (Visible)
        {
            ShowInTaskbar = true;
            BeginInvoke(ClearPortFocus);
        }
    }

    private void OnPortTextChanged(object? sender, EventArgs e)
    {
        if (!syncingPortText && portEditing)
        {
            portDirty = true;
        }
    }

    private void OnPortActionClicked(object? sender, EventArgs e)
    {
        if (!portEditing)
        {
            SetPortEditing(true);
            portBox.Focus();
            portBox.SelectAll();
            return;
        }

        if (int.TryParse(portBox.Text.Trim(), out var port) && port is > 0 and <= 65535)
        {
            portDirty = false;
            Settings.SavePort(port);
            listener.Start(port);
            SetPortEditing(false);
            ClearPortFocus();
        }
        else
        {
            SystemSounds.Beep.Play();
        }
    }

    private void SetPortEditing(bool editing)
    {
        portEditing = editing;
        portBox.ReadOnly = !editing;
        portBox.TabStop = editing;
        portBox.Cursor = editing ? Cursors.IBeam : Cursors.Default;
        portBox.BackColor = editing ? FieldBg : Color.FromArgb(0x32, 0x32, 0x34);
        portBox.ForeColor = editing ? TextPrimary : TextMuted;

        if (editing)
        {
            portActionButton.Text = "Apply";
            portActionButton.BackColor = Accent;
            portActionButton.ForeColor = Color.White;
            portActionButton.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            portActionButton.FlatAppearance.MouseOverBackColor = Color.FromArgb(0x48, 0xE0, 0x70);
            portActionButton.FlatAppearance.MouseDownBackColor = Color.FromArgb(0x28, 0xB8, 0x4C);
            portActionButton.FlatAppearance.BorderSize = 0;
        }
        else
        {
            portActionButton.Text = "Edit";
            portActionButton.BackColor = FieldBg;
            portActionButton.ForeColor = TextPrimary;
            portActionButton.Font = new Font("Segoe UI", 9f);
            portActionButton.FlatAppearance.MouseOverBackColor = DividerColor;
            portActionButton.FlatAppearance.MouseDownBackColor = CardBg;
            portActionButton.FlatAppearance.BorderSize = 1;
            portActionButton.FlatAppearance.BorderColor = DividerColor;
            portDirty = false;
        }
    }

    private void ClearPortFocus()
    {
        if (ActiveControl == portBox || portBox.Focused)
        {
            ActiveControl = null;
        }
    }

    private void AttachClearFocus(Control control)
    {
        control.MouseDown += (_, _) => ClearPortFocus();
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            if (portEditing)
            {
                SetPortEditing(false);
            }
            Hide();
            ShowInTaskbar = false;
        }
    }

    public void UpdateStatus(bool listening, int port, bool connected, bool capturing, string? error)
    {
        // Sync the port field unless the user is mid-edit.
        if (!portEditing || !portDirty || string.IsNullOrWhiteSpace(portBox.Text))
        {
            var portText = port.ToString();
            if (portBox.Text != portText)
            {
                syncingPortText = true;
                portBox.Text = portText;
                syncingPortText = false;
                portDirty = false;
            }
        }

        var color = !listening ? StatusRed : capturing ? StatusGreen : StatusOrange;

        var oldImage = statusDot.Image;
        statusDot.Image = TrayIcons.CreateDotBitmap(color, 32);
        oldImage?.Dispose();

        statusLabel.ForeColor = color;
        statusLabel.Text = error
            ?? (capturing ? "Capturing" : connected ? "Connected (idle)" : listening ? "Listening" : "Stopped");

        statusPill.BackColor = BlendTint(color);
        statusPill.Invalidate();
    }

    private static Control Centered(Control child)
    {
        var bottom = child.Margin.Bottom;
        var host = new Panel
        {
            Width = ContentWidth,
            Margin = new Padding(0, 0, 0, bottom),
            BackColor = Color.Transparent
        };
        child.Margin = new Padding(0);
        host.Controls.Add(child);

        void Recenter()
        {
            host.Height = Math.Max(1, child.Height);
            child.Left = Math.Max(0, (host.ClientSize.Width - child.Width) / 2);
            child.Top = 0;
        }

        child.SizeChanged += (_, _) => Recenter();
        host.SizeChanged += (_, _) => Recenter();
        host.HandleCreated += (_, _) => Recenter();
        host.MouseDown += (_, _) =>
        {
            if (host.FindForm() is SettingsForm form)
            {
                form.ClearPortFocus();
            }
        };
        return host;
    }

    private static Color BlendTint(Color accent)
    {
        const float a = 0.14f;
        return Color.FromArgb(
            (int)(accent.R * a + Bg.R * (1 - a)),
            (int)(accent.G * a + Bg.G * (1 - a)),
            (int)(accent.B * a + Bg.B * (1 - a)));
    }

    private static void StyleQuietButton(Button button, string text)
    {
        button.Text = text;
        button.AutoSize = true;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = DividerColor;
        button.BackColor = FieldBg;
        button.ForeColor = TextPrimary;
        button.Font = new Font("Segoe UI", 8.5f);
        button.Padding = new Padding(12, 3, 12, 3);
        button.Margin = new Padding(0);
        button.Cursor = Cursors.Hand;
        button.FlatAppearance.MouseOverBackColor = DividerColor;
        button.FlatAppearance.MouseDownBackColor = CardBg;
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        if (diameter <= 0 || bounds.Width < diameter || bounds.Height < diameter)
        {
            path.AddRectangle(bounds);
            return path;
        }

        var arc = new Rectangle(bounds.Location, new Size(diameter, diameter));
        path.AddArc(arc, 180, 90);
        arc.X = bounds.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = bounds.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = bounds.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }

    private sealed class RoundedPanel : Panel
    {
        public int CornerRadius { get; set; } = 12;

        public RoundedPanel()
        {
            DoubleBuffered = true;
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            ApplyRegion();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(BackColor);
            using var path = RoundedRect(ClientRectangle, CornerRadius);
            e.Graphics.FillPath(brush, path);
        }

        private void ApplyRegion()
        {
            if (Width <= 0 || Height <= 0)
            {
                return;
            }

            using var path = RoundedRect(new Rectangle(0, 0, Width, Height), CornerRadius);
            Region?.Dispose();
            Region = new Region(path);
        }
    }
}
