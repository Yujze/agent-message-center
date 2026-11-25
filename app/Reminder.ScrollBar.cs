using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // The borderless content keeps its native ranges, keyboard, wheel and focus scrolling.
    // Its parent clips it to the Win32 client rectangle. Only our sibling rails can paint the gutter.
    public sealed class HudScrollBar : Panel {
        private readonly Panel viewport = new Panel { TabStop=false };
        private readonly Control content;
        private readonly Rail vertical, horizontal;
        private readonly ScrollObserver observer;
        private HudColors palette;
        private bool arranging;

        public HudScrollBar(ScrollableControl content) : this((Control)content) { }
        public HudScrollBar(ListBox content) : this((Control)content) { }
        private HudScrollBar(Control content) {
            this.content=content;
            TabStop=false;
            vertical=new Rail(this,true);
            horizontal=new Rail(this,false);
            viewport.Size=Size.Empty;
            viewport.Controls.Add(content);
            Controls.AddRange(new Control[]{viewport,vertical,horizontal});
            observer=new ScrollObserver(this);
            content.HandleCreated+=ContentCreated;
            content.HandleDestroyed+=ContentDestroyed;
            content.ClientSizeChanged+=ContentChanged;
            content.BackColorChanged+=ContentChanged;
            if(content.IsHandleCreated) ContentCreated(null,EventArgs.Empty);
        }
        public int GutterWidth => GetSystemMetricsForDpi(2,(uint)content.DeviceDpi);
        public HudColors Palette {
            set { palette=value; UpdateRails(); }
        }
        private void ContentCreated(object sender,EventArgs e) {
            observer.AssignHandle(content.Handle);
            UpdateRails();
        }
        private void ContentDestroyed(object sender,EventArgs e) {
            if(observer.Handle!=IntPtr.Zero) observer.ReleaseHandle();
        }
        private void ContentChanged(object sender,EventArgs e) => UpdateRails();
        protected override void OnLayout(LayoutEventArgs e) {
            base.OnLayout(e);
            UpdateRails();
        }
        public void UpdateRails() {
            if(arranging || horizontal==null || IsDisposed || Disposing || content.IsDisposed) return;
            arranging=true;
            try {
                if(content.Bounds!=ClientRectangle) content.Bounds=ClientRectangle;
                var visible=Size.Empty;
                if(content.IsHandleCreated && GetClientRect(content.Handle,out var client))
                    visible=new Size(Math.Clamp(client.Right,0,Width),Math.Clamp(client.Bottom,0,Height));
                viewport.Bounds=new Rectangle(Point.Empty,visible);
                BackColor=viewport.BackColor=content.BackColor;
                vertical.SetBounds(visible.Width,0,Width-visible.Width,visible.Height);
                horizontal.SetBounds(0,visible.Height,visible.Width,Height-visible.Height);
                vertical.Visible=vertical.Width>0 && visible.Height>0;
                horizontal.Visible=horizontal.Height>0 && visible.Width>0;
                vertical.Invalidate(); horizontal.Invalidate();
            } finally { arranging=false; }
        }
        private sealed class ScrollObserver : NativeWindow {
            private readonly HudScrollBar host;
            internal ScrollObserver(HudScrollBar host) { this.host=host; }
            protected override void WndProc(ref Message m) {
                int msg=m.Msg;
                base.WndProc(ref m);
                switch(msg) {
                    case 0x007D: case 0x0047: case 0x0085: // style, position or non-client layout changed
                        host.UpdateRails(); break;
                    case 0x000F: case 0x0114: case 0x0115: case 0x020A: case 0x020E:
                    case 0x0100: case 0x0186: case 0x0197: // key, selection or LB_SETTOPINDEX
                        host.vertical.Invalidate(); host.horizontal.Invalidate(); break;
                }
            }
        }
        public bool ScrollKey(Keys key) {
            if(!vertical.Range(out var t)) return false;
            int target;
            switch(key) {
                case Keys.PageUp: target=t.Pos-t.Page; break;
                case Keys.PageDown: target=t.Pos+t.Page; break;
                case Keys.Home: target=t.Min; break;
                case Keys.End: target=t.Last; break;
                default: return false;
            }
            vertical.ScrollTo(target,t); return true;
        }
        protected override bool ProcessCmdKey(ref Message m,Keys keyData) {
            if(content is ScrollableControl && ScrollKey(keyData)) return true;
            return base.ProcessCmdKey(ref m,keyData);
        }
        protected override void Dispose(bool disposing) {
            if(disposing && observer!=null) {
                content.HandleCreated-=ContentCreated; content.HandleDestroyed-=ContentDestroyed;
                content.ClientSizeChanged-=ContentChanged; content.BackColorChanged-=ContentChanged;
                ContentDestroyed(null,EventArgs.Empty);
            }
            base.Dispose(disposing);
        }

        private struct Track {
            internal Rectangle Thumb;
            internal int Min,Last,Page,Pos,Travel,Pad;
        }
        private sealed class Rail : Control {
            private readonly HudScrollBar host;
            private readonly bool upright;
            private readonly Timer repeat=new Timer();
            private bool held,dragging,hot;
            private int grip;
            internal Rail(HudScrollBar host,bool upright) {
                this.host=host; this.upright=upright;
                Name=upright ? "hud-scroll-vertical" : "hud-scroll-horizontal";
                AccessibleRole=AccessibleRole.ScrollBar;
                AccessibleName=upright ? "垂直滚动条" : "水平滚动条";
                SetStyle(ControlStyles.Selectable,false);
                DoubleBuffered=true; TabStop=false; Visible=false;
                repeat.Tick+=(s,e)=>{ repeat.Interval=85; if(held && !dragging && Range(out var t)) PageAt(PointToClient(MousePosition),t); };
            }
            private int Px(int n) => Math.Max(1,(int)Math.Round(n*DeviceDpi/96.0));
            private int Axis(Point p) => upright ? p.Y : p.X;
            internal bool Range(out Track t) {
                t=default;
                int length=upright ? Height : Width, thickness=upright ? Width : Height;
                if(!Visible || !host.content.IsHandleCreated || length<4 || thickness<1) return false;
                var info=new ScrollInfo {Size=Marshal.SizeOf<ScrollInfo>(),Mask=7};
                if(!GetScrollInfo(host.content.Handle,upright ? 1 : 0,ref info)) return false;
                t.Min=info.Min; t.Page=Math.Max(1,(int)info.Page);
                t.Last=info.Max-t.Page+1;
                if(t.Last<=t.Min) return false;
                t.Pos=Math.Clamp(info.Pos,t.Min,t.Last); t.Pad=Math.Min(Px(3),length/4);
                int span=length-2*t.Pad;
                int size=Math.Clamp((int)Math.Round((double)span*t.Page/(info.Max-t.Min+1)),Math.Min(Px(24),span-1),span-1);
                t.Travel=span-size;
                int offset=t.Pad+(int)Math.Round(t.Travel*(double)(t.Pos-t.Min)/(t.Last-t.Min));
                int breadth=Math.Min(thickness,Px(hot || held ? 7 : 4)), side=(thickness-breadth)/2;
                t.Thumb=upright ? new Rectangle(side,offset,breadth,size) : new Rectangle(offset,side,size,breadth);
                return true;
            }
            protected override void OnPaint(PaintEventArgs e) {
                var colors=host.palette;
                var bg=host.content.BackColor;
                e.Graphics.Clear(bg);
                if(colors==null || !Range(out var t)) return;
                e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
                int breadth=upright ? t.Thumb.Width : t.Thumb.Height;
                if(hot || held) {
                    var rail=upright ? new Rectangle(t.Thumb.X,t.Pad,breadth,Height-2*t.Pad) :
                        new Rectangle(t.Pad,t.Thumb.Y,Width-2*t.Pad,breadth);
                    using var path=MetricPill.Outline(rail,breadth/2f);
                    using var brush=new SolidBrush(colors.Divider);
                    e.Graphics.FillPath(brush,path);
                }
                using var outline=MetricPill.Outline(t.Thumb,breadth/2f);
                using var thumb=new SolidBrush(held ? colors.Ink : hot ? colors.Muted : Color.FromArgb(171,colors.Muted));
                e.Graphics.FillPath(thumb,outline);
            }
            internal void ScrollTo(int value,Track t) {
                value=Math.Clamp(value,t.Min,t.Last);
                if(value!=t.Pos) {
                    if(host.content is ScrollableControl sc) {
                        var old=sc.AutoScrollPosition;
                        sc.AutoScrollPosition=upright ? new Point(-old.X,value) : new Point(value,-old.Y);
                    } else SendMessage(host.content.Handle,0x0197,(IntPtr)value,IntPtr.Zero);
                }
                Invalidate();
            }
            private void PageAt(Point pt,Track t) {
                if(!ClientRectangle.Contains(pt)) return;
                int pos=Axis(pt), start=Axis(t.Thumb.Location);
                if(pos<start) ScrollTo(t.Pos-t.Page,t);
                else if(pos>=start+(upright ? t.Thumb.Height : t.Thumb.Width)) ScrollTo(t.Pos+t.Page,t);
            }
            protected override void OnMouseDown(MouseEventArgs e) {
                base.OnMouseDown(e);
                if(e.Button!=MouseButtons.Left || !Range(out var t)) return;
                int pos=Axis(e.Location), start=Axis(t.Thumb.Location);
                dragging=pos>=start && pos<start+(upright ? t.Thumb.Height : t.Thumb.Width);
                grip=pos-start; held=true; Capture=true;
                if(!dragging) { PageAt(e.Location,t); repeat.Interval=400; repeat.Start(); }
                Invalidate();
            }
            protected override void OnMouseMove(MouseEventArgs e) {
                base.OnMouseMove(e);
                if(!held || !dragging || !Range(out var t)) return;
                double ratio=Math.Clamp((Axis(e.Location)-grip-t.Pad)/(double)t.Travel,0,1);
                ScrollTo(t.Min+(int)Math.Round(ratio*(t.Last-t.Min)),t);
            }
            protected override void OnMouseUp(MouseEventArgs e) {
                base.OnMouseUp(e);
                if(e.Button==MouseButtons.Left && held) Capture=false;
            }
            protected override void OnMouseCaptureChanged(EventArgs e) {
                base.OnMouseCaptureChanged(e);
                if(!Capture) { repeat.Stop(); held=dragging=false; Invalidate(); }
            }
            protected override void OnVisibleChanged(EventArgs e) {
                base.OnVisibleChanged(e);
                if(!Visible && held) Capture=false;
            }
            protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hot=true; Invalidate(); }
            protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot=false; Invalidate(); }
            protected override void OnMouseWheel(MouseEventArgs e) {
                if(!host.content.IsHandleCreated) return;
                var pt=PointToScreen(e.Location);
                SendMessage(host.content.Handle,0x020A,(IntPtr)(e.Delta<<16),(IntPtr)((pt.X&0xffff)|(pt.Y<<16)));
                if(e is HandledMouseEventArgs handled) handled.Handled=true;
            }
            protected override void Dispose(bool disposing) { if(disposing) repeat.Dispose(); base.Dispose(disposing); }
        }

        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left,Top,Right,Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct ScrollInfo {
            public int Size,Mask,Min,Max; public uint Page; public int Pos,TrackPos;
        }
        [DllImport("user32")] private static extern bool GetScrollInfo(IntPtr h,int bar,ref ScrollInfo info);
        [DllImport("user32")] private static extern bool GetClientRect(IntPtr h,out Rect rect);
        [DllImport("user32")] private static extern int GetSystemMetricsForDpi(int index,uint dpi);
        [DllImport("user32")] private static extern IntPtr SendMessage(IntPtr h,int msg,IntPtr w,IntPtr l);
    }
}
