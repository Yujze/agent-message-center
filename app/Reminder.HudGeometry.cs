using System;
using System.Drawing;

namespace JieShou {
    public enum DockEdge { Top, Bottom, Left, Right }

    public readonly struct HudDock {
        public static readonly string[] Labels = {
            "上边靠左","上边居中","上边靠右","下边靠左","下边居中","下边靠右",
            "左边靠上","左边居中","左边靠下","右边靠上","右边居中","右边靠下"
        };
        public DockEdge Edge { get; }
        public int Third { get; }
        public bool Vertical => Edge==DockEdge.Left || Edge==DockEdge.Right;
        public int Anchor => Edge switch {
            DockEdge.Top => Third, DockEdge.Bottom => 6+Third, DockEdge.Left => 3*Third, _ => 3*Third+2
        };
        public string Label => Labels[(int)Edge*3+Third];
        public HudDock(DockEdge edge,int third) { Edge=edge; Third=Math.Clamp(third,0,2); }
        public static HudDock FromLabel(string label) {
            int index=Array.IndexOf(Labels,label);
            if(index<0) index=5;
            return new HudDock((DockEdge)(index/3),index%3);
        }
        public static HudDock FromAnchor(int anchor,bool vertical) {
            int slot=HudGeometry.DockSlot(anchor,vertical);
            return vertical ? new HudDock(slot%3==0 ? DockEdge.Left : DockEdge.Right,slot/3)
                            : new HudDock(slot/3==0 ? DockEdge.Top : DockEdge.Bottom,slot%3);
        }
        public static HudDock At(Point release, Rectangle work, DockEdge previous) {
            // Work areas use exclusive right/bottom coordinates. Treat both outermost pixels equally.
            int x=Math.Clamp(release.X-work.Left,0,work.Width-1), y=Math.Clamp(release.Y-work.Top,0,work.Height-1);
            int bottom=work.Height-1-y, right=work.Width-1-x;
            int closest=Math.Min(Math.Min(y,bottom),Math.Min(x,right));
            int prior=previous switch { DockEdge.Top=>y, DockEdge.Bottom=>bottom, DockEdge.Left=>x, _=>right };
            var edge=prior==closest ? previous : y==closest ? DockEdge.Top : bottom==closest ? DockEdge.Bottom :
                x==closest ? DockEdge.Left : DockEdge.Right;
            bool vertical=edge==DockEdge.Left || edge==DockEdge.Right;
            return new HudDock(edge,vertical ? 3*y/work.Height : 3*x/work.Width);
        }
    }

    public static class HudGeometry {
        public static Rectangle Place(Rectangle work, Size requested, int dpi, int anchor,
                                      bool dragged, bool right, bool bottom, double dx, double dy) {
            int width=Math.Clamp(requested.Width,1,work.Width), height=Math.Clamp(requested.Height,1,work.Height);
            int margin=(int)Math.Round(12*dpi/96.0);
            double x=dragged ? (right ? work.Right-width-Math.Round(dx*dpi/96) : work.Left+Math.Round(dx*dpi/96)) :
                Preset(work.Left,work.Width-width,anchor%3,margin);
            double y=dragged ? (bottom ? work.Bottom-height-Math.Round(dy*dpi/96) : work.Top+Math.Round(dy*dpi/96)) :
                Preset(work.Top,work.Height-height,anchor/3,margin);
            return new Rectangle((int)Math.Round(Math.Clamp(x,work.Left,work.Right-width)),
                (int)Math.Round(Math.Clamp(y,work.Top,work.Bottom-height)),width,height);
        }
        private static double Preset(int start,int room,int slot,int margin) =>
            start+(slot==0 ? margin : slot==1 ? room/2.0 : room-margin);

        // Keep the former nine anchor IDs readable in existing settings. The
        // middle band maps to the conventional right or bottom docking edge.
        public static int DockSlot(int anchor,bool vertical) {
            if(anchor<0 || anchor>8) anchor=8;
            int row=anchor/3, col=anchor%3;
            return vertical ? row*3+(col==0 ? 0 : 2) : (row==0 ? 0 : 6)+col;
        }
        public static int NearestDock(Rectangle bounds,Rectangle work,bool vertical) {
            double x=(bounds.Left+bounds.Width/2.0-work.Left)/work.Width;
            double y=(bounds.Top+bounds.Height/2.0-work.Top)/work.Height;
            int third=Math.Clamp((int)Math.Floor(3*(vertical ? y : x)),0,2);
            return vertical ? 3*third+(x<.5 ? 0 : 2) : third+(y<.5 ? 0 : 6);
        }
        public static Rectangle Dock(Rectangle work,Size requested,int anchor,bool vertical) {
            anchor=DockSlot(anchor,vertical);
            int w=Math.Clamp(requested.Width,1,work.Width), h=Math.Clamp(requested.Height,1,work.Height);
            int x=vertical ? (anchor%3==0 ? work.Left : work.Right-w) :
                work.Left+(int)Math.Round((anchor%3+.5)*work.Width/3-w/2.0);
            int y=!vertical ? (anchor/3==0 ? work.Top : work.Bottom-h) :
                work.Top+(int)Math.Round((anchor/3+.5)*work.Height/3-h/2.0);
            return new Rectangle(Math.Clamp(x,work.Left,work.Right-w),Math.Clamp(y,work.Top,work.Bottom-h),w,h);
        }

        public static bool OpensForward(Rectangle pill,Rectangle work,bool vertical) => vertical
            ? pill.Left-work.Left<=work.Right-pill.Right : pill.Top-work.Top<=work.Bottom-pill.Bottom;

        public static Rectangle Expand(Rectangle pill, Size panel, Rectangle work, bool vertical, int dpi) {
            panel=new Size(Math.Clamp(panel.Width,1,work.Width),Math.Clamp(panel.Height,1,work.Height));
            int edge=(int)Math.Round(48*dpi/96.0);
            return new Rectangle(Axis(pill.Left,pill.Width,panel.Width,work.Left,work.Right,vertical,edge),
                Axis(pill.Top,pill.Height,panel.Height,work.Top,work.Bottom,!vertical,edge),panel.Width,panel.Height);
        }
        private static int Axis(int start,int before,int after,int low,int high,bool primary,int edge) {
            int near=start-low, far=high-start-before;
            // Grow into the freer side. Across it, preserve a docked edge or
            // center the panel on a free-floating pill.
            int result=primary || Math.Min(near,far)<=edge ? (near<=far ? start : start+before-after)
                : start+(before-after)/2;
            return Math.Clamp(result,low,high-after);
        }
    }
}
