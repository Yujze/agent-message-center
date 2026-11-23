using System;
using System.Drawing;
using System.Runtime.InteropServices;

namespace JieShou.Tests {
    public static class ScrollGesture {
        // Send the same non-client press and captured client drag Windows sends to
        // the actual control. The desktop cursor and unrelated windows stay untouched.
        public static void DragToEnd(IntPtr handle, bool combo) {
            if (combo) {
                var info = new ComboInfo { Size = Marshal.SizeOf<ComboInfo>() };
                if (!GetComboBoxInfo(handle,ref info)) throw new Exception("ComboLBox unavailable");
                handle=info.List;
                SendMessage(handle,0x0197,IntPtr.Zero,IntPtr.Zero); // LB_SETTOPINDEX
            }
            var bar = new BarInfo { Size = Marshal.SizeOf<BarInfo>() };
            if (!GetScrollBarInfo(handle,-5,ref bar)) throw new Exception("Vertical scroll area unavailable");
            int x=(bar.Left+bar.Right)/2;
            SendMessage(handle,0x00A1,(IntPtr)7,Pack(new Point(x,bar.Top+bar.Right-bar.Left)));
            var end=new Point(x,bar.Bottom-1);
            ScreenToClient(handle,ref end);
            SendMessage(handle,0x0200,(IntPtr)1,Pack(end));
            SendMessage(handle,0x0202,IntPtr.Zero,Pack(end));
            if (combo && SendMessage(handle,0x018E,IntPtr.Zero,IntPtr.Zero).ToInt64() <= 0)
                throw new Exception("Font scrollbar did not scroll");
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
        [StructLayout(LayoutKind.Sequential)] private struct ComboInfo {
            public int Size; public Rectangle Item,Button; public int State; public IntPtr Combo,Edit,List;
        }
        [DllImport("user32")] private static extern bool GetComboBoxInfo(IntPtr h,ref ComboInfo info);
        [DllImport("user32")] private static extern bool GetScrollBarInfo(IntPtr h,int objectId,ref BarInfo info);
        [DllImport("user32")] private static extern bool ScreenToClient(IntPtr h,ref Point p);
        [DllImport("user32")] private static extern IntPtr SendMessage(IntPtr h,int message,IntPtr w,IntPtr l);
    }
}
