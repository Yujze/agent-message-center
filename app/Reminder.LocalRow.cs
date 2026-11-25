using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace JieShou {
    public enum SessionIndicator { None, Attention, Running, CompletedUnread }
    public enum SideChatBranch { None, Through, Last }

    internal static class SideChatTree {
        public const int ParentText = 37, ChildText = 59;

        // Both controls paint the same rail up to their edge, including for wrapped titles.
        public static void Draw(Graphics g, Color color, int dpi, int middle, int height, bool continues) {
            float scale = dpi / 96f, x = (float)Math.Round(ParentText * scale), radius = 5 * scale;
            float bend = middle - radius;
            var saved = g.Save();
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(color, Math.Max(1f, scale));
            using var path = new GraphicsPath();
            path.AddLine(x, 0, x, bend);
            path.AddArc(x, bend-radius, 2*radius, 2*radius, 180, -90);
            path.AddLine(x+radius, middle, x+14*scale, middle);
            g.DrawPath(pen, path);
            if (continues) g.DrawLine(pen, x, bend, x, height);
            g.Restore(saved);
        }
    }

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
            string caption=count+" 个侧聊";
            if (colors==palette && summary==status && Text==caption && open==expanded && Font==font && dpi==scale) return;
            colors=palette; dpi=scale; Font=font; Text=caption; open=expanded;
            summary=status; waiting=input>0; unread=unseen>0; BackColor=colors.Surface;
            AccessibleName=(open ? "收起 " : "展开 ")+caption+(status.Length==0 ? "" : "，"+status);
            Invalidate();
        }
        protected override void OnMouseEnter(EventArgs e) {base.OnMouseEnter(e);hover=true;Invalidate();}
        protected override void OnMouseLeave(EventArgs e) {base.OnMouseLeave(e);hover=false;Invalidate();}
        private const TextFormatFlags CaptionFlags=TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding|TextFormatFlags.SingleLine|TextFormatFlags.NoPrefix;
        private const TextFormatFlags SummaryFlags=TextFormatFlags.WordBreak|TextFormatFlags.NoPadding|TextFormatFlags.NoPrefix|TextFormatFlags.TextBoxControl;
        private (int Height,int CaptionWidth,int Line,Rectangle Summary) LayoutSummary(Graphics g,int width) {
            int x=D(SideChatTree.ChildText), line=Math.Max(D(28),Font.Height+D(10));
            int caption=TextRenderer.MeasureText(g,Text,Font,Size.Empty,CaptionFlags).Width;
            int start=x+caption+D(20)+Math.Max(2,D(3)), right=width-D(6);
            if(summary.Length==0 || TextRenderer.MeasureText(g,summary,Font,Size.Empty,CaptionFlags).Width<=right-start)
                return (line,caption,line,new Rectangle(start,0,Math.Max(1,right-start),line));
            int room=Math.Max(1,right-x);
            int h=TextRenderer.MeasureText(g,summary,Font,new Size(room,int.MaxValue),SummaryFlags).Height;
            return (line+h+D(4),caption,line,new Rectangle(x,line,room,h));
        }
        public int ContentHeight(int width) {
            using var g=CreateGraphics(); return LayoutSummary(g,width).Height;
        }
        protected override void OnPaint(PaintEventArgs e) {
            if(colors==null) return;
            var g=e.Graphics; g.Clear(colors.Surface); g.SmoothingMode=SmoothingMode.AntiAlias;
            var layout=LayoutSummary(g,Width);
            int x=D(SideChatTree.ChildText), cy=layout.Line/2;
            SideChatTree.Draw(g,colors.Line,dpi,cy,Height,open);
            int width=layout.CaptionWidth;
            var ink=hover ? colors.Ink : colors.Accent;
            TextRenderer.DrawText(g,Text,Font,new Rectangle(x,0,width,layout.Line),ink,CaptionFlags);
            int cx=x+width+D(8), k=Math.Max(2,D(3)), dy=open ? -k : k;
            using var pen=new Pen(ink,Math.Max(1,dpi/72f)){LineJoin=LineJoin.Round,StartCap=LineCap.Round,EndCap=LineCap.Round};
            g.DrawLines(pen,new[]{new Point(cx-k,cy-dy/2),new Point(cx,cy+dy/2),new Point(cx+k,cy-dy/2)});
            TextRenderer.DrawText(g,summary,Font,layout.Summary,waiting ? colors.InputInk : unread ? colors.Unread : colors.Muted,
                layout.Summary.Top==0 ? CaptionFlags : SummaryFlags);
            if(Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(g,new Rectangle(x-D(3),D(2),cx+k+D(7)-x,Height-2*D(2)),colors.Action,BackColor);
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
        private SideChatBranch branch;
        private int TextLeft => Dip(branch == SideChatBranch.None ? SideChatTree.ParentText : SideChatTree.ChildText);
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
                         bool canOpen,Image icon,HudColors colors,Font titleFont,Font detailFont,int dpi,bool sideChat,bool group,SideChatBranch position) {
            if (Text==title && Agent==agent && Detail==detail && TimeText==time && AccessibleDescription==description &&
                Indicator==indicator && CanOpen==canOpen && Image==icon && Colors==colors && TitleFont==titleFont &&
                DetailFont==detailFont && LayoutDpi==dpi && side==sideChat && groupHead==group && branch==position) return;
            if (Text!=title || Agent!=agent || Detail!=detail || TimeText!=time || Indicator!=indicator || CanOpen!=canOpen || TitleFont!=titleFont || DetailFont!=detailFont || LayoutDpi!=dpi || side!=sideChat || groupHead!=group || branch!=position) heights.Clear();
            branch=position;
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
            int width = Math.Max(1, rowWidth - TextLeft - Dip(32));
            return TextRenderer.MeasureText(graphics, Text, TitleFont, new Size(width, int.MaxValue), TitleFlags);
        }
        private const TextFormatFlags SingleLine = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        private string StatusBadge => Indicator switch {
            SessionIndicator.Attention => "待输入",
            SessionIndicator.CompletedUnread => "完成未读",
            _ => null
        };
        private (string Text, Rectangle Badge, Rectangle Label, Rectangle Stamp, int Height) LayoutDetail(Graphics g,int width,int top) {
            int left=TextLeft, right=Math.Max(left+1,width-Dip(8));
            string badge=StatusBadge;
            string text=Detail;
            if(badge!=null) {
                text=side ? Agent+" 侧聊" : groupHead ? Agent+" 主会话" : Agent;
                if(side && !CanOpen) text+=" · 主会话不可用";
            }
            Size Measure(string value) => TextRenderer.MeasureText(g,value,DetailFont,Size.Empty,SingleLine);
            var stampSize=Measure(TimeText);
            var labelSize=Measure(text);
            int line=Math.Max(stampSize.Height,labelSize.Height)+(badge!=null ? Dip(4) : 0);
            int badgeWidth=badge==null ? 0 : Measure(badge).Width+Dip(12);
            int indent=badge!=null ? badgeWidth+Dip(7) : Indicator==SessionIndicator.Running ? Dip(18) : 0;
            int labelLeft=left+indent;
            bool stacked=labelLeft+labelSize.Width+Dip(8)+stampSize.Width>right;
            int labelWidth=Math.Max(1,right-labelLeft-(stacked ? 0 : stampSize.Width+Dip(8)));
            int labelHeight=stacked ? Math.Max(line,TextRenderer.MeasureText(g,text,DetailFont,new Size(labelWidth,int.MaxValue),TitleFlags).Height) : line;
            int stampY=stacked ? top+labelHeight+Dip(2) : top;
            var stamp=new Rectangle(Math.Max(left,right-stampSize.Width),stampY,Math.Min(right-left,stampSize.Width),line);
            return (text,new Rectangle(left,top,badgeWidth,line),new Rectangle(labelLeft,top,labelWidth,labelHeight),stamp,stamp.Bottom-top);
        }

        private void DrawStatusBadge(Graphics g,Rectangle badge) {
            bool input=Indicator==SessionIndicator.Attention;
            using var path=MetricPill.Outline(badge,Dip(6));
            using var fill=new SolidBrush(input ? Colors.InputSurface : Colors.UnreadSurface);
            g.FillPath(fill,path);
            TextRenderer.DrawText(g,StatusBadge,DetailFont,badge,input ? Colors.InputInk : Colors.Unread,
                SingleLine|TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
        }

        public int ContentHeight() => ContentHeight(Width);
        public int ContentHeight(int width) {
            if (heights.TryGetValue(width,out int cached)) return cached;
            using var graphics=CreateGraphics();
            int height=Dip(side ? 8 : 12)+TitleSize(graphics,width).Height+Dip(6)+LayoutDetail(graphics,width,0).Height+Dip(groupHead ? 4 : side ? 8 : 12);
            if (heights.Count>=2) heights.Clear();
            heights[width]=height;
            return height;
        }
        private void DrawAgentIcon(Graphics g, int top) {
            if (Image == null) return;
            int size = Dip(20);
            var saved = g.Save();
            try {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(Image, new Rectangle(Dip(6), top, size, size),
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
            int left = TextLeft, top = Dip(side ? 8 : 12), titleHeight = TitleSize(g,Width).Height;
            if (branch != SideChatBranch.None)
                SideChatTree.Draw(g,Colors.Line,LayoutDpi,top+TitleFont.Height/2,Height,branch==SideChatBranch.Through);
            else
                DrawAgentIcon(g, top + Math.Max(0,(TitleFont.Height - Dip(20))/2));
            TextRenderer.DrawText(g, Text, TitleFont, new Rectangle(left, top, Math.Max(1, Width-left-Dip(32)), titleHeight),
                ForeColor, TitleFlags);
            int detailY = top + titleHeight + Dip(6);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var detail=LayoutDetail(g,Width,detailY);
            int mid=detailY+detail.Badge.Height/2;
            if (Indicator == SessionIndicator.Running) {
                indicatorBounds=new Rectangle(left,mid-Dip(13)/2,Dip(14),Dip(13));
                DrawRunning(g);
            } else if (detail.Badge.Width>0) {
                DrawStatusBadge(g,detail.Badge);
            }
            TextRenderer.DrawText(g,detail.Text,DetailFont,detail.Label,Colors.Muted,TitleFlags|TextFormatFlags.VerticalCenter);
            TextRenderer.DrawText(g,TimeText,DetailFont,detail.Stamp,Colors.Muted,SingleLine|TextFormatFlags.Right|TextFormatFlags.VerticalCenter);
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
