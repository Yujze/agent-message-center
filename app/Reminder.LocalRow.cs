using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace JieShou {
    public enum SessionIndicator { None, Attention, Running, CompletedUnread }

    public sealed class SessionActivityAnimation {
        private readonly FlowLayoutPanel list;
        private readonly Timer timer;

        public SessionActivityAnimation(FlowLayoutPanel list, IContainer components) {
            this.list = list;
            timer = new Timer(components) { Interval=60 };
            timer.Tick += (sender,e) => PaintFrame(Environment.TickCount64);
            list.VisibleChanged += (sender,e) => Refresh();
        }

        // SPI_GETCLIENTAREAANIMATION follows Windows' Animation effects preference.
        [DllImport("user32.dll", EntryPoint="SystemParametersInfoW")]
        private static extern bool SystemParametersInfo(uint action,uint param,out int enabled,uint flags);
        public static bool MotionAllowed => SystemParametersInfo(0x1042,0,out int enabled,0) && enabled != 0;
        public bool Enabled => timer.Enabled;

        private bool InView(LocalRow row) => row.Visible && list.ClientRectangle.IntersectsWith(row.Bounds);

        // The existing status poll also picks up scrolling and changes to the OS preference.
        public void Refresh() {
            bool animate = false;
            if (list.Visible && !list.Disposing && !list.IsDisposed) {
                foreach (Control control in list.Controls) {
                    if (control is LocalRow row && row.Indicator == SessionIndicator.Running && InView(row)) {
                        animate = MotionAllowed;
                        break;
                    }
                }
            }
            if (animate == timer.Enabled) return;
            timer.Enabled = animate;
            PaintFrame(animate ? Environment.TickCount64 : -1);
        }

        private void PaintFrame(long time) {
            foreach (Control control in list.Controls) {
                if (control is LocalRow row && row.Indicator == SessionIndicator.Running && (time < 0 || InView(row)))
                    row.SetAnimationTime(time);
            }
        }
    }

    // A separate button lets keyboard and pointer users expand the family without navigating.
    public sealed class SideChatToggle : Button {
        private bool hover, open;
        private string summary="";
        private HudColors colors;
        private int dpi;
        private bool waiting, unread;
        private int D(int n) => (int)Math.Round(n*dpi/96.0);
        public SideChatToggle() {
            DoubleBuffered=true; UseMnemonic=false; FlatStyle=FlatStyle.Flat;
            FlatAppearance.BorderSize=0; Margin=Padding.Empty; Cursor=Cursors.Hand;
        }
        public void Bind(int count,int input,int unseen,int running,bool expanded,HudColors palette,Font font,int scale) {
            var parts=new System.Collections.Generic.List<string>();
            if(input>0) parts.Add(input+" 待输入");
            if(unseen>0) parts.Add(unseen+" 完成未读");
            if(running>0) parts.Add(running+" 进行中");
            var status=String.Join("  ·  ",parts);
            string caption="侧聊 "+count;
            if (colors==palette && summary==status && Text==caption && open==expanded && Font==font && dpi==scale) return;
            colors=palette; dpi=scale; Font=font; Text=caption; open=expanded;
            summary=status; waiting=input>0; unread=unseen>0; BackColor=colors.Surface;
            AccessibleName=(open ? "收起" : "展开")+caption+(status.Length==0 ? "" : "，"+status);
            Height=Math.Max(D(31),font.Height+D(12)); Invalidate();
        }
        protected override void OnMouseEnter(EventArgs e) {base.OnMouseEnter(e);hover=true;Invalidate();}
        protected override void OnMouseLeave(EventArgs e) {base.OnMouseLeave(e);hover=false;Invalidate();}
        protected override void OnPaint(PaintEventArgs e) {
            if(colors==null) return;
            var g=e.Graphics; g.Clear(colors.Surface); g.SmoothingMode=SmoothingMode.AntiAlias;
            var flags=TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine|TextFormatFlags.NoPrefix;
            int x=D(37), y=D(1), h=Height-D(6);
            int w=TextRenderer.MeasureText(g,Text,Font,Size.Empty,flags).Width+D(34);
            using var tile=MetricPill.Outline(new RectangleF(x,y,w,h),h/2f);
            using var fill=new SolidBrush(hover ? colors.Hover : colors.Track); g.FillPath(fill,tile);
            int cx=x+D(12), cy=y+h/2, k=Math.Max(2,D(3));
            using var pen=new Pen(colors.Muted,Math.Max(1,dpi/72f)){LineJoin=LineJoin.Round,StartCap=LineCap.Round,EndCap=LineCap.Round};
            g.DrawLines(pen,open ? new[]{new Point(cx-k,cy-k/2),new Point(cx,cy+k/2),new Point(cx+k,cy-k/2)}
                                : new[]{new Point(cx-k/2,cy-k),new Point(cx+k/2,cy),new Point(cx-k/2,cy+k)});
            TextRenderer.DrawText(g,Text,Font,new Rectangle(x+D(23),y,w-D(23),h),colors.Ink,flags);
            int meta=x+w+D(9);
            TextRenderer.DrawText(g,summary,Font,new Rectangle(meta,y,Math.Max(1,Width-meta-D(6)),h),
                waiting ? colors.Accent : unread ? colors.Unread : colors.Muted,flags|TextFormatFlags.EndEllipsis);
            if(Focused && ShowFocusCues){using var focus=new Pen(colors.Action,Math.Max(1,D(1)));g.DrawPath(focus,tile);}
        }
    }

    // Native Button keeps keyboard, focus, and UI Automation semantics for the entire row.
    public sealed class LocalRow : Button {
        public string Detail { get; set; }
        public string TimeText { get; set; }
        public string Agent { get; set; }
        public bool CanOpen { get; set; }
        public Font TitleFont { get; set; }
        public Font DetailFont { get; set; }
        public SessionIndicator Indicator { get; set; }
        public bool ShowDivider { get; set; } = true;
        private bool hover, side, groupHead;
        private readonly System.Collections.Generic.Dictionary<int,int> heights=new System.Collections.Generic.Dictionary<int,int>();
        public int LayoutDpi { get; set; }
        public HudColors Colors { get; set; }
        private int Dip(int value) { return (int)Math.Round(value * LayoutDpi / 96.0); }
        private const TextFormatFlags TitleFlags = TextFormatFlags.WordBreak |
            TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl;

        public LocalRow() {
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseMnemonic = false;
            Margin = Padding.Empty;
            Cursor = Cursors.Hand;
            DoubleBuffered = true;
        }
        public void Bind(string title,string agent,string detail,string time,string description,SessionIndicator indicator,
                         bool canOpen,Image icon,HudColors colors,Font titleFont,Font detailFont,int dpi,bool sideChat,bool group) {
            if (Text==title && Agent==agent && Detail==detail && TimeText==time && AccessibleDescription==description &&
                Indicator==indicator && CanOpen==canOpen && Image==icon && Colors==colors && TitleFont==titleFont &&
                DetailFont==detailFont && LayoutDpi==dpi && side==sideChat && groupHead==group) return;
            if (Text!=title || Indicator!=indicator || TitleFont!=titleFont || DetailFont!=detailFont || LayoutDpi!=dpi || side!=sideChat || groupHead!=group) heights.Clear();
            side=sideChat; groupHead=group;
            Text=title; Agent=agent; Detail=detail; TimeText=time; Indicator=indicator; CanOpen=canOpen;
            Image=icon; Colors=colors; TitleFont=titleFont; DetailFont=detailFont; LayoutDpi=dpi;
            BackColor=colors.Surface; ForeColor=colors.Ink; TabStop=canOpen;
            Cursor=canOpen ? Cursors.Hand : Cursors.Default;
            AccessibleRole=canOpen ? AccessibleRole.PushButton : AccessibleRole.ListItem;
            AccessibleName=agent+" "+title; AccessibleDescription=description;
            indicatorBounds=Rectangle.Empty;
            Invalidate();
        }
        private Size TitleSize(Graphics graphics,int rowWidth) {
            int width = Math.Max(1, rowWidth - Dip(side ? 84 : 69));
            return TextRenderer.MeasureText(graphics, Text, TitleFont, new Size(width, int.MaxValue), TitleFlags);
        }
        private int DetailHeight(Graphics g) {
            int height = (int)Math.Ceiling(DetailFont.GetHeight(g));
            return Indicator == SessionIndicator.CompletedUnread ? height + Dip(4) : height;
        }

        private int DrawUnreadBadge(Graphics g,int left,int top,int height,int available,TextFormatFlags flags) {
            const string text = "完成未读";
            int padding = Dip(6);
            int width = Math.Min(available,TextRenderer.MeasureText(g,text,DetailFont,Size.Empty,flags & ~TextFormatFlags.EndEllipsis).Width + 2*padding);
            if (width <= 2*padding) return left;
            using var path = MetricPill.Outline(new RectangleF(left,top,width,height),Dip(6));
            using var fill = new SolidBrush(Colors.UnreadSurface);
            g.FillPath(fill,path);
            TextRenderer.DrawText(g,text,DetailFont,new Rectangle(left+padding,top,width-2*padding,height),Colors.Unread,flags);
            return left + width + Dip(7);
        }

        public int ContentHeight() => ContentHeight(Width);
        public int ContentHeight(int width) {
            if (heights.TryGetValue(width,out int cached)) return cached;
            using var graphics=CreateGraphics();
            int height=Dip(side ? 8 : 12)+TitleSize(graphics,width).Height+Dip(6)+DetailHeight(graphics)+Dip(groupHead ? 4 : side ? 8 : 12);
            if (heights.Count>=2) heights.Clear();
            heights[width]=height;
            return height;
        }
        private void DrawAgentIcon(Graphics g, int top) {
            if (Image == null) return;
            int size = Dip(side ? 16 : 20);
            var saved = g.Save();
            try {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(Image, new Rectangle(Dip(side ? 28 : 6), top, size, size),
                    0, 0, Image.Width, Image.Height, GraphicsUnit.Pixel);
            } finally { g.Restore(saved); }
        }
        private Rectangle indicatorBounds;
        private long animationTime = -1;

        internal void SetAnimationTime(long time) {
            animationTime = time;
            if (Visible && !indicatorBounds.IsEmpty) Invalidate(indicatorBounds);
        }

        private void DrawRunning(Graphics g) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // A stable session offset keeps simultaneous indicators independent across list refreshes.
            int offset = StringComparer.Ordinal.GetHashCode(Name) & 1023;
            double phase = ((animationTime % 1440 + offset) / 1440.0) * 2 * Math.PI;
            float scale = LayoutDpi / 96f;
            float middle = indicatorBounds.Top + indicatorBounds.Height / 2f;
            using var pen = new Pen(Colors.Accent, 2f * scale) { StartCap=LineCap.Round, EndCap=LineCap.Round };
            for (int bar=0; bar<3; bar++) {
                double wave = animationTime < 0 ? (bar == 1 ? 1 : 0.25) : (1+Math.Sin(phase - bar*1.6))/2;
                float half = (float)(1.1 + 2.8 * wave) * scale;
                float x = indicatorBounds.Left + (2.5f + 4*bar) * scale;
                g.DrawLine(pen,x,middle-half,x,middle+half);
            }
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            var surface = hover && CanOpen ? Colors.Hover : BackColor;
            if (Indicator == SessionIndicator.Running && !indicatorBounds.IsEmpty && indicatorBounds.Contains(e.ClipRectangle)) {
                using var fill = new SolidBrush(surface);
                g.FillRectangle(fill,indicatorBounds);
                DrawRunning(g);
                return;
            }
            g.Clear(surface);
            int left = Dip(side ? 52 : 37), top = Dip(side ? 8 : 12), titleHeight = TitleSize(g,Width).Height;
            if(side) {
                int branchX=Dip(15), end=top+TitleFont.Height/2;
                using var branch=new Pen(Colors.Divider,Math.Max(1,Dip(1)));
                g.DrawLine(branch,branchX,0,branchX,end); g.DrawLine(branch,branchX,end,Dip(22),end);
            }
            DrawAgentIcon(g, top + Math.Max(0,(TitleFont.Height - Dip(20))/2));
            int detailHeight = DetailHeight(g);
            TextRenderer.DrawText(g, Text, TitleFont, new Rectangle(left, top, Math.Max(1, Width - Dip(side ? 84 : 69)), titleHeight),
                ForeColor, TitleFlags);
            int detailY = top + titleHeight + Dip(6);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            const TextFormatFlags meta = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix |
                TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;
            int right = Width - Dip(8);
            int timeWidth = Math.Min(TextRenderer.MeasureText(g,TimeText,DetailFont,new Size(int.MaxValue,int.MaxValue),
                                                          meta & ~TextFormatFlags.EndEllipsis).Width + Dip(2),
                                     Math.Max(0,(right-left)/2));
            string detailText = Detail;
            int metaLeft = left;
            if (Indicator == SessionIndicator.Running) {
                indicatorBounds = new Rectangle(left,detailY+(detailHeight-Dip(13))/2,Dip(14),Dip(13));
                DrawRunning(g);
                metaLeft += Dip(18);
            } else if (Indicator == SessionIndicator.CompletedUnread) {
                metaLeft = DrawUnreadBadge(g,left,detailY,detailHeight,Math.Max(0,right-timeWidth-Dip(8)-left),meta);
                detailText = side ? Agent+" 侧聊" : groupHead ? Agent+" 主会话" : Agent;
            } else if (Indicator == SessionIndicator.Attention) {
                using var dot = new SolidBrush(Colors.Accent);
                g.FillEllipse(dot,left,detailY+(detailHeight-Dip(5))/2,Dip(5),Dip(5));
                metaLeft += Dip(10);
            }
            TextRenderer.DrawText(g, detailText, DetailFont,
                new Rectangle(metaLeft,detailY,Math.Max(0,right-timeWidth-Dip(8)-metaLeft),detailHeight),
                Colors.Muted,meta);
            TextRenderer.DrawText(g, TimeText, DetailFont,new Rectangle(right-timeWidth,detailY,timeWidth,detailHeight),
                Colors.Muted, meta | TextFormatFlags.Right);
            int x = Width - Dip(13), y = top + TitleFont.Height/2;
            if (CanOpen) using (var pen = new Pen(Colors.Muted, Math.Max(1, Dip(2)))) {
                g.DrawLines(pen, new[] { new Point(x - Dip(3), y - Dip(5)), new Point(x + Dip(2), y),
                    new Point(x - Dip(3), y + Dip(5)) });
            }
            if (ShowDivider) using (var pen = new Pen(Colors.Divider))
                g.DrawLine(pen, left, Height - 1, Width - Dip(6), Height - 1);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -2, -2));
        }
    }
}
