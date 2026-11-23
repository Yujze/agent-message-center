using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace JieShou {
    public sealed class SessionListPanel : FlowLayoutPanel {
        private readonly Timer timer=new Timer {Interval=15};
        private readonly Stopwatch clock=new Stopwatch();
        private readonly Dictionary<Control,int> starts=new Dictionary<Control,int>();
        private readonly Dictionary<Control,int> ends=new Dictionary<Control,int>();
        private Dictionary<Control,int> before;
        private bool placing;
        public bool IsReordering => timer.Enabled;
        public SessionListPanel() {
            DoubleBuffered=true;
            timer.Tick+=(s,e)=>Frame();
        }
        // Compositing the children's native windows avoids flashing the background
        // between two moves while keeping hit testing and accessibility on the real rows.
        protected override CreateParams CreateParams {
            get { var p=base.CreateParams; p.ExStyle|=0x02000000; return p; }
        }
        public void CaptureOrder(bool animate) {
            before=null;
            if (animate && Visible && SessionActivityAnimation.MotionAllowed)
                before=Controls.Cast<Control>().Where(c=>c is LocalRow || c is SideChatToggle).ToDictionary(c=>c,c=>c.Top-AutoScrollPosition.Y);
            if (timer.Enabled) Finish();
        }
        public void CommitOrder() {
            if (before==null) return;
            var previous=before; before=null;
            int offset=AutoScrollPosition.Y;
            foreach(Control c in Controls) {
                int target=c.Top-offset;
                if (!previous.TryGetValue(c,out int from) || from==target) continue;
                starts[c]=from; ends[c]=target;
            }
            if (ends.Count==0) return;
            clock.Restart(); timer.Start(); Frame();
        }
        private void Frame() {
            double t=Math.Min(1,clock.Elapsed.TotalMilliseconds/205.0);
            if (t>=1 || !Visible || !SessionActivityAnimation.MotionAllowed) { Finish(); return; }
            double remaining=(1-t)*(1-t)*(1-t);
            placing=true;
            try {
                int offset=AutoScrollPosition.Y;
                foreach (var entry in ends) {
                    var c=entry.Key;
                    if (!c.IsDisposed) c.Top=offset+entry.Value+(int)Math.Round((starts[c]-entry.Value)*remaining);
                }
            } finally { placing=false; }
        }
        private void Finish() {
            timer.Stop(); clock.Stop();
            placing=true;
            try {
                foreach(var entry in ends)
                    if (!entry.Key.IsDisposed && entry.Key.Parent==this) entry.Key.Top=entry.Value+AutoScrollPosition.Y;
            } finally { placing=false; starts.Clear(); ends.Clear(); }
        }
        protected override void OnLayout(LayoutEventArgs e) {
            if (placing) return;
            base.OnLayout(e);
            if (timer!=null && timer.Enabled) {
                // An unchanged poll can request layout halfway through a move.
                // Retain the same clock when the flow layout still has the same destinations.
                foreach (var entry in ends) {
                    if (entry.Key.IsDisposed || entry.Key.Top-AutoScrollPosition.Y!=entry.Value) {
                        timer.Stop(); starts.Clear(); ends.Clear(); return;
                    }
                }
                Frame();
            }
        }
        protected override void OnScroll(ScrollEventArgs e) {
            if (timer.Enabled) Finish();
            base.OnScroll(e);
        }
        protected override void OnVisibleChanged(EventArgs e) {
            if (!Visible && timer!=null && timer.Enabled) Finish();
            base.OnVisibleChanged(e);
        }
        protected override void Dispose(bool disposing) {
            if (disposing) timer.Dispose();
            base.Dispose(disposing);
        }
    }
}
