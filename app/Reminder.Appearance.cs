using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace JieShou {
    public sealed class HudAppearance {
        public static readonly string[] Anchors = {"左上","上中","右上","左中","居中","右中","左下","下中","右下"};
        public string Orientation { get; set; } = "横向";
        public string StartupAnchor { get; set; } = "右下";
        // The original pair also distinguishes the two docking choices at a corner.
        [System.Text.Json.Serialization.JsonIgnore]
        public HudDock StartupDock {
            get => HudDock.FromAnchor(Array.IndexOf(Anchors,StartupAnchor),Orientation=="竖向");
            set { Orientation=value.Vertical ? "竖向" : "横向"; StartupAnchor=Anchors[value.Anchor]; }
        }
        // Empty follows the Windows primary monitor, even when the primary changes.
        public string StartupDisplay { get; set; } = "";
        public bool RememberPosition { get; set; }
        public bool AutoHide { get; set; }
        public HudDragPosition LastDrag { get; set; }
        public string PillMode { get; set; } = "极简模式";
        public string Shape { get; set; } = "胶囊";
        public string Theme { get; set; } = "夜紫";
        public string Family { get; set; } = "Microsoft YaHei UI";
        public int Size { get; set; } = 15;
        public Dictionary<string,int> DisplayScales { get; set; }=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        public int Opacity { get; set; } = 100;
        public string Accent { get; set; } = "";

        public HudAppearance Copy() {
            var copy=(HudAppearance)MemberwiseClone();
            copy.DisplayScales=new Dictionary<string,int>(DisplayScales,StringComparer.OrdinalIgnoreCase);
            return copy;
        }
        private void Normalize() {
            var startup=StartupDock;
            StartupDock=startup;
            StartupDisplay ??= "";
            if (LastDrag!=null && (String.IsNullOrEmpty(LastDrag.Display) || LastDrag.X<0 || LastDrag.Y<0 ||
                !Double.IsFinite(LastDrag.X) || !Double.IsFinite(LastDrag.Y))) LastDrag=null;
            if (LastDrag!=null) LastDrag.Vertical ??= StartupDock.Vertical;
            if (PillMode!="丰富模式") PillMode="极简模式";
            if (Array.IndexOf(new[]{"胶囊","圆角","直角"}, Shape) < 0) Shape = "胶囊";
            if (Array.IndexOf(new[]{"夜紫","深海","云白"}, Theme) < 0) Theme = "夜紫";
            if (String.IsNullOrWhiteSpace(Family) || Family.Length > 96) Family = "Microsoft YaHei UI";
            Size = Math.Clamp(Size, 12, 20);
            var scales=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
            if(DisplayScales!=null) foreach(var entry in DisplayScales) {
                if(!String.IsNullOrWhiteSpace(entry.Key) && (entry.Value==-1 || Array.IndexOf(HudDisplayScale.Percentages,entry.Value)>=0))
                    scales[entry.Key]=entry.Value;
            }
            DisplayScales=scales;
            Opacity = Math.Clamp(Opacity, 70, 100);
            if (!Regex.IsMatch(Accent ?? "", "^#[0-9A-Fa-f]{6}$")) Accent = "";
        }
        public static HudAppearance Load(string path) {
            try {
                var a = JsonSerializer.Deserialize<HudAppearance>(File.ReadAllText(path)) ?? new HudAppearance();
                a.Normalize();
                return a;
            } catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is JsonException) {
                return new HudAppearance();
            }
        }
        public void Save(string path) {
            Normalize();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temp, JsonSerializer.Serialize(this));
                File.Move(temp, path, true);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
    }

    public sealed class HudDragPosition {
        public int? DockSlot { get; set; }
        public bool? Vertical { get; set; }
        public string Display { get; set; }
        public bool Right { get; set; }
        public bool Bottom { get; set; }
        // Logical-pixel distances from the two nearest working-area edges.
        public double X { get; set; }
        public double Y { get; set; }
    }

    public static class HudDisplayIds {
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(long point,uint flags);
        [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor,int type,out uint x,out uint y);
        public static int DpiAt(int x,int y) {
            var monitor=MonitorFromPoint(((long)y<<32)|(uint)x,2);
            return GetDpiForMonitor(monitor,0,out uint dpi,out _)==0 ? (int)dpi : 96;
        }
        internal static int RawDpiAt(int x,int y) {
            var monitor=MonitorFromPoint(((long)y<<32)|(uint)x,2);
            return GetDpiForMonitor(monitor,2,out uint dpi,out _)==0 ? (int)dpi : 0;
        }
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
        private struct DisplayDevice {
            public int Size;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Interface;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Key;
        }
        [DllImport("user32.dll",CharSet=CharSet.Unicode)]
        private static extern bool EnumDisplayDevices(string adapter,uint index,ref DisplayDevice device,uint flags);
        private static readonly Dictionary<string,string> cache=new Dictionary<string,string>();
        public static void Refresh() { cache.Clear();HudDisplayScale.Refresh(); }
        public static string For(string name) {
            if (cache.TryGetValue(name,out var id)) return id;
            var device=new DisplayDevice {Size=Marshal.SizeOf<DisplayDevice>()};
            // A monitor interface survives Windows renumbering DISPLAY1 / DISPLAY2.
            return cache[name]=EnumDisplayDevices(name,0,ref device,1) && !String.IsNullOrWhiteSpace(device.Interface)
                ? device.Interface : name;
        }
    }

    public sealed class HudColors {
        public readonly Color Start, End, Surface, Ink, Muted, Line, Hover, Accent, Action, OnAction;
        public readonly Color Chrome, Track, Selected, Divider, Unread, UnreadSurface;
        public readonly Color InputInk, InputSurface, RunningInk, RunningSurface, VerticalRunningInk;
        public HudColors(HudAppearance a) {
            bool light = a.Theme == "云白", purple = a.Theme == "夜紫";
            Chrome = ColorTranslator.FromHtml(light ? "#F6F7FA" : purple ? "#292735" : "#1D3040");
            Track = ColorTranslator.FromHtml(light ? "#E5E8EE" : purple ? "#1D1C29" : "#14232F");
            Selected = ColorTranslator.FromHtml(light ? "#FFFFFF" : purple ? "#454052" : "#314B60");
            Unread = ColorTranslator.FromHtml(light ? "#315990" : "#B6D8FF");
            UnreadSurface = ColorTranslator.FromHtml(light ? "#DCEBFF" : "#293F5C");
            InputInk = ColorTranslator.FromHtml(light ? "#7B3F12" : "#FFD29D");
            InputSurface = ColorTranslator.FromHtml(light ? "#F8E6D3" : "#594039");
            RunningInk = ColorTranslator.FromHtml(light ? "#344E63" : "#C3D9E9");
            RunningSurface = ColorTranslator.FromHtml(light ? "#E1E9F0" : purple ? "#303543" : "#263D4B");
            VerticalRunningInk = ColorTranslator.FromHtml(light ? "#245F54" : "#AFE3D7");
            Divider = ColorTranslator.FromHtml(light ? "#D8DDE5" : purple ? "#3A3749" : "#304457");
            Start = ColorTranslator.FromHtml(light ? "#F1F5FC" : purple ? "#302042" : "#15324B");
            End = ColorTranslator.FromHtml(light ? "#FFFFFF" : purple ? "#191C30" : "#101D30");
            Surface = ColorTranslator.FromHtml(light ? "#FFFFFF" : purple ? "#202033" : "#152539");
            Ink = ColorTranslator.FromHtml(light ? "#202D43" : "#F7F7FF");
            Muted = ColorTranslator.FromHtml(light ? "#475972" : purple ? "#CABFD8" : "#BCCFE2");
            Line = ColorTranslator.FromHtml(light ? "#C4D0E0" : purple ? "#544B66" : "#3E566F");
            Hover = ColorTranslator.FromHtml(light ? "#E3EAF5" : purple ? "#38344C" : "#233E57");
            Action = ColorTranslator.FromHtml(light ? "#274F83" : purple ? "#DCD0F4" : "#C5E3FF");
            OnAction = ColorTranslator.FromHtml(light ? "#FFFFFF" : "#1D2232");
            Accent = ColorTranslator.FromHtml(String.IsNullOrEmpty(a.Accent) ?
                (light ? "#2762A1" : purple ? "#A5D9FF" : "#7EE0CF") : a.Accent);
        }
    }

    public sealed class PillTally {
        private readonly SortedDictionary<string,int> counts = new SortedDictionary<string,int>(StringComparer.Ordinal);
        public IReadOnlyDictionary<string,int> ByAgent => counts;
        public int Total { get; private set; }
        public void Add(string agent) {
            counts.TryGetValue(agent,out int previous);
            counts[agent] = previous + 1;
            Total++;
        }
    }

    public sealed partial class MetricPill : Button {
        public HudAppearance Appearance { get; set; } = new HudAppearance();
        public HudColors Colors { get; set; }
        public string[] Values { get; set; } = Array.Empty<string>();
        public IDictionary AgentIcons { get; set; }
        public PillTally[] Breakdown { get; set; } = Array.Empty<PillTally>();
        private static readonly string[] Labels = {"待输入","完成未读","进行中","总数","已完成"};
        private string DisplayLabel(int index) => index==3 && !Vertical ? "任务" : Labels[index];
        public string Caption() => Caption(false);
        public string Caption(bool includeAgents) {
            var parts = new System.Collections.Generic.List<string>();
            for (int i=0; i<Values.Length && i<Labels.Length; i++) {
                if (String.IsNullOrEmpty(Values[i])) continue;
                string part=DisplayLabel(i)+" "+Values[i];
                var tally=includeAgents ? Tally(i) : null;
                if (tally!=null && tally.Total>0) {
                    var sources=new List<string>();
                    foreach (var entry in tally.ByAgent) sources.Add(entry.Key+" "+entry.Value);
                    part+="（"+String.Join("、",sources)+"）";
                }
                parts.Add(part);
            }
            return String.Join(" · ",parts);
        }
        private Color PriorityColor() {
            if (Values.Length > 0 && !String.IsNullOrEmpty(Values[0]))
                return Colors.InputInk;
            if (Values.Length > 1 && !String.IsNullOrEmpty(Values[1]))
                return Colors.Unread;
            return Colors.Accent;
        }
        public int LayoutDpi { get; set; } = 96;
        public bool AllowDrag { get; set; }
        public Control DragGrip { get; set; }
        public int GripWidth => D(40);
        public bool Vertical { get; set; }
        public bool OpensForward { get; set; }=true;
        public bool EdgeTab { get; set; }
        public bool EdgePeek { get; set; }
        public int ReminderCount => Breakdown.Length<2 ? 0 : Breakdown[0].Total+Breakdown[1].Total;
        private int VerticalHeaderHeight => D(Appearance.Size+10);
        public Rectangle GripBounds(Size size) => new Rectangle(Vertical ? (size.Width-GripWidth)/2 : 0,0,
            GripWidth,Vertical ? VerticalHeaderHeight : size.Height);
        public bool PreviewOpacity { get; set; }
        public Point RequestedLocation { get; private set; }
        public Point DragPointer { get; private set; }
        public event EventHandler MoveRequested;
        public event EventHandler DragFinished;
        private readonly Rectangle[] statusBounds=new Rectangle[Labels.Length];
        private bool clickEmitted, inactivePress;
        public string ClickedStatus { get; private set; }
        private string StatusAt(Point p) {
            for(int i=0;i<statusBounds.Length;i++) if(statusBounds[i].Contains(p)) return Labels[i];
            return null;
        }
        private bool EmptyCategory(int i) => i>=0 && i!=3 &&
            (EdgeTab && i<3 ? EdgeCount(i)==0 : i<Values.Length && Values[i]=="0");
        private Point down, origin;
        private bool tracking, dragged;
        private int D(double n) => (int)Math.Round(n * LayoutDpi / 96);
        public MetricPill() {
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseMnemonic = false;
            DoubleBuffered = true;
            Cursor = Cursors.Hand;
            AccessibleRole = AccessibleRole.PushButton;
        }
        private const TextFormatFlags Format = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix |
            TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
        private int Piece(Graphics g, bool draw, string text, Font font, Color color, int x, int y, int height, bool typographic=false) {
            if(Vertical || typographic) {
                using var format=StringFormat.GenericTypographic;
                format.LineAlignment=StringAlignment.Center;
                format.FormatFlags|=StringFormatFlags.NoWrap;
                int width=(int)Math.Ceiling(g.MeasureString(text,font,PointF.Empty,format).Width);
                if(draw) {
                    using var brush=new SolidBrush(color);
                    g.DrawString(text,font,brush,new Rectangle(x,y,width+1,height),format);
                }
                return x+width;
            }
            int w = TextRenderer.MeasureText(g,text,font,new Size(int.MaxValue,int.MaxValue),Format).Width;
            if (draw) TextRenderer.DrawText(g,text,font,new Rectangle(x,y,w+1,height),color,Format);
            return x+w;
        }

        private PillTally Tally(int metric) =>
            Appearance.PillMode=="丰富模式" && metric<Breakdown.Length ? Breakdown[metric] : null;

        private int AgentCount(Graphics g,bool draw,KeyValuePair<string,int> entry,Font small,Color ink,int x,int y,int height,bool nameOnly=false) {
            string key=entry.Key=="Qoder" ? (Appearance.Theme=="云白" ? "qoder-light" : "qoder-dark") : entry.Key.ToLowerInvariant();
            var icon=AgentIcons?[key] as Image;
            if (icon!=null) {
                int size=D(Appearance.Size);
                if (draw) {
                    var state=g.Save();
                    g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode=PixelOffsetMode.HighQuality;
                    g.DrawImage(icon,new Rectangle(x,y+(height-size)/2,size,size),0,0,icon.Width,icon.Height,GraphicsUnit.Pixel);
                    g.Restore(state);
                }
                x+=size;
            } else if(!nameOnly) x=Piece(g,draw,entry.Key,small,ink,x,y,height);
            if(nameOnly) return Piece(g,draw,entry.Key,small,ink,x+(icon==null ? 0 : D(4)),y,height);
            return Piece(g,draw,entry.Value.ToString(),small,ink,x+D(2),y,height);
        }

        private int MetricContent(Graphics g,bool draw,int i,Font label,Font number,Font small,int x,int y,int height) {
            if (i>=3) {
                x=Piece(g,draw,Values[i],small,Colors.Muted,x,y,height)+D(3);
                return Piece(g,draw,DisplayLabel(i),small,Colors.Muted,x,y,height);
            }
            Color ink=i==0 ? Colors.InputInk : i==1 ? Colors.Unread : Colors.RunningInk;
            x=Piece(g,draw,Values[i],number,ink,x,y,height)+D(4);
            x=Piece(g,draw,Labels[i],label,ink,x,y,height);
            var tally = Tally(i);
            if (tally==null || tally.Total==0) return x;
            x+=D(6);
            if (draw) {
                using var separator=new Pen(Color.FromArgb(80,ink),Math.Max(1,D(1)));
                int line=D(Appearance.Size-2), top=y+(height-line)/2;
                g.DrawLine(separator,x,top,x,top+line);
            }
            foreach (var entry in tally.ByAgent) {
                x=AgentCount(g,draw,entry,small,ink,x+D(6),y,height);
            }
            return x;
        }

        private Size LayoutMetrics(Graphics g,bool draw,int maxWidth,Rectangle[] rows=null) {
            if(draw && rows==null) rows=statusBounds;
            if(rows!=null) Array.Clear(rows,0,rows.Length);
            using var label = new Font(Appearance.Family,D(Appearance.Size),FontStyle.Regular,GraphicsUnit.Pixel);
            using var number = new Font(Appearance.Family,D(Appearance.Size+2),FontStyle.Bold,GraphicsUnit.Pixel);
            using var small = new Font(Appearance.Family,D(Appearance.Size-1),FontStyle.Regular,GraphicsUnit.Pixel);
            int left=GripWidth, tail=D(32), inset=D(5);
            int height=Math.Max(D(Appearance.Size+12),number.Height+D(2));
            int x=left, y=inset, widest=left;
            bool first=true;
            if (Values.Length==0) widest=Piece(g,draw,Text,label,Colors.Ink,x,y,height);
            for (int i=0; i<Values.Length && i<Labels.Length; i++) {
                if (String.IsNullOrEmpty(Values[i])) continue;
                bool segment=i<3;
                int padding=segment ? D(9) : 0, gap=segment ? D(4) : D(11);
                int width=MetricContent(g,false,i,label,number,small,0,0,height)+2*padding;
                if (!first) {
                    if ((long)x+gap+width+tail > maxWidth) { x=left; y+=height+D(4); }
                    else x+=gap;
                }
                if(rows!=null) rows[i]=new Rectangle(x,y,width,height);
                if (draw) {
                    if (segment) {
                        Color fill=i==0 ? Colors.InputSurface : i==1 ? Colors.UnreadSurface : Colors.RunningSurface;
                        using var path=Outline(new RectangleF(x+.5f,y+.5f,width-1,height-1),D(8));
                        using var brush=new SolidBrush(fill);
                        g.FillPath(brush,path);
                        if (first && Values[i]!="0") {
                            using var edge=new Pen(Color.FromArgb(50,Colors.Ink),Math.Max(1,D(1)));
                            g.DrawPath(edge,path);
                        }
                    }
                    MetricContent(g,true,i,label,number,small,x+padding,y,height);
                }
                x+=width; widest=Math.Max(widest,x);
                first=false;
            }
            return new Size(widest+tail,y+height+inset);
        }

        private void DrawStatusIcon(Graphics g,int metric,Color ink,int x,int cy,int size) {
            var state=g.Save();
            g.TranslateTransform(x,cy-size/2f);
            g.ScaleTransform(size/18f,size/18f);
            using var pen=new Pen(ink,1.7f) {StartCap=LineCap.Round,EndCap=LineCap.Round,LineJoin=LineJoin.Round};
            switch (metric) {
                case 0: // Input prompt
                    g.DrawLines(pen,new[]{new Point(2,3),new Point(16,3),new Point(16,12),new Point(8,12),new Point(4,16),new Point(4,12),new Point(2,12),new Point(2,3)});
                    g.DrawLine(pen,6,7,12,7); break;
                case 1: // Unread envelope
                    g.DrawRectangle(pen,2,4,14,10); g.DrawLines(pen,new[]{new Point(3,5),new Point(9,10),new Point(15,5)}); break;
                case 2:
                    g.DrawLine(pen,4,7,4,12); g.DrawLine(pen,9,3,9,15); g.DrawLine(pen,14,5,14,12); break;
                case 3:
                    for(int row=4;row<=14;row+=5) { g.DrawLine(pen,2,row,3,row); g.DrawLine(pen,7,row,16,row); } break;
                case 4:
                    g.DrawEllipse(pen,2,2,14,14);
                    g.DrawLines(pen,new[]{new Point(5,9),new Point(8,12),new Point(13,6)}); break;
            }
            g.Restore(state);
        }

        private Size LayoutVertical(Graphics g,bool draw,int maxHeight,Rectangle[] rows=null) {
            if(draw && rows==null) rows=statusBounds;
            if(rows!=null) Array.Clear(rows,0,rows.Length);
            using var label=new Font(Appearance.Family,D(Appearance.Size),GraphicsUnit.Pixel);
            using var count=new Font(Appearance.Family,D(Appearance.Size+10),FontStyle.Regular,GraphicsUnit.Pixel);
            using var small=new Font(Appearance.Family,D(Math.Max(12,Appearance.Size-3)),GraphicsUnit.Pixel);
            int top=VerticalHeaderHeight, inset=D(12), gap=D(8);
            if (Values.Length==0) {
                int width=D(144), available=width-2*inset;
                var flags=TextFormatFlags.WordBreak|TextFormatFlags.HorizontalCenter|TextFormatFlags.NoPadding;
                int height=TextRenderer.MeasureText(g,Text,small,new Size(available,int.MaxValue),flags).Height;
                if(draw) TextRenderer.DrawText(g,Text,small,new Rectangle(inset,top,available,height),Colors.Ink,flags);
                return new Size(width,top+height+2*inset);
            }
            int sub=Math.Max(small.Height,D(Appearance.Size))+D(2), footer=2*sub+D(12);
            int numberWidth=D(24), textWidth=D(60);
            for(int i=0;i<Values.Length && i<3;i++) {
                if(String.IsNullOrEmpty(Values[i])) continue;
                numberWidth=Math.Max(numberWidth,Piece(g,false,Values[i],count,Colors.Ink,0,0,0));
                textWidth=Math.Max(textWidth,Piece(g,false,Labels[i],label,Colors.Ink,0,0,0));
                var tally=Tally(i);
                if(tally!=null) foreach(var entry in tally.ByAgent)
                    textWidth=Math.Max(textWidth,AgentCount(g,false,entry,small,Colors.Muted,0,0,sub,tally.ByAgent.Count==1));
            }
            int columnWidth=Math.Max(D(Appearance.PillMode=="丰富模式" ? 103 : 95),numberWidth+gap+textWidth);
            for(int i=3;i<Values.Length && i<5;i++)
                columnWidth=Math.Max(columnWidth,Piece(g,false,Labels[i],small,Colors.Muted,0,0,sub)
                    +gap+Piece(g,false,Values[i],small,Colors.Ink,0,0,sub));
            int col=0,y=top,bottom=top;
            using var divider=new Pen(Colors.Divider,Math.Max(1,D(.6)));
            for(int i=0;i<Values.Length && i<3;i++) {
                if(String.IsNullOrEmpty(Values[i])) continue;
                var tally=Tally(i);
                var sources=new List<(KeyValuePair<string,int> entry,int x,int y)>();
                int sx=0,sy=0;
                if(tally!=null) foreach(var entry in tally.ByAgent) {
                    int item=AgentCount(g,false,entry,small,Colors.Muted,0,0,sub,tally.ByAgent.Count==1);
                    if(sx!=0 && sx+item>columnWidth-numberWidth-gap) { sx=0;sy+=sub; }
                    sources.Add((entry,sx,sy));sx+=item+D(5);
                }
                int block=label.Height+(sources.Count==0 ? 0 : sy+sub+D(2));
                int height=Math.Max(count.Height,block)+D(10);
                if(y>top && (long)y+height+footer>maxHeight) { col++;y=top; }
                int x=inset+col*(columnWidth+gap), textX=x+numberWidth+gap;
                Color ink=EmptyCategory(i) ? Colors.Muted : i==0 ? Colors.InputInk : i==1 ? Colors.Unread : Colors.VerticalRunningInk;
                if(rows!=null) rows[i]=new Rectangle(x,y,columnWidth,height);
                if(draw) {
                    int n=Piece(g,false,Values[i],count,ink,0,0,height);
                    Piece(g,true,Values[i],count,ink,x+(numberWidth-n)/2,y,height);
                    int textY=y+(height-block)/2;
                    Piece(g,true,Labels[i],label,EmptyCategory(i) ? Colors.Muted : Colors.Ink,textX,textY,label.Height);
                    foreach(var s in sources) AgentCount(g,true,s.entry,small,Colors.Muted,textX+s.x,textY+label.Height+D(2)+s.y,sub,tally.ByAgent.Count==1);
                    g.DrawLine(divider,x,y+height-1,x+columnWidth,y+height-1);
                }
                y+=height;bottom=Math.Max(bottom,y);
            }
            var desired=new Size(2*inset+(col+1)*columnWidth+col*gap,bottom+footer);
            for(int i=3;i<Values.Length && i<Labels.Length;i++) {
                int fy=bottom+D(5)+(i-3)*sub;
                if(rows!=null) rows[i]=new Rectangle(inset,fy,desired.Width-2*inset,sub);
                if(!draw) continue;
                Color ink=EmptyCategory(i) ? Colors.Line : Colors.Muted;
                Piece(g,true,Labels[i],small,ink,inset,fy,sub);
                int n=Piece(g,false,Values[i],small,Colors.Muted,0,fy,sub);
                Piece(g,true,Values[i],small,ink,desired.Width-inset-n,fy,sub);
            }
            return desired;
        }

        public Size MeasureForWidth(int maxWidth) => MeasureForArea(new Size(maxWidth,int.MaxValue));
        public Size MeasureForArea(Size area) {
            using var g=CreateGraphics();
            return EdgeTab ? MeasureEdge(g,area) : MeasureCapsule(g,area);
        }
        private Size MeasureCapsule(Graphics g,Size area,Rectangle[] rows=null) => Vertical
            ? LayoutVertical(g,false,area.Height,rows) : LayoutMetrics(g,false,area.Width,rows);
        public int RequiredWidth() => MeasureForWidth(int.MaxValue).Width;
        public static GraphicsPath Outline(RectangleF r, float radius) {
            var path=new GraphicsPath();
            float d=Math.Min(Math.Min(r.Width,r.Height),Math.Max(0,2*radius));
            if (d < 2) { path.AddRectangle(r); return path; }
            path.AddArc(r.Left,r.Top,d,d,180,90); path.AddArc(r.Right-d,r.Top,d,d,270,90);
            path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90); path.AddArc(r.Left,r.Bottom-d,d,d,90,90);
            path.CloseFigure(); return path;
        }
        public static void ShapeWindow(Control control, float radius) {
            using var path = Outline(control.ClientRectangle,radius);
            control.Region = new Region(path);
        }
        // A speech bubble with three recessed finger grooves, shared by both window states.
        public void DrawMessageGrip(Graphics g, Rectangle bounds) => DrawMessageGrip(g,bounds,DragGrip?.Parent==this);
        private void DrawMessageGrip(Graphics g, Rectangle bounds, bool onPill) {
            if (Colors==null || bounds.IsEmpty) return;
            var state=g.Save();
            try {
                g.SmoothingMode=SmoothingMode.AntiAlias;
                float cx=bounds.Left+bounds.Width/2f, cy=bounds.Top+bounds.Height/2f;
                if (DragGrip!=null && DragGrip.Visible &&
                    (DragGrip.Capture || DragGrip.ClientRectangle.Contains(DragGrip.PointToClient(Control.MousePosition)))) {
                    int tile=D(30);
                    using var hover=Outline(new RectangleF(cx-tile/2f,cy-tile/2f,tile,tile),D(8));
                    using var tint=new SolidBrush(Color.FromArgb(DragGrip.Capture ? 48 : 26,Colors.Ink));
                    g.FillPath(tint,hover);
                }
                float side=D(Appearance.Size+6);
                g.TranslateTransform(cx-side/2f,cy-side/2f);
                g.ScaleTransform(side/24f,side/24f);
                using var bubble=new GraphicsPath(FillMode.Alternate);
                bubble.StartFigure();
                bubble.AddLine(6,2,18,2);
                bubble.AddBezier(18,2,21.5f,2,23.5f,4,23.5f,7.5f);
                bubble.AddLine(23.5f,7.5f,23.5f,13.1f);
                bubble.AddBezier(23.5f,13.1f,23.5f,16.6f,21.5f,18.6f,18,18.6f);
                bubble.AddLine(18,18.6f,7.6f,18.6f);
                bubble.AddLine(7.6f,18.6f,2.2f,22);
                bubble.AddLine(2.2f,22,3.1f,18);
                bubble.AddBezier(3.1f,18,1.4f,17.2f,.5f,15.6f,.5f,13.1f);
                bubble.AddLine(.5f,13.1f,.5f,7.5f);
                bubble.AddBezier(.5f,7.5f,.5f,4,2.5f,2,6,2);
                bubble.CloseFigure();
                foreach (float x in new[]{6.1f,10.9f,15.7f}) {
                    using var slot=Outline(new RectangleF(x,6.1f,2.2f,8.2f),1.1f);
                    bubble.AddPath(slot,false);
                }
                var ink=PriorityColor();
                var surface=onPill ? Colors.Start : Colors.Chrome;
                if (Math.Abs(ink.GetBrightness()-surface.GetBrightness())<.22f) ink=Colors.Ink;
                using var brush=new SolidBrush(ink);
                g.FillPath(brush,bubble);
            } finally { g.Restore(state); }
        }
        internal float CornerRadius => EdgeTab ? EdgeRadius : CapsuleRadius(Height);
        private float CapsuleRadius(int height) {
            if (Appearance.Shape=="直角") return 0;
            if (Appearance.Shape=="圆角") return 9f*LayoutDpi/96;
            return Math.Min(height,D(Appearance.Size+22))/2f;
        }

        // Both the regular vertical capsule and a revealed ruler use the same rows.
        private void DrawNumberColumn(Graphics g,Size size,int heightLimit) {
            g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            if(Appearance.Theme=="夜紫") g.Clear(Color.FromArgb(34,39,48));
            else g.Clear(Colors.Chrome);
            float w=D(24), h=D(3);
            var slot=new RectangleF((size.Width-w)/2f,(VerticalHeaderHeight-h)/2f,w,h);
            using var shape=Outline(slot,h/2);
            bool hot=DragGrip?.Parent==this && DragGrip.Visible &&
                (DragGrip.Capture || DragGrip.ClientRectangle.Contains(DragGrip.PointToClient(Control.MousePosition)));
            using var ink=new SolidBrush(Color.FromArgb(hot ? 210 : 125,Colors.Muted));
            g.FillPath(ink,shape);
            LayoutVertical(g,true,heightLimit);
            int x=size.Width-D(16), y=VerticalHeaderHeight/2, wing=D(3), step=OpensForward ? D(2) : -D(2);
            using var pen=new Pen(Colors.Muted,Math.Max(1,1.5f*LayoutDpi/96)) {LineJoin=LineJoin.Round};
            g.DrawLines(pen,new[]{new Point(x-step,y-wing),new Point(x+step,y),new Point(x-step,y+wing)});
        }

        // GDI text does not preserve alpha. Draw content at native resolution on an
        // opaque surface, then apply the silhouette once to produce premultiplied pixels.
        public Bitmap RenderFrame() => EdgeTab ? RenderEdgeFrame() : RenderCapsuleFrame(Size);
        private Bitmap RenderCapsuleFrame(Size size) {
            var bounds=new Rectangle(Point.Empty,size);
            using var content=new Bitmap(size.Width,size.Height,PixelFormat.Format32bppRgb);
            float radius=CapsuleRadius(size.Height), border=Math.Max(1f,LayoutDpi/96f);
            using (var g=Graphics.FromImage(content)) {
                g.SmoothingMode=SmoothingMode.AntiAlias;
                if(Vertical) DrawNumberColumn(g,size,size.Height);
                else {
                    using var bg=new LinearGradientBrush(bounds,Colors.Start,Colors.End,0f);
                    g.FillRectangle(bg,bounds);
                    DrawMessageGrip(g,GripBounds(size),true);
                    LayoutMetrics(g,true,size.Width);
                    int x=size.Width-D(23), y=size.Height/2, wing=D(4), step=OpensForward ? D(2) : -D(2);
                    using var pen=new Pen(Colors.Ink,Math.Max(1f,2f*LayoutDpi/96f));
                    g.DrawLines(pen,new[]{new Point(x-wing,y-step),new Point(x,y+step),new Point(x+wing,y-step)});
                }
                if (Focused && ShowFocusCues) {
                    float inset=3f*LayoutDpi/96;
                    if (size.Width>2*inset && size.Height>2*inset) {
                        using var focus=Outline(new RectangleF(inset,inset,size.Width-2*inset,size.Height-2*inset),Math.Max(0,radius-inset));
                        using var edge=new Pen(Colors.Muted,border);
                        g.DrawPath(edge,focus);
                    }
                }
                if(EdgeTab && Exposure==1) DrawEdgeFocus(g);
            }

            var frame=new Bitmap(size.Width,size.Height,PixelFormat.Format32bppPArgb);
            try {
                using (var g=Graphics.FromImage(frame)) g.DrawImageUnscaled(content,0,0);
                ApplyEdge(frame,radius,border,Colors.Line);
                return frame;
            } catch { frame.Dispose(); throw; }
        }

        // Coverage of a unit pixel in the upper-left quadrant. Only pixels that
        // intersect the arc need integration; mirror the result into all four corners.
        internal static double Coverage(double x,double y,double r) {
            if (x+1<=0 || y+1<=0) return 0;
            double left=Math.Max(0,x), top=Math.Max(0,y);
            double area=(x+1-left)*(y+1-top);
            if (left>=r || top>=r) return area;
            double farX=r-left, farY=r-top, rr=r*r;
            if (farX*farX+farY*farY<=rr) return area;
            double nearX=Math.Max(0,r-x-1), nearY=Math.Max(0,r-y-1);
            if (nearX*nearX+nearY*nearY>=rr) return 0;
            const int samples=16;
            double dy=(y+1-top)/samples, sum=0;
            for (int i=0;i<samples;i++) {
                double d=Math.Max(0,r-(top+(i+.5)*dy));
                double arc=r-Math.Sqrt(Math.Max(0,rr-d*d));
                sum+=Math.Max(0,x+1-Math.Max(left,arc));
            }
            return sum*dy;
        }

        private static void ApplyEdge(Bitmap frame,double radius,double border,Color line) {
            int w=frame.Width, h=frame.Height;
            radius=Math.Min(radius,Math.Min(w,h)/2.0);
            var data=frame.LockBits(new Rectangle(0,0,w,h),ImageLockMode.ReadWrite,PixelFormat.Format32bppPArgb);
            try {
                for (int y=0;y<h;y++) {
                    int edgeY=Math.Min(y,h-1-y);
                    int span=edgeY<border ? (w+1)/2 : Math.Min((w+1)/2,(int)Math.Ceiling(edgeY<radius ? radius : border));
                    var row=IntPtr.Add(data.Scan0,y*data.Stride);
                    for (int x=0;x<span;x++) {
                        double outer=Coverage(x,edgeY,radius);
                        double inner=Math.Min(outer,Coverage(x-border,edgeY-border,Math.Max(0,radius-border)));
                        if (inner>=1) continue;
                        double ring=outer-inner;
                        BlendEdge(row,x,outer,inner,ring,line);
                        if (x!=w-1-x) BlendEdge(row,w-1-x,outer,inner,ring,line);
                    }
                }
            } finally { frame.UnlockBits(data); }
        }

        private static void BlendEdge(IntPtr row,int x,double outer,double inner,double ring,Color line) {
            int pixel=Marshal.ReadInt32(row,x*4);
            int r=(int)Math.Round(((pixel>>16)&255)*inner+line.R*ring);
            int g=(int)Math.Round(((pixel>>8)&255)*inner+line.G*ring);
            int b=(int)Math.Round((pixel&255)*inner+line.B*ring);
            Marshal.WriteInt32(row,x*4,((int)Math.Round(255*outer)<<24)|(r<<16)|(g<<8)|b);
        }
        protected override void OnPaint(PaintEventArgs e) {
            if (Colors==null || Width<2 || Height<2) return;
            e.Graphics.Clear(BackColor);
            using var frame=RenderFrame();
            if (PreviewOpacity && Appearance.Opacity<100) {
                using var attr=new ImageAttributes();
                attr.SetColorMatrix(new ColorMatrix {Matrix33=Appearance.Opacity/100f});
                e.Graphics.DrawImage(frame,ClientRectangle,0,0,Width,Height,GraphicsUnit.Pixel,attr);
            } else e.Graphics.DrawImageUnscaled(frame,0,0);
        }
        protected override void OnMouseDown(MouseEventArgs e) {
            dragged=false;
            clickEmitted=false;
            ClickedStatus=!EdgeTab && e.Button==MouseButtons.Left ? StatusAt(e.Location) : null;
            inactivePress=e.Button==MouseButtons.Left && (EdgeTab
                ? Array.Exists(edgeButtons,b=>b!=null && b.Visible && !b.Enabled && b.Bounds.Contains(e.Location))
                : EmptyCategory(Array.IndexOf(Labels,ClickedStatus)));
            if (AllowDrag && e.Button==MouseButtons.Left) { tracking=true; down=PointToScreen(e.Location); origin=FindForm().Location; }
            base.OnMouseDown(e);
        }
        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            if (!tracking || e.Button!=MouseButtons.Left) return;
            var pos=PointToScreen(e.Location);
            int dx=pos.X-down.X, dy=pos.Y-down.Y;
            if (!dragged && Math.Abs(dx)<D(4) && Math.Abs(dy)<D(4)) return;
            dragged=true;
            DragPointer=pos;
            RequestedLocation=new Point(origin.X+dx,origin.Y+dy);
            MoveRequested?.Invoke(this,EventArgs.Empty);
        }
        protected override void OnMouseUp(MouseEventArgs e) {
            bool moved=dragged && e.Button==MouseButtons.Left;
            if(moved) DragPointer=PointToScreen(e.Location);
            bool activate=e.Button==MouseButtons.Left && !moved && ClickedStatus!=null && ClickedStatus==StatusAt(e.Location);
            tracking=false;
            base.OnMouseUp(e);
            // The native Button can hit-test the layered parent HWND even when the
            // press and release were both delivered to the same painted segment.
            if(activate && !clickEmitted) OnClick(e);
            dragged=false; inactivePress=false; ClickedStatus=null;
            if (moved) DragFinished?.Invoke(this,EventArgs.Empty);
        }
        protected override void OnMouseCaptureChanged(EventArgs e) { tracking=false; base.OnMouseCaptureChanged(e); }
        protected override void OnClick(EventArgs e) {
            if(dragged || inactivePress) return;
            clickEmitted=true; base.OnClick(e);
        }
    }
}
