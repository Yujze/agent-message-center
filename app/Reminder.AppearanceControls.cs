using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    internal enum AppearanceChoiceStyle { Text, Theme, Shape, Grid, Navigation }

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
            set {
                foreach (var option in options) if (option.Text == value) option.Checked = true;
            }
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
            dpi=scale; palette=colors; BackColor=colors.Surface;
            Track=style==AppearanceChoiceStyle.Navigation ? colors.Surface : colors.Track;
            Radius=D(10);
            foreach (var option in options) { option.BackColor=Track; option.ForeColor=colors.Ink; }
            PerformLayout(); Invalidate(true);
        }
        protected override void OnLayout(LayoutEventArgs e) {
            base.OnLayout(e);
            if (options == null) return;
            bool grid=style==AppearanceChoiceStyle.Grid;
            int inset=D(3), groupWidth=grid ? D(50) : 0, width=Math.Max(0,Width-2*inset-groupWidth);
            for (int i=0; i<options.Length; i++) {
                if (options[i] == null) continue;
                int columns=grid ? 3 : options.Length;
                int rows=options.Length/columns, height=Math.Max(0,Height-2*inset);
                int column=i%columns, row=i/columns;
                int start=column*width/columns, top=row*height/rows;
                options[i].SetBounds(inset+groupWidth+start,inset+top,(column+1)*width/columns-start,(row+1)*height/rows-top);
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            if(style!=AppearanceChoiceStyle.Grid || palette==null) return;
            for(int i=0;i<options.Length;i+=3) {
                var first=options[i];
                var bounds=new Rectangle(D(8),first.Top,first.Left-D(12),first.Height);
                TextRenderer.DrawText(e.Graphics,first.Text.Substring(0,2),Font,bounds,palette.Muted,
                    TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
            }
        }
        private sealed class ChoiceRadio : RadioButton { public bool KeyboardFocus => ShowFocusCues; }
        private void DrawOption(ChoiceRadio option,HudColors swatch,Graphics g) {
            if (palette == null) return;
            g.Clear(Track); g.SmoothingMode=SmoothingMode.AntiAlias;
            bool hot=option.ClientRectangle.Contains(option.PointToClient(Cursor.Position));
            var bounds=new RectangleF(.5f,.5f,option.Width-1,option.Height-1);
            using var tile=MetricPill.Outline(bounds,D(7));
            bool nav=style==AppearanceChoiceStyle.Navigation;
            if (nav && option.Checked) {
                using var mark=new SolidBrush(palette.Accent);
                g.FillRectangle(mark,D(12),option.Height-D(3),option.Width-D(24),D(3));
            } else if (option.Checked || hot) {
                using var fill=new SolidBrush(option.Checked ? palette.Selected : palette.Hover);
                g.FillPath(fill,tile);
            }
            if (option.Focused && option.KeyboardFocus) {
                using var focus=new Pen(palette.Action,Math.Max(1,D(1)));
                g.DrawPath(focus,tile);
            }
            var flags=TextFormatFlags.NoPrefix|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine|TextFormatFlags.VerticalCenter;
            string caption=style==AppearanceChoiceStyle.Grid ? option.Text.Substring(2) : option.Text;
            int textWidth=TextRenderer.MeasureText(g,caption,option.Font,Size.Empty,flags).Width;
            int icon=style==AppearanceChoiceStyle.Shape || swatch!=null ? D(18) : 0, gap=icon==0 ? 0 : D(7);
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
            TextRenderer.DrawText(g,caption,option.Font,new Rectangle(x+icon+gap,0,textWidth+D(1),option.Height),ink,flags);
        }
    }

    internal sealed class AppearanceDropDown : Button {
        private readonly ChoicePopup popup;
        private readonly ToolStripControlHost host;
        private readonly HudScrollBar scroll;
        public ListBox Options { get; } = new ListBox {
            DrawMode=DrawMode.OwnerDrawFixed, BorderStyle=BorderStyle.None, IntegralHeight=false,
            Margin=Padding.Empty
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
        private int itemHeight=32;
        public int ItemHeight { get => itemHeight; set { itemHeight=value; Options.ItemHeight=value; } }
        public bool DroppedDown {
            get => popup.Visible;
            set { if (value && !popup.Visible) Open(); else if (!value && popup.Visible) popup.Close(); }
        }
        public event EventHandler SelectedIndexChanged;
        public HudColors Palette;
        public int LayoutDpi=96;
        private int hover=-1;
        private int D(int n) => ChoiceRow.Px(n,LayoutDpi);

        public AppearanceDropDown(string label) {
            Options.AccessibleName=label+"选项";
            FlatStyle=FlatStyle.Flat; Cursor=Cursors.Hand; AccessibleRole=AccessibleRole.DropList;
            SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);
            popup=new ChoicePopup(this) {AutoSize=false, LayoutStyle=ToolStripLayoutStyle.VerticalStackWithOverflow};
            scroll=new HudScrollBar(Options);
            host=new ToolStripControlHost(scroll) {AutoSize=false,Margin=Padding.Empty,Padding=Padding.Empty};
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
            scroll.Palette=Palette;
            var location=new Point(Math.Clamp(anchor.Left,work.Left,Math.Max(work.Left,work.Right-Width)),
                below>=height ? anchor.Bottom+D(3) : Math.Max(work.Top,anchor.Top-D(3)-height));
            popup.Size=new Size(Width,height);
            popup.Show(location);
            // The popup has its own HWND and Windows may scale it during Show.
            popup.Font=Options.Font=Font;
            Options.ItemHeight=ItemHeight;
            host.Size=scroll.Size=new Size(Math.Max(1,Width-2*pad),rows*ItemHeight);
            popup.Bounds=new Rectangle(location,new Size(Width,height));
            Options.SelectedIndex=SelectedIndex;
            if (SelectedIndex>=0) Options.TopIndex=Math.Clamp(SelectedIndex-rows/2,0,Math.Max(0,Items.Count-rows));
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

        private sealed class ChoicePopup : ToolStripDropDown {
            private readonly AppearanceDropDown field;
            internal ChoicePopup(AppearanceDropDown field) { this.field=field; }
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
        private Rectangle[] monitors=Array.Empty<Rectangle>(), workAreas=Array.Empty<Rectangle>();
        private string[] labels=Array.Empty<string>();
        private RectangleF[] labelBounds=Array.Empty<RectangleF>();
        private string legend="";
        private Rectangle legendBounds;
        private Point guideStart,guideEnd;
        public string MapCaption { get; set; }="";
        private int selected;
        public event Action<int,HudDock> DockPicked;
        public Rectangle MarkerBounds { get; private set; }
        public Rectangle SelectedScreenBounds => monitors.Length==0 ? Rectangle.Empty : monitors[selected];
        public AppearancePreview() { DoubleBuffered=true; }
        public void ClearMap() { monitors=Array.Empty<Rectangle>(); MarkerBounds=Rectangle.Empty; }
        private Point DockPoint(HudDock dock) {
            var area=workAreas[selected];
            var marker=HudGeometry.Dock(area,new Size(1,1),dock.Anchor,dock.Vertical);
            int pad=Math.Min(ChoiceRow.Px(3,LayoutDpi),Math.Min(area.Width-1,area.Height-1)/2);
            return new Point(Math.Clamp(marker.X,area.Left+pad,area.Right-1-pad),
                Math.Clamp(marker.Y,area.Top+pad,area.Bottom-1-pad));
        }
        protected override void OnMouseClick(MouseEventArgs e) {
            base.OnMouseClick(e);
            if(e.Button!=MouseButtons.Left || monitors.Length==0 || !workAreas[selected].Contains(e.Location)) return;
            int radius=ChoiceRow.Px(9,LayoutDpi), nearest=radius*radius+1;
            HudDock? hit=null;
            foreach(string label in HudDock.Labels) {
                var dock=HudDock.FromLabel(label);
                var p=DockPoint(dock);
                int dx=p.X-e.X, dy=p.Y-e.Y, distance=dx*dx+dy*dy;
                if(distance<nearest) { nearest=distance; hit=dock; }
            }
            if(hit.HasValue) DockPicked?.Invoke(selected,hit.Value);
        }
        public void SetSampleEdge(Rectangle area,bool vertical,bool forward) {
            int x=forward ? area.Left-1 : area.Right, y=forward ? area.Top-1 : area.Bottom;
            Point start=vertical ? new Point(x,area.Top) : new Point(area.Left,y);
            Point end=vertical ? new Point(x,area.Bottom) : new Point(area.Right,y);
            if(start==guideStart && end==guideEnd) return;
            guideStart=start; guideEnd=end; Invalidate();
        }
        private RectangleF FitLabel(Graphics g,string text,int i) {
            int gap=ChoiceRow.Px(3,LayoutDpi);
            var inner=Rectangle.Inflate(workAreas[i],-gap,-gap);
            var size=g.MeasureString(text,Font);
            if(size.Width>inner.Width || size.Height>inner.Height) return RectangleF.Empty;
            var box=new RectangleF(inner.Left+(inner.Width-size.Width)/2,inner.Top+(inner.Height-size.Height)/2,size.Width,size.Height);
            if(i!=selected || !box.IntersectsWith(MarkerBounds)) return box;
            // Only move the caption if the glyphs themselves meet the capsule.
            foreach(var point in new[]{new PointF(MarkerBounds.Left-gap-box.Width,box.Y),new PointF(MarkerBounds.Right+gap,box.Y),
                    new PointF(box.X,MarkerBounds.Top-gap-box.Height),new PointF(box.X,MarkerBounds.Bottom+gap)}) {
                var candidate=new RectangleF(point,box.Size);
                if(((RectangleF)inner).Contains(candidate)) return candidate;
            }
            return RectangleF.Empty;
        }
        private void ProjectMap(Rectangle desktop,Rectangle area,Rectangle[] screens,Rectangle[] work,Rectangle pill) {
            double scale=Math.Min(area.Width/(double)desktop.Width,area.Height/(double)desktop.Height);
            int X(int x)=>area.Left+(int)Math.Round((area.Width-desktop.Width*scale)/2+(x-desktop.Left)*scale);
            int Y(int y)=>area.Top+(int)Math.Round((area.Height-desktop.Height*scale)/2+(y-desktop.Top)*scale);
            Rectangle Map(Rectangle r)=>Rectangle.FromLTRB(X(r.Left),Y(r.Top),X(r.Right),Y(r.Bottom));
            monitors=Array.ConvertAll(screens,Map); workAreas=Array.ConvertAll(work,Map);
            var marker=Map(pill);
            var limit=workAreas[selected];
            // Preserve the marker center at small diagram scales, keeping it inside its screen.
            int shortSide=Math.Max(2,ChoiceRow.Px(4,LayoutDpi)), longSide=shortSide*3;
            bool tall=pill.Height>pill.Width;
            int w=Math.Min(limit.Width,Math.Max(tall ? shortSide : longSide,marker.Width));
            int h=Math.Min(limit.Height,Math.Max(tall ? longSide : shortSide,marker.Height));
            MarkerBounds=new Rectangle(Math.Clamp(marker.Left+(marker.Width-w)/2,limit.Left,limit.Right-w),
                Math.Clamp(marker.Top+(marker.Height-h)/2,limit.Top,limit.Bottom-h),w,h);
        }
        public void SetMap(Rectangle[] screens,Rectangle[] work,string[] names,int target,Rectangle pill) {
            Rectangle desktop=screens[0];
            foreach(var screen in screens) desktop=Rectangle.Union(desktop,screen);
            int pad=ChoiceRow.Px(14,LayoutDpi), top=ChoiceRow.Px(38,LayoutDpi);
            var area=Rectangle.FromLTRB(pad,top,Width-pad,Math.Max(top+1,Height-pad));
            selected=target;
            ProjectMap(desktop,area,screens,work,pill);
            labels=(string[])names.Clone();
            labelBounds=new RectangleF[names.Length];
            legend="";
            using var g=CreateGraphics();
            g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            bool needsLegend=false;
            for(int i=0;i<labels.Length;i++) {
                labelBounds[i]=FitLabel(g,labels[i],i);
                if(labelBounds[i].IsEmpty) {
                    labels[i]=names[i].Replace(" · ","\n");
                    labelBounds[i]=FitLabel(g,labels[i],i);
                    needsLegend |= labelBounds[i].IsEmpty;
                }
            }
            if(needsLegend) {
                legend=String.Join("     ",names);
                int h=(int)Math.Ceiling(g.MeasureString(legend,Font,Math.Max(1,area.Width)).Height);
                legendBounds=new Rectangle(area.Left,area.Bottom-h,area.Width,h);
                area.Height=Math.Max(1,area.Height-h-ChoiceRow.Px(5,LayoutDpi));
                ProjectMap(desktop,area,screens,work,pill);
                for(int i=0;i<labels.Length;i++) {
                    labels[i]=names[i].Split('·')[0].Trim().Replace("屏幕 ","");
                    labelBounds[i]=FitLabel(g,labels[i],i);
                }
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            if(Palette==null) return;
            var g=e.Graphics; g.Clear(BackColor); g.SmoothingMode=SmoothingMode.AntiAlias;
            using var frame=MetricPill.Outline(new RectangleF(.5f,.5f,Width-1,Height-1),ChoiceRow.Px(12,LayoutDpi));
            using var surface=new SolidBrush(Palette.Track); g.FillPath(surface,frame);
            using var line=new Pen(Palette.Divider); g.DrawPath(line,frame);
            if(monitors.Length>0) {
                using var screenFill=new SolidBrush(Palette.Chrome);
                using var activeFill=new SolidBrush(Palette.Selected);
                using var taskbar=new SolidBrush(Color.FromArgb(90,Palette.Line));
                using var activeEdge=new Pen(Palette.Accent,Math.Max(1,LayoutDpi/96f));
                for(int i=0;i<monitors.Length;i++) {
                    var rect=monitors[i];
                    if(rect.Width<2 || rect.Height<2) continue;
                    g.FillRectangle(taskbar,rect);
                    g.FillRectangle(i==selected ? activeFill : screenFill,workAreas[i]);
                    g.DrawRectangle(i==selected ? activeEdge : line,rect.X,rect.Y,rect.Width-1,rect.Height-1);
                }
                g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using var normal=new SolidBrush(Palette.Muted);
                using var active=new SolidBrush(Palette.Ink);
                int inset=ChoiceRow.Px(16,LayoutDpi);
                using var captionFont=new Font(Font.FontFamily,ChoiceRow.Px(13,LayoutDpi),FontStyle.Bold,GraphicsUnit.Pixel);
                using var format=new StringFormat {LineAlignment=StringAlignment.Center};
                var caption=new RectangleF(inset,ChoiceRow.Px(5,LayoutDpi),Width-2*inset,ChoiceRow.Px(30,LayoutDpi));
                g.DrawString(MapCaption,captionFont,normal,caption,format);
                for(int i=0;i<labels.Length;i++)
                    if(!labelBounds[i].IsEmpty) g.DrawString(labels[i],Font,i==selected ? active : normal,labelBounds[i].Location);
                if(legend.Length>0) g.DrawString(legend,Font,normal,legendBounds);
                if(workAreas[selected].Width>0 && workAreas[selected].Height>0) {
                    int radius=Math.Max(1,ChoiceRow.Px(2,LayoutDpi));
                    foreach(string label in HudDock.Labels) {
                        var p=DockPoint(HudDock.FromLabel(label));
                        g.FillEllipse(normal,p.X-radius,p.Y-radius,2*radius,2*radius);
                    }
                }
                if(MarkerBounds.Width>0 && MarkerBounds.Height>0) {
                    using var marker=MetricPill.Outline(MarkerBounds,Math.Min(MarkerBounds.Width,MarkerBounds.Height)/2f);
                    using var ink=new SolidBrush(Palette.Accent); g.FillPath(ink,marker);
                }
                return;
            }
            using var dot=new SolidBrush(Color.FromArgb(65,Palette.Line));
            int grid=ChoiceRow.Px(12,LayoutDpi); float sz=Math.Max(1,LayoutDpi/80f);
            for(int x=grid;x<Width-grid/2;x+=grid)
                for(int y=ChoiceRow.Px(38,LayoutDpi)+grid/2;y<Height-grid/2;y+=grid) g.FillEllipse(dot,x,y,sz,sz);
            using var guide=new Pen(Palette.Line,Math.Max(1,LayoutDpi/96f));
            g.DrawLine(guide,guideStart,guideEnd);
        }
    }
}
