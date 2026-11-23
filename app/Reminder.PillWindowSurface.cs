using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // The HWND and its child controls retain input, accessibility and focus.
    // Only the collapsed window's pixels are submitted directly to the compositor.
    public sealed class PillWindowSurface : IDisposable {
        private readonly Form host;
        private readonly MetricPill pill;
        private readonly Control grip;
        private readonly PanelCorners corners;
        private readonly PanelReveal reveal;
        private bool active, pending, disposed;
        public bool IsActive => active;
        public bool IsRevealing => reveal.Active;
        public bool IsRollingUp => reveal.Closing;
        public event EventHandler RolledUp {
            add { reveal.Collapsed += value; }
            remove { reveal.Collapsed -= value; }
        }
        public int LastError { get; private set; }

        public PillWindowSurface(Form host,MetricPill pill,Control grip,Control band) {
            this.host=host; corners=new PanelCorners(host); this.pill=pill; this.grip=grip;
            reveal=new PanelReveal(host,pill,band,corners);
            grip.MouseEnter+=VisualChanged; grip.MouseLeave+=VisualChanged;
            grip.MouseCaptureChanged+=VisualChanged;
            pill.GotFocus+=VisualChanged; pill.LostFocus+=VisualChanged;
            host.VisibleChanged+=VisualChanged;
        }

        private void VisualChanged(object sender,EventArgs e) {
            if (!active || pending || disposed || host.Disposing || !host.Visible || !host.IsHandleCreated) return;
            pending=true;
            host.BeginInvoke((Action)(()=>{
                pending=false;
                if (active && !disposed && !host.IsDisposed && host.Visible && pill.Visible &&
                    pill.Size==host.ClientSize) Present();
            }));
        }

        private const int ExtendedStyle=-20, Layered=0x80000;
        private void SetLayered(bool value) {
            int style=GetWindowLong(host.Handle,ExtendedStyle);
            int next=value ? style|Layered : style&~Layered;
            if (style!=next) SetWindowLong(host.Handle,ExtendedStyle,next);
        }

        public void UseControls(double opacity) {
            if (active || reveal.Closing) reveal.Begin();
            if (active) {
                active=false;
                SetLayered(false);
                host.Invalidate(true);
            }
            if (host.Opacity!=opacity) host.Opacity=opacity;
        }

        public void SetPanelBounds(Rectangle bounds,int radius) => reveal.SetTarget(bounds,radius);
        public void PlayReveal() => reveal.Play();
        public bool RollUp(Rectangle bounds) => reveal.RollUp(bounds);
        public void FinishReveal() => reveal.Finish();
        public void CancelReveal() { if (reveal.Active) reveal.Cancel(); }

        public void Present() {
            if (disposed || pill.Width<2 || pill.Height<2) return;
            corners.Hide();
            if (!active) {
                host.Region=null;
                host.Opacity=1.0;
                // SetLayeredWindowAttributes (used by Form.Opacity) and
                // UpdateLayeredWindow cannot be mixed on the same layered style.
                SetLayered(false);
            }
            SetLayered(true);
            using var frame=pill.RenderFrame();
            byte opacity=(byte)Math.Round(255*pill.Appearance.Opacity/100.0);
            LastError=Upload(host.Handle,frame,opacity);
            active=LastError==0;
            if (!active) {
                // Preserve the controls when the desktop cannot accept a layered surface.
                SetLayered(false);
                MetricPill.ShapeWindow(host,pill.CornerRadius);
                host.Opacity=pill.Appearance.Opacity/100.0;
            }
        }

        internal static int Upload(IntPtr hwnd,Bitmap frame,byte opacity) {
            IntPtr dc=CreateCompatibleDC(IntPtr.Zero);
            if (dc==IntPtr.Zero) return Marshal.GetLastWin32Error();
            IntPtr bitmap=IntPtr.Zero, previous=IntPtr.Zero;
            try {
                bitmap=frame.GetHbitmap(Color.FromArgb(0));
                previous=SelectObject(dc,bitmap);
                if (previous==IntPtr.Zero || previous==new IntPtr(-1)) return Marshal.GetLastWin32Error();
                var origin=Point.Empty;
                var size=frame.Size;
                var blend=new Blend { ConstantAlpha=opacity, AlphaFormat=1 };
                return UpdateLayeredWindow(hwnd,IntPtr.Zero,IntPtr.Zero,ref size,dc,ref origin,0,ref blend,2)
                    ? 0 : Marshal.GetLastWin32Error();
            } finally {
                if (previous!=IntPtr.Zero && previous!=new IntPtr(-1)) SelectObject(dc,previous);
                if (bitmap!=IntPtr.Zero) DeleteObject(bitmap);
                DeleteDC(dc);
            }
        }

        public void Dispose() {
            disposed=true;
            reveal.Dispose();
            corners.Dispose();
            grip.MouseEnter-=VisualChanged; grip.MouseLeave-=VisualChanged; grip.MouseCaptureChanged-=VisualChanged;
            pill.GotFocus-=VisualChanged; pill.LostFocus-=VisualChanged; host.VisibleChanged-=VisualChanged;
        }

        [StructLayout(LayoutKind.Sequential,Pack=1)]
        private struct Blend { public byte Operation,Flags,ConstantAlpha,AlphaFormat; }
        [DllImport("user32",EntryPoint="GetWindowLongW")] private static extern int GetWindowLong(IntPtr h,int index);
        [DllImport("user32",EntryPoint="SetWindowLongW")] private static extern int SetWindowLong(IntPtr h,int index,int value);
        [DllImport("user32",SetLastError=true)] private static extern bool UpdateLayeredWindow(IntPtr hwnd,IntPtr screen,IntPtr location,
            ref Size size,IntPtr source,ref Point origin,uint key,ref Blend blend,uint flags);
        [DllImport("gdi32",SetLastError=true)] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32",SetLastError=true)] private static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
        [DllImport("gdi32")] private static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32")] private static extern bool DeleteDC(IntPtr dc);
    }
}
