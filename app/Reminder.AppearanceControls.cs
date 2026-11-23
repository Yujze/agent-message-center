using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    internal enum AppearanceChoiceStyle { Text, Theme, Shape }

    // Each segment is a native radio button, including its keyboard and UIA behavior.
    internal sealed class AppearanceChoices : SegmentRail {
        private readonly RadioButton[] options;
        private readonly AppearanceChoiceStyle style;
        private HudColors palette;
        private int dpi = 96;
        public event EventHandler Changed;
        public string SelectedItem {
            get {
                foreach (var option in options) if (option.Checked) return option.Text;
                return null;
            }
            set { foreach (var option in options) if (option.Text == value) option.Checked = true; }
        }

        public AppearanceChoices(AppearanceChoiceStyle style, params string[] values) {
            this.style=style;
            options = new RadioButton[values.Length];
            for (int i=0; i<values.Length; i++) {
                var option = new ChoiceRadio { Text=values[i], Name=values[i], AccessibleName=values[i],
                    Appearance=System.Windows.Forms.Appearance.Button, FlatStyle=FlatStyle.Flat,
                    Cursor=Cursors.Hand, UseMnemonic=false };
                var swatch = style==AppearanceChoiceStyle.Theme ? new HudColors(new HudAppearance { Theme=values[i] }) : null;
                option.Paint += (s,e) => DrawOption(option,swatch,e.Graphics);
                option.CheckedChanged += (s,e) => { if (option.Checked) Changed?.Invoke(this,EventArgs.Empty); };
                options[i] = option;
                Controls.Add(option);
            }
        }
        private int D(int n) => ChoiceRow.Px(n,dpi);
        public void Style(HudColors colors,int scale) {
            dpi=scale; palette=colors; BackColor=colors.Surface; Track=colors.Track; Radius=D(10);
            foreach (var option in options) { option.BackColor=Track; option.ForeColor=colors.Ink; }
            PerformLayout(); Invalidate(true);
        }
        protected override void OnLayout(LayoutEventArgs e) {
            base.OnLayout(e);
            if (options == null) return;
            int inset=D(3), width=Math.Max(0,Width-2*inset);
            for (int i=0; i<options.Length; i++) {
                if (options[i] == null) continue;
                int start=i*width/options.Length, end=(i+1)*width/options.Length;
                options[i].SetBounds(inset+start,inset,end-start,Math.Max(0,Height-2*inset));
            }
        }
        private sealed class ChoiceRadio : RadioButton { public bool KeyboardFocus => ShowFocusCues; }
        private void DrawOption(ChoiceRadio option,HudColors swatch,Graphics g) {
            if (palette == null) return;
            g.Clear(Track); g.SmoothingMode=SmoothingMode.AntiAlias;
            bool hot=option.ClientRectangle.Contains(option.PointToClient(Cursor.Position));
            var bounds=new RectangleF(.5f,.5f,option.Width-1,option.Height-1);
            using var tile=MetricPill.Outline(bounds,D(7));
            if (option.Checked || hot) {
                using var fill=new SolidBrush(option.Checked ? palette.Selected : palette.Hover);
                g.FillPath(fill,tile);
            }
            if (option.Focused && option.KeyboardFocus) {
                using var focus=new Pen(palette.Action,Math.Max(1,D(1)));
                g.DrawPath(focus,tile);
            }
            var flags=TextFormatFlags.NoPrefix|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine|TextFormatFlags.VerticalCenter;
            int textWidth=TextRenderer.MeasureText(g,option.Text,option.Font,Size.Empty,flags).Width;
            int icon=style==AppearanceChoiceStyle.Text ? 0 : D(18), gap=icon==0 ? 0 : D(7);
            int x=(option.Width-textWidth-icon-gap)/2, cy=option.Height/2;
            Color ink=option.Checked ? palette.Ink : palette.Muted;
            if (swatch != null) {
                var rect=new Rectangle(x,cy-D(7),D(14),D(14));
                using var surface=new SolidBrush(swatch.Chrome);
                using var accent=new SolidBrush(swatch.Accent);
                using var rim=new Pen(palette.Line,Math.Max(1,D(1)));
                g.FillEllipse(surface,rect);
                g.FillPie(accent,rect,315,180);
                g.DrawEllipse(rim,rect);
            } else if (style==AppearanceChoiceStyle.Shape) {
                int radius=option.Text=="胶囊" ? 5 : option.Text=="圆角" ? 2 : 0;
                using var shape=MetricPill.Outline(new RectangleF(x,cy-D(5),icon,D(10)),D(radius));
                using var edge=new Pen(ink,Math.Max(1,dpi/80f)); g.DrawPath(edge,shape);
            }
            TextRenderer.DrawText(g,option.Text,option.Font,new Rectangle(x+icon+gap,0,textWidth+D(1),option.Height),ink,flags);
        }
    }

    internal sealed class AppearanceFontBox : Button {
        private readonly FontPopup popup;
        private readonly ToolStripControlHost host;
        public ListBox Options { get; } = new ListBox {
            DrawMode=DrawMode.OwnerDrawFixed, BorderStyle=BorderStyle.None, IntegralHeight=false,
            AccessibleName="字体选项", Margin=Padding.Empty
        };
        public ListBox.ObjectCollection Items => Options.Items;
        private string selected;
        public string SelectedItem {
            get => selected;
            set {
                if (value==selected || !Items.Contains(value)) return;
                selected=value; Text=value; Invalidate(); SelectedIndexChanged?.Invoke(this,EventArgs.Empty);
            }
        }
        public int SelectedIndex => selected==null ? -1 : Items.IndexOf(selected);
        public int DropDownHeight { get; set; } = 228;
        public int ItemHeight { get => Options.ItemHeight; set => Options.ItemHeight=value; }
        public bool DroppedDown {
            get => popup.Visible;
            set { if (value && !popup.Visible) Open(); else if (!value && popup.Visible) popup.Close(); }
        }
        public event EventHandler SelectedIndexChanged;
        public HudColors Palette;
        public int LayoutDpi=96;
        private int hover=-1;
        private int D(int n) => ChoiceRow.Px(n,LayoutDpi);

        public AppearanceFontBox() {
            FlatStyle=FlatStyle.Flat; Cursor=Cursors.Hand; AccessibleRole=AccessibleRole.DropList;
            SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);
            popup=new FontPopup(this) {AutoSize=false, LayoutStyle=ToolStripLayoutStyle.VerticalStackWithOverflow};
            host=new ToolStripControlHost(Options) {AutoSize=false,Margin=Padding.Empty,Padding=Padding.Empty};
            popup.Items.Add(host);
            Options.DrawItem+=(s,e)=>{
                if (Palette!=null && e.Index>=0 && e.Index<Items.Count)
                    ChoiceRow.Paint(e.Graphics,e.Bounds,Items[e.Index].ToString(),Options.Font,Palette,LayoutDpi,
                        e.Index==SelectedIndex,e.Index==hover || e.Index==Options.SelectedIndex);
            };
            Options.MouseMove+=(s,e)=>SetHover(Options.IndexFromPoint(e.Location));
            Options.MouseLeave+=(s,e)=>SetHover(-1);
            Options.MouseUp+=(s,e)=>{
                int index=Options.IndexFromPoint(e.Location);
                if(e.Button==MouseButtons.Left && index>=0) Commit(index);
            };
            Options.KeyDown+=(s,e)=>{
                if (e.KeyCode==Keys.Enter || e.KeyCode==Keys.Escape) {
                    e.SuppressKeyPress=true;
                    if(e.KeyCode==Keys.Enter) Commit(Options.SelectedIndex); else popup.Close();
                }
            };
            popup.Closing+=(s,e)=>{
                if (e.CloseReason==ToolStripDropDownCloseReason.AppClicked && ClientRectangle.Contains(PointToClient(MousePosition)))
                    e.Cancel=true;
            };
            popup.Closed+=(s,e)=>{hover=-1;Invalidate();};
        }
        private void SetHover(int next) {
            if (hover==next) return;
            int old=hover; hover=next;
            if (old>=0) Options.Invalidate(Options.GetItemRectangle(old));
            if (next>=0) Options.Invalidate(Options.GetItemRectangle(next));
        }
        private void Commit(int index) {
            if (index>=0 && index<Items.Count) SelectedItem=Items[index].ToString();
            popup.Close(); Focus();
        }
        private void Open() {
            if(Palette==null || Items.Count==0 || !Visible) return;
            int pad=D(4);
            var work=Screen.FromControl(this).WorkingArea;
            var anchor=RectangleToScreen(ClientRectangle);
            int below=work.Bottom-anchor.Bottom-D(3), above=anchor.Top-work.Top-D(3);
            int height=Math.Min(DropDownHeight,Math.Max(above,below));
            int rows=Math.Min(Items.Count,Math.Max(1,(height-2*pad)/ItemHeight));
            height=rows*ItemHeight+2*pad;
            popup.Padding=new Padding(pad); popup.BackColor=Options.BackColor=Palette.Chrome; Options.ForeColor=Palette.Ink;
            Options.Font=Font; popup.Font=Font;
            host.Size=Options.Size=new Size(Math.Max(1,Width-2*pad),rows*ItemHeight);
            popup.Size=new Size(Width,height);
            Options.SelectedIndex=SelectedIndex;
            if (SelectedIndex>=0) Options.TopIndex=Math.Clamp(SelectedIndex-rows/2,0,Math.Max(0,Items.Count-rows));
            popup.Show(new Point(Math.Clamp(anchor.Left,work.Left,Math.Max(work.Left,work.Right-Width)),
                below>=height ? anchor.Bottom+D(3) : Math.Max(work.Top,anchor.Top-D(3)-height)));
            Options.Focus(); Invalidate();
        }
        protected override bool ProcessCmdKey(ref Message m,Keys keyData) {
            if (keyData==Keys.F4 || keyData==(Keys.Alt|Keys.Down) || keyData==Keys.Down || keyData==Keys.Enter) {
                DroppedDown=!DroppedDown; return true;
            }
            return base.ProcessCmdKey(ref m,keyData);
        }
        protected override void OnClick(EventArgs e) { base.OnClick(e); DroppedDown=!DroppedDown; }
        protected override void OnPaint(PaintEventArgs e) {
            if (Palette==null || Width<2 || Height<2) return;
            var g=e.Graphics; int pad=D(12), mid=Height/2;
            g.Clear(Parent?.BackColor ?? Palette.Surface); g.SmoothingMode=SmoothingMode.AntiAlias;
            using var field=MetricPill.Outline(new RectangleF(.5f,.5f,Width-1,Height-1),D(8));
            using var fill=new SolidBrush(ClientRectangle.Contains(PointToClient(MousePosition)) ? Palette.Hover : Palette.Chrome);
            g.FillPath(fill,field);
            using var edge=new Pen(DroppedDown || (Focused && ShowFocusCues) ? Palette.Action : Palette.Divider,Math.Max(1,LayoutDpi/96f));
            g.DrawPath(edge,field);
            TextRenderer.DrawText(g,Text,Font,new Rectangle(pad,0,Math.Max(0,Width-4*pad),Height),Palette.Ink,
                TextFormatFlags.NoPrefix|TextFormatFlags.SingleLine|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
            using var arrow=new Pen(Palette.Muted,Math.Max(1,LayoutDpi/70f)) {StartCap=LineCap.Round,EndCap=LineCap.Round,LineJoin=LineJoin.Round};
            int x=Width-pad*2, d=D(4); if(DroppedDown) d=-d;
            g.DrawLines(arrow,new[]{new Point(x-Math.Abs(d),mid-d/2),new Point(x,mid+d/2),new Point(x+Math.Abs(d),mid-d/2)});
        }
        protected override void Dispose(bool disposing) { if(disposing) popup?.Dispose(); base.Dispose(disposing); }

        private sealed class FontPopup : ToolStripDropDown {
            private readonly AppearanceFontBox field;
            internal FontPopup(AppearanceFontBox field) { this.field=field; }
            [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h,int key,ref int value,int length);
            protected override void OnHandleCreated(EventArgs e) {
                base.OnHandleCreated(e);
                int round=3; DwmSetWindowAttribute(Handle,33,ref round,4);
            }
            protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(BackColor); }
            protected override void OnPaint(PaintEventArgs e) {
                if (field?.Palette==null) return;
                using var edge=new Pen(field.Palette.Divider,Math.Max(1,field.D(1)));
                e.Graphics.DrawRectangle(edge,0,0,Width-1,Height-1);
            }
            protected override bool ProcessCmdKey(ref Message m,Keys keyData) {
                if(keyData==Keys.Enter) { field.Commit(field.Options.SelectedIndex); return true; }
                if(keyData==Keys.Escape) { Close(); field.Focus(); return true; }
                return base.ProcessCmdKey(ref m,keyData);
            }
        }
    }

    internal sealed class AppearanceSlider : TrackBar {
        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left,Top,Right,Bottom; }
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd,int msg,IntPtr wParam,out Rect rect);
        public HudColors Palette;
        public int LayoutDpi=96;
        public AppearanceSlider() {
            AutoSize=false; TickStyle=TickStyle.None; SmallChange=1; Cursor=Cursors.Hand;
            SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);
        }
        protected override void OnPaint(PaintEventArgs e) {
            if (Palette==null || Width<4 || Height<4) return;
            var g=e.Graphics;
            g.Clear(BackColor); g.SmoothingMode=SmoothingMode.AntiAlias;
            SendMessage(Handle,0x419,IntPtr.Zero,out var thumb); // TBM_GETTHUMBRECT
            SendMessage(Handle,0x41A,IntPtr.Zero,out var channel);
            float r=ChoiceRow.Px(6,LayoutDpi), y=Height/2f;
            float x=(thumb.Left+thumb.Right)/2f;
            float half=(thumb.Right-thumb.Left)/2f, start=channel.Left+half, end=channel.Right-half;
            if (end<=start) return;
            x=Math.Clamp(x,start,end);
            float weight=ChoiceRow.Px(4,LayoutDpi);
            using var track=new Pen(Palette.Divider,weight) {StartCap=LineCap.Round,EndCap=LineCap.Round};
            g.DrawLine(track,start,y,end,y);
            if(x>start) {
                using var progress=new Pen(Palette.Action,weight) {StartCap=LineCap.Round,EndCap=LineCap.Round};
                g.DrawLine(progress,start,y,x,y);
            }
            using var knob=new SolidBrush(Palette.Action); g.FillEllipse(knob,x-r,y-r,2*r,2*r);
            if(Focused && ShowFocusCues) {
                using var ring=new Pen(Palette.Muted,Math.Max(1,LayoutDpi/96f));
                g.DrawEllipse(ring,x-r-2,y-r-2,2*r+4,2*r+4);
            }
        }
        protected override void OnValueChanged(EventArgs e) { base.OnValueChanged(e); Invalidate(); }
    }

    internal sealed class AppearancePreview : Panel {
        public HudColors Palette;
        public int LayoutDpi=96;
        public AppearancePreview() { DoubleBuffered=true; }
        protected override void OnPaint(PaintEventArgs e) {
            if(Palette==null) return;
            var g=e.Graphics; g.Clear(BackColor); g.SmoothingMode=SmoothingMode.AntiAlias;
            using var frame=MetricPill.Outline(new RectangleF(.5f,.5f,Width-1,Height-1),ChoiceRow.Px(12,LayoutDpi));
            using var surface=new SolidBrush(Palette.Track); g.FillPath(surface,frame);
            using var line=new Pen(Palette.Divider); g.DrawPath(line,frame);
            using var dot=new SolidBrush(Color.FromArgb(65,Palette.Line));
            int grid=ChoiceRow.Px(12,LayoutDpi); float sz=Math.Max(1,LayoutDpi/80f);
            for(int x=grid;x<Width-grid/2;x+=grid)
                for(int y=grid;y<Height-grid/2;y+=grid) g.FillEllipse(dot,x,y,sz,sz);
        }
    }
}