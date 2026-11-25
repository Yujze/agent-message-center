using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // Both directions traverse the same timeline: 0 is the pill, 1 the live list.
    // Lay out the live panel once; its window region exposes the rows as the curtain moves.
    internal sealed class PanelReveal : NativeWindow, IDisposable {
        private const int DurationMs = 290;
        private readonly Form host;
        private readonly MetricPill pill;
        private readonly PanelCorners corners;
        private readonly Control band;
        private readonly Timer timer = new Timer { Interval = 15 };
        private readonly Stopwatch clock = new Stopwatch();
        private Rectangle pillBounds, panelBounds, segmentBounds, displayedBounds;
        private int pillRadius, panelRadius, segmentRadius, displayedRadius;
        private double phase, segmentPhase;
        private byte opacity;
        private Bitmap compact;
        private bool overlayVisible;
        internal bool Active { get; private set; }
        internal bool Closing { get; private set; }
        internal event EventHandler Collapsed;

        internal PanelReveal(Form host, MetricPill pill, Control band, PanelCorners corners) {
            this.host = host;
            this.pill = pill;
            this.band = band;
            this.corners = corners;
            timer.Tick += (s,e) => Step();
            host.VisibleChanged += VisibilityChanged;
            host.HandleDestroyed += HandleLost;
        }

        private bool CapturePill(Rectangle bounds) {
            pillBounds = bounds;
            pill.Size = bounds.Size;
            pillRadius = (int)Math.Round(pill.CornerRadius);
            opacity = (byte)Math.Round(255 * pill.Appearance.Opacity / 100.0);
            try {
                if (Handle == IntPtr.Zero) CreateHandle(new CreateParams {
                    Parent = host.Handle, Style = unchecked((int)0x80000000),
                    ExStyle = 0x080800A0 // NOACTIVATE | LAYERED | TOOLWINDOW | TRANSPARENT
                });
                compact?.Dispose();
                compact = pill.RenderFrame();
                return true;
            } catch (ExternalException) { Cancel(); return false; }
        }

        internal void Begin() {
            if (Closing) { ChangeDirection(false); return; }
            if (Active || !host.Visible || !pill.Visible || !SessionActivityAnimation.MotionAllowed) return;
            if (!CapturePill(host.Bounds)) return;
            phase = 0;
            if (!PaintPill()) { Cancel(); return; }
            displayedBounds = pillBounds;
            displayedRadius = pillRadius;
            ChangeDirection(false);
            // The outgoing pill covers the surface switch and initial list layout.
            var empty = new Region();
            empty.MakeEmpty();
            host.Region = empty;
        }

        internal bool RollUp(Rectangle bounds) {
            if (!host.Visible || !band.Visible || !SessionActivityAnimation.MotionAllowed) return false;
            if (Closing) return true;
            if (!Active) { phase = 1; displayedBounds = panelBounds = host.Bounds; displayedRadius = panelRadius; }
            if (!CapturePill(bounds)) return false;
            ChangeDirection(true);
            if (phase <= 0) Finish();
            else Play();
            return true;
        }

        private void StartSegment() {
            segmentPhase = phase;
            segmentBounds = displayedBounds;
            segmentRadius = displayedRadius;
            clock.Restart();
        }

        private void ChangeDirection(bool closing) {
            Active = true;
            Closing = closing;
            StartSegment();
        }

        internal void SetTarget(Rectangle bounds, int cornerRadius) {
            if (Active && !Closing && timer.Enabled && (bounds != panelBounds || cornerRadius != panelRadius)) StartSegment();
            panelBounds = bounds;
            panelRadius = cornerRadius;
            if (!Active) Apply(bounds, cornerRadius);
        }

        internal void Play() {
            if (!Active || timer.Enabled) return;
            Apply(segmentBounds, segmentRadius);
            clock.Restart();
            timer.Start();
        }

        private static double Ease(double t) {
            double left = 1 - Math.Clamp(t, 0, 1);
            return 1 - left * left * left * (4 - 3 * left);
        }
        private static int Blend(int a, int b, double t) => a + (int)Math.Round((b - a) * t);
        // Normalize just the remaining stretch of the curve after a reversal or resize.
        private double Amount(bool primary) {
            double end = Closing ? 0 : 1;
            double Progress(double t) => Ease(primary ? t : (t-.10)/.85);
            double from = Progress(segmentPhase), range = end - from;
            if (Math.Abs(range) > 1e-8) return (Progress(phase) - from) / range;
            return segmentPhase == end ? 1 : (phase - segmentPhase) / (end - segmentPhase);
        }

        private void Step() {
            double elapsed = clock.Elapsed.TotalMilliseconds / DurationMs;
            phase = Math.Clamp(segmentPhase + (Closing ? -elapsed : elapsed), 0, 1);
            if ((Closing ? phase <= 0 : phase >= 1) || !host.Visible || !SessionActivityAnimation.MotionAllowed) {
                Finish(); return;
            }
            var end = Closing ? pillBounds : panelBounds;
            double x = Amount(pill.Vertical), y = Amount(!pill.Vertical);
            var rect = Rectangle.FromLTRB(Blend(segmentBounds.Left,end.Left,x), Blend(segmentBounds.Top,end.Top,y),
                Blend(segmentBounds.Right,end.Right,x), Blend(segmentBounds.Bottom,end.Bottom,y));
            Apply(rect, Blend(segmentRadius, Closing ? pillRadius : panelRadius, pill.Vertical ? x : y));
            if (!PaintPill()) Finish();
        }

        private bool PaintPill() {
            byte alpha = (byte)Math.Round(opacity * (1 - Ease(phase * 2)));
            if (alpha == 0) { HideOverlay(); return true; }
            if (PillWindowSurface.Upload(Handle, compact, alpha) != 0) return false;
            overlayVisible = SetWindowPos(Handle, IntPtr.Zero, pillBounds.Left, pillBounds.Top, 0, 0, overlayVisible ? 0x15u : 0x55u);
            return overlayVisible;
        }

        private void Apply(Rectangle bounds, int r) {
            // Keep text laid out at the final desktop coordinates. Only expose the
            // part reached by the moving edge, including right- and bottom-origin reveals.
            if (host.Bounds != panelBounds) host.Bounds = panelBounds;
            if (band.Width != panelBounds.Width) band.Width = panelBounds.Width;
            var viewport = Rectangle.Intersect(bounds,panelBounds);
            viewport.Offset(-panelBounds.Left,-panelBounds.Top);
            var colors = pill.Colors;
            corners.Apply(viewport, r, viewport.Top < band.Height ? colors.Chrome : colors.Surface,
                viewport.Bottom <= band.Height ? colors.Chrome : colors.Surface,
                (byte)Math.Round(255 * host.Opacity));
            // Paint exposed child regions in this frame. No RDW_INVALIDATE: rows already on screen stay intact.
            if (Active && displayedBounds != bounds)
                RedrawWindow(host.Handle, IntPtr.Zero, IntPtr.Zero, 0x0100 | 0x0080); // UPDATENOW | ALLCHILDREN
            displayedBounds = bounds;
            displayedRadius = r;
        }

        internal void Finish() {
            if (!Active) return;
            bool collapsed = Closing;
            timer.Stop();
            phase = collapsed ? 0 : 1;
            try {
                var end = collapsed ? pillBounds : panelBounds;
                if (!end.IsEmpty && host.IsHandleCreated && !host.Disposing) {
                    Apply(end, collapsed ? pillRadius : panelRadius);
                    if (collapsed) {
                        if (host.Visible) PaintPill();
                        // Let the normal compact layout take over under the final overlay.
                        Active = Closing = false;
                        Collapsed?.Invoke(this, EventArgs.Empty);
                    }
                }
            } finally { Cancel(); }
        }

        private void HideOverlay() {
            if (overlayVisible && Handle != IntPtr.Zero) ShowWindow(Handle, 0);
            overlayVisible = false;
        }
        internal void Cancel() {
            timer.Stop();
            clock.Reset();
            HideOverlay();
            compact?.Dispose();
            compact = null;
            Active = Closing = false;
        }
        private void VisibilityChanged(object sender, EventArgs e) { if (!host.Visible) Finish(); }
        private void HandleLost(object sender, EventArgs e) {
            Cancel();
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
        public void Dispose() {
            host.VisibleChanged -= VisibilityChanged;
            host.HandleDestroyed -= HandleLost;
            HandleLost(this, EventArgs.Empty);
            timer.Dispose();
        }
        [DllImport("user32")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
        [DllImport("user32")] private static extern bool RedrawWindow(IntPtr hwnd, IntPtr rect, IntPtr region, uint flags);
        [DllImport("user32")] private static extern bool ShowWindow(IntPtr h, int command);
    }
}
