using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    // The HUD accepts clicks without activating. Deactivate therefore cannot
    // detect a click back into the application that already owns the focus.
    public sealed class OutsideClickDismissal : IDisposable {
        private readonly Control panel;
        private readonly MouseProc callback;
        private IntPtr hook;
        private int generation;
        private bool pending;
        public event EventHandler OutsidePressed;

        public OutsideClickDismissal(Control panel) {
            this.panel = panel;
            callback = OnMouse;
            panel.VisibleChanged += Sync;
            panel.HandleCreated += Sync;
            panel.HandleDestroyed += Stop;
            Sync(this, EventArgs.Empty);
        }

        private void Sync(object sender, EventArgs e) {
            if (!panel.Visible || !panel.IsHandleCreated || panel.Disposing) {
                Stop(sender, e);
            } else if (hook == IntPtr.Zero) {
                hook = SetWindowsHookEx(14 /* WH_MOUSE_LL */, callback, GetModuleHandle(null), 0);
            }
        }

        private void Stop(object sender, EventArgs e) {
            if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
            generation++;
            pending = false;
        }

        private IntPtr OnMouse(int code, IntPtr message, IntPtr data) {
            // Resolve the hit before a menu can close or the foreground can change.
            if (code == 0 && message == (IntPtr)0x0201 /* WM_LBUTTONDOWN */ && !pending)
                CheckPress(WindowFromPoint(Marshal.PtrToStructure<Point>(data)));
            return CallNextHookEx(IntPtr.Zero, code, message, data);
        }

        private void CheckPress(IntPtr target) {
            if (hook == IntPtr.Zero || pending || target == IntPtr.Zero || panel.Disposing) return;
            GetWindowThreadProcessId(target, out uint pid);
            if (pid == Environment.ProcessId) return;
            pending = true;
            int current = generation;
            panel.BeginInvoke((Action)(() => {
                if (current != generation) return;
                pending = false;
                OutsidePressed?.Invoke(this, EventArgs.Empty);
            }));
        }

        public void Dispose() {
            panel.VisibleChanged -= Sync;
            panel.HandleCreated -= Sync;
            panel.HandleDestroyed -= Stop;
            Stop(this, EventArgs.Empty);
        }

        private delegate IntPtr MouseProc(int code, IntPtr message, IntPtr data);
        [DllImport("user32", EntryPoint="SetWindowsHookExW")] private static extern IntPtr SetWindowsHookEx(int id, MouseProc proc, IntPtr module, uint thread);
        [DllImport("kernel32", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32")] private static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    }
}
