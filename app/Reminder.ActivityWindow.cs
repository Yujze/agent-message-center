using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace JieShou {
    public static class ActivityWindow {
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetPackageFamilyName(IntPtr process, ref uint length, StringBuilder family);

        public static IntPtr Find() {
            foreach (string name in new[] { "ChatGPT", "Codex" }) {
                var processes = Process.GetProcessesByName(name);
                try {
                    foreach (var process in processes) {
                        try {
                            IntPtr handle = process.MainWindowHandle;
                            if (handle == IntPtr.Zero) continue;
                            uint length = 256;
                            var family = new StringBuilder((int)length);
                            if (GetPackageFamilyName(process.Handle, ref length, family) == 0 &&
                                family.ToString().Equals("OpenAI.Codex_2p2nqsd0c76g0", StringComparison.OrdinalIgnoreCase))
                                return handle;
                        } catch (InvalidOperationException) { }
                          catch (System.ComponentModel.Win32Exception) { }
                    }
                } finally {
                    foreach (var process in processes) process.Dispose();
                }
            }
            return IntPtr.Zero;
        }

        public static IntPtr Activate() {
            IntPtr handle = Find();
            if (handle == IntPtr.Zero) return IntPtr.Zero;
            if (IsIconic(handle)) ShowWindowAsync(handle, 9); // SW_RESTORE
            if (GetForegroundWindow() != handle) SetForegroundWindow(handle);
            for (int i = 0; i < 12 && GetForegroundWindow() != handle; i++) Thread.Sleep(20);
            return GetForegroundWindow() == handle ? handle : IntPtr.Zero;
        }

        public static bool Ready(IntPtr handle) {
            foreach (int modifier in new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
                if (GetAsyncKeyState(modifier) < 0) return false;
            return handle != IntPtr.Zero && handle == GetForegroundWindow();
        }
    }
}
