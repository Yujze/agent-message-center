using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // Both the flow panel and the font options own a Win32 vertical scrollbar.
    // Keep their native scroll range, items, wheel and keyboard navigation.
    public sealed class HudScrollBar : NativeWindow, IDisposable {
        private readonly Control owner;
        private readonly ScrollableControl panel;
        private readonly ListBox choices;
        private HudColors colors;
        private bool hot, held, dragging;
        private int gripOffset;
        private IntPtr previousCapture;
        private readonly Timer repeat = new Timer();

        public HudScrollBar(ScrollableControl panel) : this((Control)panel) {
            this.panel = panel;
            panel.HandleCreated += Attach;
            if (panel.IsHandleCreated) Attach(panel,EventArgs.Empty);
        }
        public HudScrollBar(ListBox choices) : this((Control)choices) {
            this.choices=choices;
            choices.HandleCreated+=Attach;
            if (choices.IsHandleCreated) Attach(choices,EventArgs.Empty);
        }
        private HudScrollBar(Control owner) {
            this.owner = owner;
            owner.HandleDestroyed += Closed;
            owner.Disposed += OwnerDisposed;
            repeat.Tick += RepeatPage;
        }
        public HudColors Palette {
            set { colors = value; Refresh(); }
        }
        public int GutterWidth => GetSystemMetricsForDpi(2,(uint)owner.DeviceDpi); // SM_CXVSCROLL
        private void Attach(object sender, EventArgs e) {
            IntPtr target = owner.Handle;
            if (Handle != target) {
                Closed(null,EventArgs.Empty);
                if (target != IntPtr.Zero) AssignHandle(target);
            }
            Refresh();
        }
        private void Closed(object sender, EventArgs e) {
            StopTracking();
            hot = false;
            if (Handle != IntPtr.Zero) ReleaseHandle();
        }
        private void OwnerDisposed(object sender, EventArgs e) => Dispose();
        public void Dispose() {
            Closed(null,EventArgs.Empty);
            owner.HandleDestroyed -= Closed;
            owner.Disposed -= OwnerDisposed;
            if (panel != null) panel.HandleCreated -= Attach;
            if (choices!=null) choices.HandleCreated-=Attach;
            repeat.Dispose();
        }

        private struct Track {
            public Rectangle Bounds, Thumb;
            public int Min, Last, Page, Value, Travel, Dpi;
        }
        private static int Px(int n,int dpi) => Math.Max(1,(int)Math.Round(n*dpi/96.0));
        private bool Read(out Track t) {
            t = default;
            if (colors == null || Handle == IntPtr.Zero || !IsWindowVisible(Handle)) return false;
            var bar = new BarInfo { Size=Marshal.SizeOf<BarInfo>() };
            var range = new ScrollInfo { Size=Marshal.SizeOf<ScrollInfo>(), Mask=7 };
            if (!GetScrollBarInfo(Handle,ObjVertical,ref bar) || (bar.State[0] & 0x18000) != 0 ||
                !GetScrollInfo(Handle,1,ref range)) return false;
            t.Bounds = bar.Bounds.Rectangle;
            t.Min=range.Min; t.Page=Math.Max(1,(int)range.Page);
            t.Last=range.Max-t.Page+1; t.Value=Math.Clamp(range.Pos,t.Min,Math.Max(t.Min,t.Last));
            if (t.Last <= t.Min || t.Bounds.Width < 2 || t.Bounds.Height < 4) return false;
            t.Dpi = owner.DeviceDpi;
            int pad = Math.Min(Px(3,t.Dpi),t.Bounds.Height/4);
            int length = t.Bounds.Height-2*pad;
            int height = Math.Clamp((int)Math.Round(length*(double)t.Page/(range.Max-t.Min+1)),Math.Min(Px(24,t.Dpi),length-1),length-1);
            t.Travel = length-height;
            int y = t.Bounds.Top+pad+(int)Math.Round(t.Travel*(double)(t.Value-t.Min)/(t.Last-t.Min));
            int width = Math.Min(t.Bounds.Width,Px(hot || held ? 7 : 4,t.Dpi));
            t.Thumb = new Rectangle(t.Bounds.Left+(t.Bounds.Width-width)/2,y,width,height);
            return true;
        }
        private static Color Mix(Color a,Color b,int percent) =>
            Color.FromArgb((a.R*(100-percent)+b.R*percent)/100,(a.G*(100-percent)+b.G*percent)/100,(a.B*(100-percent)+b.B*percent)/100);
        public void Refresh() {
            if (!Read(out var t) || !GetWindowRect(Handle,out var window)) return;
            IntPtr dc=GetWindowDC(Handle);
            if (dc == IntPtr.Zero) return;
            try {
                using var g = Graphics.FromHdc(dc);
                g.TranslateTransform(-window.Left,-window.Top);
                g.SetClip(t.Bounds);
                using var fill = new SolidBrush(owner.BackColor);
                g.FillRectangle(fill,t.Bounds);
                g.SmoothingMode=SmoothingMode.AntiAlias;
                if (hot || held) {
                    var rail = t.Thumb;
                    rail.Y = t.Bounds.Top+Px(2,t.Dpi); rail.Height = Math.Max(1,t.Bounds.Height-2*Px(2,t.Dpi));
                    using var path = MetricPill.Outline(rail,rail.Width/2f);
                    using var track = new SolidBrush(colors.Divider); g.FillPath(track,path);
                }
                using var outline = MetricPill.Outline(t.Thumb,t.Thumb.Width/2f);
                using var thumb = new SolidBrush(held ? colors.Ink : hot ? colors.Muted : Mix(owner.BackColor,colors.Muted,67));
                g.FillPath(thumb,outline);
            } finally { ReleaseDC(Handle,dc); }
        }
        private void ScrollTo(int value,Track t) {
            value = Math.Clamp(value,t.Min,t.Last);
            if (value != t.Value) {
                if (panel != null) panel.AutoScrollPosition = new Point(-panel.AutoScrollPosition.X,value);
                else SendMessage(Handle,LbSetTopIndex,(IntPtr)value,IntPtr.Zero);
            }
            Refresh();
        }
        public bool ScrollKey(Keys key) {
            if (!Read(out var t)) return false;
            int value;
            switch (key) {
                case Keys.PageUp: value=t.Value-t.Page; break;
                case Keys.PageDown: value=t.Value+t.Page; break;
                case Keys.Home: value=t.Min; break;
                case Keys.End: value=t.Last; break;
                default: return false;
            }
            ScrollTo(value,t); return true;
        }
        private void PageAt(Point pt,Track t) {
            if (pt.Y < t.Thumb.Top) ScrollTo(t.Value-t.Page,t);
            else if (pt.Y >= t.Thumb.Bottom) ScrollTo(t.Value+t.Page,t);
        }
        private void RepeatPage(object sender,EventArgs e) {
            repeat.Interval=85;
            if (held && !dragging && Read(out var t) && t.Bounds.Contains(Cursor.Position)) PageAt(Cursor.Position,t);
        }
        private void StopTracking() {
            repeat.Stop();
            if (!held) return;
            held=dragging=false;
            if (GetCapture()==Handle && previousCapture!=Handle) {
                ReleaseCapture();
            }
            previousCapture=IntPtr.Zero;
        }
        private static Point Pointer(Message m,bool client) {
            long xy=m.LParam.ToInt64();
            var pt=new Point((short)xy,(short)(xy>>16));
            if (client) ClientToScreen(m.HWnd,ref pt);
            return pt;
        }
        protected override void WndProc(ref Message m) {
            bool move=m.Msg==MouseMove || m.Msg==NcMouseMove;
            bool down=m.Msg==LeftDown || m.Msg==NcLeftDown || m.Msg==LeftDouble || m.Msg==NcLeftDouble;
            bool up=m.Msg==LeftUp || m.Msg==NcLeftUp;
            if (up && held) {
                Point pt=Pointer(m,m.Msg==LeftUp);
                StopTracking();
                hot=Read(out var track) && track.Bounds.Contains(pt);
                Refresh(); m.Result=IntPtr.Zero; return;
            }
            if (move || down) {
                Point pt=Pointer(m,m.Msg>=MouseMove && m.Msg<=LeftDouble);
                if (Read(out var t) && (held || t.Bounds.Contains(pt))) {
                    if (!hot) {
                        hot=true;
                        const uint leave=2, nonClient=16;
                        var track=new MouseTrack { Size=Marshal.SizeOf<MouseTrack>(), Flags=m.Msg>=MouseMove ? leave : leave|nonClient, Window=Handle };
                        TrackMouseEvent(ref track);
                    }
                    if (down) {
                        dragging=pt.Y>=t.Thumb.Top && pt.Y<t.Thumb.Bottom;
                        gripOffset=pt.Y-t.Thumb.Top;
                        previousCapture=GetCapture(); held=true;
                        if (previousCapture!=Handle) SetCapture(Handle);
                        if (!dragging) { PageAt(pt,t); repeat.Interval=400; repeat.Start(); }
                    } else if (move && held && dragging) {
                        int start=t.Bounds.Top+Math.Min(Px(3,t.Dpi),t.Bounds.Height/4);
                        double fraction=Math.Clamp((pt.Y-gripOffset-start)/(double)t.Travel,0,1);
                        ScrollTo(t.Min+(int)Math.Round(fraction*(t.Last-t.Min)),t);
                    }
                    Refresh(); m.Result=IntPtr.Zero; return;
                }
                if (hot && !held) { hot=false; Refresh(); }
            }
            if (m.Msg==0x0215 || m.Msg==0x001F || (m.Msg==0x0018 && m.WParam==IntPtr.Zero))
                StopTracking(); // capture changed, cancel or hide while dragging
            if (m.Msg==0x02A2 || m.Msg==0x02A3) hot=false;
            int msg=m.Msg;
            base.WndProc(ref m);
            switch (msg) {
                case 0x000F: case 0x0085: case 0x0086: case 0x0047: // paint, non-client paint/activation, resize
                case 0x0115: case 0x020A: case 0x0100: case 0x0101: // scroll, wheel, keyboard
                case LbSetTopIndex: case 0x0186: case 0x0215: case 0x02A2: case 0x02A3:
                    Refresh(); break;
            }
        }
        private const int ObjVertical=-5, LbSetTopIndex=0x0197;
        private const int MouseMove=0x200,LeftDown=0x201,LeftUp=0x202,LeftDouble=0x203;
        private const int NcMouseMove=0xA0,NcLeftDown=0xA1,NcLeftUp=0xA2,NcLeftDouble=0xA3;
        [StructLayout(LayoutKind.Sequential)] private struct Rect {
            public int Left,Top,Right,Bottom;
            public Rectangle Rectangle => Rectangle.FromLTRB(Left,Top,Right,Bottom);
        }
        [StructLayout(LayoutKind.Sequential)] private struct BarInfo {
            public int Size; public Rect Bounds; public int Button,ThumbTop,ThumbBottom,Reserved;
            [MarshalAs(UnmanagedType.ByValArray,SizeConst=6)] public int[] State;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ScrollInfo {
            public int Size,Mask,Min,Max; public uint Page; public int Pos,TrackPos;
        }
        [StructLayout(LayoutKind.Sequential)] private struct MouseTrack {
            public int Size; public uint Flags; public IntPtr Window; public uint HoverTime;
        }
        [DllImport("user32")] private static extern bool GetScrollBarInfo(IntPtr h,int id,ref BarInfo info);
        [DllImport("user32")] private static extern bool GetScrollInfo(IntPtr h,int bar,ref ScrollInfo info);
        [DllImport("user32")] private static extern IntPtr GetWindowDC(IntPtr h);
        [DllImport("user32")] private static extern int ReleaseDC(IntPtr h,IntPtr dc);
        [DllImport("user32")] private static extern bool GetWindowRect(IntPtr h,out Rect rect);
        [DllImport("user32")] private static extern int GetSystemMetricsForDpi(int index,uint dpi);
        [DllImport("user32")] private static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32")] private static extern bool ClientToScreen(IntPtr h,ref Point pt);
        [DllImport("user32")] private static extern bool TrackMouseEvent(ref MouseTrack t);
        [DllImport("user32")] private static extern IntPtr GetCapture();
        [DllImport("user32")] private static extern IntPtr SetCapture(IntPtr h);
        [DllImport("user32")] private static extern bool ReleaseCapture();
        [DllImport("user32")] private static extern IntPtr SendMessage(IntPtr h,int msg,IntPtr w,IntPtr l);
    }
}
