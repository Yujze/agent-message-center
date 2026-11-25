using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace JieShou {
    // Both the filter popups and the appearance pickers keep their native
    // selection, keyboard and accessibility behavior.
    internal static class ChoiceRow {
        internal static int Px(int value, int dpi) => (int)Math.Round(value * dpi / 96.0);
        internal static void Paint(Graphics g, Rectangle bounds, string text, Font font,
                                   HudColors colors, int dpi, bool current, bool hot) {
            var state = g.Save();
            try {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using var surface = new SolidBrush(colors.Chrome);
                g.FillRectangle(surface, bounds);
                var tile = Rectangle.Inflate(bounds, -Px(4,dpi), -Px(2,dpi));
                if (current || hot) {
                    using var shape = MetricPill.Outline(tile, Px(6,dpi));
                    using var fill = new SolidBrush(current ? colors.Selected : colors.Hover);
                    g.FillPath(fill, shape);
                    if (hot) {
                        using var edge = new Pen(colors.Divider, Math.Max(1,Px(1,dpi)));
                        g.DrawPath(edge,shape);
                    }
                }
                int lead = Px(13,dpi), trail = Px(34,dpi);
                var label = new Rectangle(bounds.Left+lead, bounds.Top,
                    Math.Max(1,bounds.Width-lead-trail), bounds.Height);
                TextRenderer.DrawText(g,text,font,label,colors.Ink, TextFormatFlags.NoPrefix |
                    TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter |
                    TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
                if (current) {
                    int x = bounds.Right-Px(23,dpi), y = bounds.Top+bounds.Height/2;
                    using var pen = new Pen(colors.Ink, Math.Max(1f,1.7f*dpi/96f)) {
                        StartCap=LineCap.Round, EndCap=LineCap.Round, LineJoin=LineJoin.Round
                    };
                    g.DrawLines(pen,new[]{new Point(x,y),new Point(x+Px(3,dpi),y+Px(3,dpi)),
                                         new Point(x+Px(10,dpi),y-Px(4,dpi))});
                }
            } finally { g.Restore(state); }
        }
    }

    // Context and tray menus share the same row rendering as the session filters.
    public sealed class HudCommandMenuRenderer : ToolStripRenderer {
        private readonly HudColors colors;
        private readonly int dpi;
        private HudCommandMenuRenderer(HudColors colors,int dpi) { this.colors=colors; this.dpi=dpi; }
        public static void Apply(ContextMenuStrip menu,HudColors colors,Font font,int dpi) {
            menu.Renderer=new HudCommandMenuRenderer(colors,dpi);
            menu.ShowImageMargin=menu.ShowCheckMargin=false;
            menu.Font=font; menu.BackColor=colors.Chrome; menu.ForeColor=colors.Ink;
            menu.Padding=new Padding(ChoiceRow.Px(4,dpi));
            foreach(ToolStripItem item in menu.Items) {
                item.Padding=new Padding(ChoiceRow.Px(10,dpi),ChoiceRow.Px(5,dpi),ChoiceRow.Px(22,dpi),ChoiceRow.Px(5,dpi));
            }
        }
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(colors.Chrome); }
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
            using var pen=new Pen(colors.Divider);
            e.Graphics.DrawRectangle(pen,0,0,e.ToolStrip.Width-1,e.ToolStrip.Height-1);
        }
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
            ChoiceRow.Paint(e.Graphics,new Rectangle(Point.Empty,e.Item.Size),e.Item.Text,e.Item.Font,colors,dpi,
                e.Item is ToolStripMenuItem command && command.Checked,e.Item.Selected);
        }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { }
    }

    public sealed class HudChoiceMenu : ContextMenuStrip {
        private readonly HudButton trigger;
        private int D(int value) => ChoiceRow.Px(value, trigger.LayoutDpi);

        public HudChoiceMenu(IContainer container, HudButton trigger) : base(container) {
            this.trigger = trigger;
            ShowCheckMargin = ShowImageMargin = false;
            Renderer = new Frame(this);
        }
        public ToolStripMenuItem AddChoice(string text) {
            var item = new Entry(text);
            Items.Add(item);
            return item;
        }
        private void ApplyAppearance() {
            Font = trigger.Font;
            BackColor = trigger.Palette.Chrome;
            ForeColor = trigger.Palette.Ink;
            Padding = new Padding(D(4));
            int width = Math.Max(D(132),trigger.Width);
            foreach (ToolStripItem item in Items) {
                int textWidth = TextRenderer.MeasureText(item.Text,Font,Size.Empty,
                    TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
                width = Math.Max(width,textWidth+D(50));
            }
            // DropDownMenu otherwise sizes itself from the native text/check columns
            // and can clip owner-painted rows at high DPI.
            MinimumSize = new Size(width,0);
            foreach (ToolStripItem item in Items)
                item.Size = new Size(width, Math.Max(D(32),Font.Height+D(10)));
        }
        public void ShowForTrigger() {
            // Anchor the trailing edge to the trigger. WinForms keeps the popup on screen.
            ApplyAppearance();
            Show(trigger,new Point(trigger.Width,trigger.Height+D(3)), ToolStripDropDownDirection.BelowLeft);
        }
        protected override void OnOpening(CancelEventArgs e) {
            ApplyAppearance();
            base.OnOpening(e);
        }
        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (trigger == null || Width<=1 || Height<=1) return;
            using var path = MetricPill.Outline(ClientRectangle,D(9));
            Region = new Region(path);
        }
        protected override void OnOpened(EventArgs e) { base.OnOpened(e); trigger.Invalidate(); }
        protected override void OnClosed(ToolStripDropDownClosedEventArgs e) { base.OnClosed(e); trigger.Invalidate(); }

        private sealed class Entry : ToolStripMenuItem {
            internal Entry(string label) : base(label) { AutoSize = false; Margin = Padding.Empty; }
            protected override void OnPaint(PaintEventArgs e) {
                var menu = (HudChoiceMenu)Owner;
                ChoiceRow.Paint(e.Graphics,new Rectangle(Point.Empty,Size),Text,menu.Font,
                    menu.trigger.Palette,menu.trigger.LayoutDpi,Checked,Selected);
            }
        }
        private sealed class Frame : ToolStripRenderer {
            private readonly HudChoiceMenu menu;
            internal Frame(HudChoiceMenu menu) { this.menu = menu; }
            protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
                e.Graphics.Clear(menu.BackColor);
            }
            protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using var outline = MetricPill.Outline(new RectangleF(.5f,.5f,menu.Width-1,menu.Height-1),menu.D(9));
                using var pen = new Pen(menu.trigger.Palette.Divider,Math.Max(1,menu.D(1)));
                e.Graphics.DrawPath(pen,outline);
            }
        }
    }
}
