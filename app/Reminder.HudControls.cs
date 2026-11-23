using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace JieShou {
    public class SegmentRail : Panel {
        public Color Track { get; set; }
        public int Radius { get; set; }
        public SegmentRail() { DoubleBuffered = true; }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var shape = MetricPill.Outline(ClientRectangle, Radius);
            using var fill = new SolidBrush(Track);
            e.Graphics.FillPath(fill, shape);
        }
    }

    public enum HudGlyph { None, All, Clock, Sort, Settings, Collapse, Previous, Next }

    // Keep the native button interaction, keyboard focus and AutomationId while
    // painting the same chrome across Windows themes and monitor scales.
    public sealed class HudButton : Button {
        public bool Primary { get; set; }
        public bool Field { get; set; }
        public Color? Swatch { get; set; }
        public HudGlyph Glyph { get; set; }
        public bool Selected { get; set; }
        public bool MenuArrow { get; set; }
        public bool IconOnly { get; set; }
        public HudColors Palette { get; set; }
        public int LayoutDpi { get; set; } = 96;
        private bool hot;
        private int D(int n) => (int)Math.Round(n * LayoutDpi / 96.0);
        private const TextFormatFlags LabelFlags = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding |
            TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;

        public HudButton() {
            UseMnemonic = false;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            TabStop = true;
            DoubleBuffered = true;
            Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hot = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = false; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            if (Palette == null || Width < 2 || Height < 2) return;
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var bounds = new RectangleF(.5f, .5f, Width-1, Height-1);
            using var shape = MetricPill.Outline(bounds, D(7));
            bool open = MenuArrow && ContextMenuStrip?.Visible == true;
            if (Primary || Field || Selected || open || (hot && Enabled)) {
                using var fill = new SolidBrush(Primary ? Palette.Action : Selected || open ? Palette.Selected : hot ? Palette.Hover : Palette.Chrome);
                g.FillPath(fill, shape);
                if (Field || Selected || open) {
                    using var edge = new Pen(Palette.Divider);
                    g.DrawPath(edge, shape);
                }
            }
            Color ink = !Enabled ? Palette.Line : Primary ? Palette.OnAction : open ? Palette.Ink : ForeColor;
            int icon = (Swatch.HasValue || Glyph != HudGlyph.None || Image != null) ? D(16) : 0;
            int arrow = MenuArrow ? D(9) : 0;
            int gap = D(6);
            int label = IconOnly ? 0 : Math.Min(
                TextRenderer.MeasureText(g,Text,Font,new Size(int.MaxValue,int.MaxValue),
                    LabelFlags & ~TextFormatFlags.EndEllipsis).Width + D(2),
                Math.Max(0,Width-icon-arrow-(icon>0?gap:0)-(arrow>0?gap:0)-D(4)));
            int length = icon + label + arrow + (label>0 && icon>0 ? gap:0) + (arrow>0 ? gap:0);
            int x = Math.Max(0,(Width-length)/2);
            int y = (Height-icon)/2;
            if (Swatch.HasValue) {
                using var paint = new SolidBrush(Swatch.Value);
                using var edge = new Pen(Palette.Line);
                g.FillEllipse(paint,x+1,y+1,icon-2,icon-2); g.DrawEllipse(edge,x+1,y+1,icon-2,icon-2);
            } else if (Image != null) {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(Image,new Rectangle(x,y,icon,icon),0,0,Image.Width,Image.Height,GraphicsUnit.Pixel);
            } else if (icon>0) {
                DrawGlyph(g, Glyph, x, y, icon, ink);
            }
            x += icon + (label>0 && icon>0 ? gap:0);
            if (label>0) TextRenderer.DrawText(g,Text,Font,new Rectangle(x,0,label,Height),ink,LabelFlags);
            if (MenuArrow) {
                x += label+gap;
                using var p = new Pen(ink,Math.Max(1f,LayoutDpi/96f*1.35f));
                int wing = Height/2 + (open ? D(1) : -D(1));
                int tip = Height/2 + (open ? -D(2) : D(2));
                g.DrawLines(p,new[]{new Point(x,wing),new Point(x+arrow/2,tip),new Point(x+arrow,wing)});
            }
            if (Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(g,Rectangle.Inflate(ClientRectangle,-D(3),-D(3)),ink,BackColor);
        }

        private static void DrawGlyph(Graphics g, HudGlyph glyph, int x, int y, int size, Color ink) {
            var saved = g.Save();
            try {
                g.TranslateTransform(x,y);
                g.ScaleTransform(size/18f,size/18f);
                using var p = new Pen(ink,1.6f) { StartCap=LineCap.Round, EndCap=LineCap.Round, LineJoin=LineJoin.Round };
                switch (glyph) {
                    case HudGlyph.All:
                        for (int i=0; i<4; i++) g.DrawRectangle(p,2+i%2*8,2+i/2*8,5,5);
                        break;
                    case HudGlyph.Clock:
                        g.DrawEllipse(p,2,2,14,14); g.DrawLine(p,9,5,9,9); g.DrawLine(p,9,9,12,11);
                        break;
                    case HudGlyph.Sort:
                        g.DrawLine(p,2,4,16,4); g.DrawLine(p,2,9,12,9); g.DrawLine(p,2,14,8,14);
                        break;
                    case HudGlyph.Settings:
                        g.DrawLine(p,2,5,5,5); g.DrawEllipse(p,5,3,4,4); g.DrawLine(p,9,5,16,5);
                        g.DrawLine(p,2,13,10,13); g.DrawEllipse(p,10,11,4,4); g.DrawLine(p,14,13,16,13);
                        break;
                    case HudGlyph.Collapse:
                        g.DrawLines(p,new[]{new Point(3,11),new Point(9,5),new Point(15,11)}); break;
                    case HudGlyph.Previous:
                        g.DrawLines(p,new[]{new Point(11,3),new Point(5,9),new Point(11,15)}); break;
                    case HudGlyph.Next:
                        g.DrawLines(p,new[]{new Point(7,3),new Point(13,9),new Point(7,15)}); break;
                }
            } finally { g.Restore(saved); }
        }
    }
}
