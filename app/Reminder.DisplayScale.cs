using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Security;
using System.Windows.Forms;
using Microsoft.Win32;

namespace JieShou {
    public static class HudDisplayScale {
        private static readonly Dictionary<string,Size> panels=new Dictionary<string,Size>(StringComparer.OrdinalIgnoreCase);
        public static readonly int[] Percentages={100,125,150,175,200,225,250,300};
        internal static void Refresh() => panels.Clear();

        public static Size PanelMillimeters(byte[] edid) {
            if(edid==null || edid.Length<128 || edid[0]!=0 || edid[7]!=0) return Size.Empty;
            for(int i=1;i<=6;i++) if(edid[i]!=255) return Size.Empty;
            if(edid[21]>0 && edid[22]>0) return new Size(edid[21]*10,edid[22]*10);
            // Some portable screens omit both base-block dimensions but include
            // the physical image size in their preferred detailed timing.
            for(int i=54;i+18<=126;i+=18) {
                if(edid[i]==0 && edid[i+1]==0) continue;
                int w=edid[i+12]+((edid[i+14]&0xf0)<<4), h=edid[i+13]+((edid[i+14]&15)<<8);
                if(w>0 && h>0) return new Size(w,h);
            }
            return Size.Empty;
        }
        private static Size ReadPanel(string id) {
            if(panels.TryGetValue(id,out var size)) return size;
            var parts=id.Split('#');
            if(parts.Length>=3 && parts[0].EndsWith(@"\DISPLAY",StringComparison.OrdinalIgnoreCase)) {
                try {
                    using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\DISPLAY\"+parts[1]+"\\"+parts[2]+@"\Device Parameters");
                    size=PanelMillimeters(key?.GetValue("EDID") as byte[]);
                } catch(Exception ex) when(ex is IOException || ex is UnauthorizedAccessException || ex is SecurityException) { }
            }
            return panels[id]=size;
        }
        public static int AutoDpi(Size pixels,Size mm,Size work,int systemDpi,int rawDpi) {
            double ppi=rawDpi;
            if(Math.Min(mm.Width,mm.Height)>=50 && Math.Max(mm.Width,mm.Height)<=4000) {
                double diagonal=Math.Sqrt((double)mm.Width*mm.Width+(double)mm.Height*mm.Height);
                double density=25.4*Math.Sqrt((double)pixels.Width*pixels.Width+(double)pixels.Height*pixels.Height)/diagonal;
                if(density>=50 && density<=700) ppi=density;
            }
            if(ppi<50 || ppi>700) return systemDpi;
            // Round to 12.5% steps. Limit only the automatic increase so a
            // small work area still has space for the list and its controls.
            double room=Math.Min(Math.Min(work.Width/540.0,work.Height/540.0),2.0);
            int limit=(int)Math.Floor(room*8)*12;
            return Math.Max(systemDpi,Math.Min(limit,(int)Math.Round(ppi/12)*12));
        }
        public static int SystemDpi(Screen screen) => HudDisplayIds.DpiAt(screen.Bounds.Left,screen.Bounds.Top);
        public static int Automatic(Screen screen) {
            var bounds=screen.Bounds;
            return AutoDpi(bounds.Size,ReadPanel(HudDisplayIds.For(screen.DeviceName)),screen.WorkingArea.Size,
                SystemDpi(screen),HudDisplayIds.RawDpiAt(bounds.Left,bounds.Top));
        }
        public static int For(Screen screen,HudAppearance appearance) {
            string id=HudDisplayIds.For(screen.DeviceName);
            if(appearance.DisplayScales.TryGetValue(id,out int percent)) {
                if(percent==-1) return SystemDpi(screen);
                if(Array.IndexOf(Percentages,percent)>=0) return (int)Math.Round(96*percent/100.0);
            }
            return Automatic(screen);
        }
    }
}
