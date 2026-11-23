using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // The live controls own the interior. Only the fractional arc pixels need
    // compositor surfaces. Moving the bottom strip reveals more rows at native scale.
    internal sealed class PanelCorners : IDisposable {
        private sealed class Strip : NativeWindow {
            private bool shown;
            private Point location;
            internal bool Upload(Form owner, Bitmap image, byte opacity) {
                if (Handle == IntPtr.Zero) CreateHandle(new CreateParams {
                    Parent=owner.Handle, Style=unchecked((int)0x80000000),
                    ExStyle=0x080800A0 // NOACTIVATE | LAYERED | TOOLWINDOW | TRANSPARENT
                });
                return PillWindowSurface.Upload(Handle,image,opacity)==0;
            }
            internal void Place(int x,int y) {
                if (Handle==IntPtr.Zero || (shown && location.X==x && location.Y==y)) return;
                SetWindowPos(Handle,IntPtr.Zero,x,y,0,0,0x15u | (shown ? 0u : 0x40u));
                location=new Point(x,y);
                shown=true;
            }
            internal void Hide() {
                if (shown && Handle!=IntPtr.Zero) ShowWindow(Handle,0);
                shown=false;
            }
            internal void Release() {
                Hide();
                if (Handle!=IntPtr.Zero) DestroyHandle();
            }
        }

        private readonly Form host;
        private readonly Strip upper=new Strip(), lower=new Strip();
        private Size size;
        private int radius;
        private int[] cut;
        private Color top, bottom;
        private byte alpha;
        private bool enabled;
        internal PanelCorners(Form host) {
            this.host=host;
            host.LocationChanged+=Sync; host.VisibleChanged+=Sync; host.HandleDestroyed+=OwnerDestroyed;
        }
        internal void Apply(int r,Color topColor,Color bottomColor,byte opacity) {
            var next=host.ClientSize;
            r=Math.Min(r,Math.Min(next.Width,next.Height)/2);
            if (r<=0) { Hide(); if (host.Region!=null) host.Region=null; return; }
            bool reuse=cut!=null && size.Width==next.Width && r==radius && top==topColor && bottom==bottomColor && alpha==opacity;
            if (enabled && reuse && size==next) return;
            if (!reuse && !RenderStrips(next.Width,r,topColor,bottomColor,opacity)) {
                cut=null;
                Hide();
                MetricPill.ShapeWindow(host,r);
                return;
            }
            using var shape=new GraphicsPath(FillMode.Winding);
            for (int y=0;y<r;) {
                int first=y, inset=cut[y++];
                while (y<r && cut[y]==inset) y++;
                if (2*inset>=next.Width) continue;
                shape.AddRectangle(new Rectangle(inset,first,next.Width-2*inset,y-first));
                shape.AddRectangle(new Rectangle(inset,next.Height-y,next.Width-2*inset,y-first));
            }
            if (next.Height>2*r) shape.AddRectangle(new Rectangle(0,r,next.Width,next.Height-2*r));
            host.Region=new Region(shape);
            size=next; radius=r; top=topColor; bottom=bottomColor; alpha=opacity;
            enabled=true;
            Sync(this,EventArgs.Empty);
        }

        private bool RenderStrips(int width,int r,Color topColor,Color bottomColor,byte opacity) {
            using var topImage=new Bitmap(width,r,PixelFormat.Format32bppPArgb);
            using var bottomImage=new Bitmap(width,r,PixelFormat.Format32bppPArgb);
            cut=new int[r];
            for (int y=0;y<r;y++) {
                for (int x=0;x<r;x++) {
                    int a=(int)Math.Round(255*MetricPill.Coverage(x,y,r));
                    if (a==255) break;
                    cut[y]=x+1;
                    if (a==0) continue;
                    int rx=width-1-x, by=r-1-y;
                    var t=Color.FromArgb(a,topColor); var b=Color.FromArgb(a,bottomColor);
                    topImage.SetPixel(x,y,t); topImage.SetPixel(rx,y,t);
                    bottomImage.SetPixel(x,by,b); bottomImage.SetPixel(rx,by,b);
                }
            }
            return upper.Upload(host,topImage,opacity) && lower.Upload(host,bottomImage,opacity);
        }

        private void Sync(object sender,EventArgs e) {
            if (!enabled) return;
            if (!host.Visible) { upper.Hide(); lower.Hide(); return; }
            upper.Place(host.Left,host.Top);
            lower.Place(host.Left,host.Top+size.Height-radius);
        }
        internal void Hide() { enabled=false; upper.Hide(); lower.Hide(); }
        private void OwnerDestroyed(object sender,EventArgs e) {
            enabled=false; cut=null;
            upper.Release(); lower.Release();
        }
        public void Dispose() {
            host.LocationChanged-=Sync; host.VisibleChanged-=Sync; host.HandleDestroyed-=OwnerDestroyed;
            OwnerDestroyed(this,EventArgs.Empty);
        }
        [DllImport("user32")] private static extern bool ShowWindow(IntPtr h,int command);
        [DllImport("user32")] private static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
    }
}
