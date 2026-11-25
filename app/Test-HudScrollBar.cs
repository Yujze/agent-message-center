using System;
using System.Drawing;
using System.Runtime.InteropServices;

namespace JieShou.Tests {
    public static class ScrollGesture {
        [DllImport("user32")] public static extern IntPtr GetDesktopWindow();
        public static Rectangle NativeTrackAfterRepaint(IntPtr handle) {
            RedrawWindow(handle,IntPtr.Zero,IntPtr.Zero,0x501); // INVALIDATE | UPDATENOW | FRAME
            var bar = new BarInfo { Size = Marshal.SizeOf<BarInfo>() };
            if (!GetScrollBarInfo(handle,-5,ref bar)) throw new Exception("Vertical scroll area unavailable");
            return Rectangle.FromLTRB(bar.Left,bar.Top,bar.Right,bar.Bottom);
        }
        public static void DragClient(IntPtr handle, Point down, Point distance) {
            var release=new Point(down.X+distance.X,down.Y+distance.Y);
            ClientToScreen(handle,ref release);
            SendMessage(handle,0x0201,(IntPtr)1,Pack(down));
            if (!distance.IsEmpty) {
                var move=release;
                ScreenToClient(handle,ref move);
                SendMessage(handle,0x0200,(IntPtr)1,Pack(move));
            }
            ScreenToClient(handle,ref release);
            SendMessage(handle,0x0202,IntPtr.Zero,Pack(release));
        }
        [DllImport("user32")] private static extern bool ClientToScreen(IntPtr h,ref Point p);
        private static IntPtr Pack(Point p) => (IntPtr)((p.X & 0xffff) | (p.Y << 16));
        [StructLayout(LayoutKind.Sequential)] private struct BarInfo {
            public int Size,Left,Top,Right,Bottom,Button,ThumbTop,ThumbBottom,Reserved;
            [MarshalAs(UnmanagedType.ByValArray,SizeConst=6)] public int[] State;
        }
        [DllImport("user32")] private static extern bool RedrawWindow(IntPtr h,IntPtr update,IntPtr region,uint flags);
        [DllImport("user32")] private static extern bool GetScrollBarInfo(IntPtr h,int objectId,ref BarInfo info);
        [DllImport("user32")] private static extern bool ScreenToClient(IntPtr h,ref Point p);
        [DllImport("user32")] private static extern IntPtr SendMessage(IntPtr h,int message,IntPtr w,IntPtr l);
    }
}
