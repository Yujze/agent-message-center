using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Windows.Forms;

namespace JieShou {
    public sealed partial class MetricPill {
        private readonly EdgeButton[] edgeButtons=new EdgeButton[Labels.Length];
        private static readonly string[] EdgeNames={"edge-input","edge-unread","edge-running","edge-total","edge-completed"};
        private static readonly string[] NoticeLabels={"待输入","未读"};
        private Size edgeArea=new Size(int.MaxValue,int.MaxValue);
        internal double? EdgeFraction;
        private double Exposure => Vertical && EdgeFraction.HasValue ? EdgeFraction.Value : (EdgePeek ? 1 : 0);
        private int EdgeCount(int i) => i<Breakdown.Length ? Breakdown[i]?.Total ?? 0 : 0;
        private int Interpolate(int a,int b) => a+(int)Math.Round((b-a)*Exposure);
        private float EdgeRadius {
            get {
                float closed=D(ReminderCount==0 ? 3 : 9);
                float open=Vertical ? D(Appearance.Shape=="直角" ? 0 : 13) : CapsuleRadius(Height);
                return closed+(open-closed)*(float)Exposure;
            }
        }
        public bool EdgeKeyboardFocus => (Focused && ShowFocusCues) ||
            Array.Exists(edgeButtons,b=>b!=null && b.FocusIndicator);

        public string NoticeCaption {
            get {
                var parts=new System.Collections.Generic.List<string>();
                for(int i=0;i<NoticeLabels.Length;i++)
                    if(EdgeCount(i)>0) parts.Add(Labels[i]+" "+EdgeCount(i));
                return parts.Count==0 ? "无提醒" : ReminderCount+" 条提醒，"+String.Join("，",parts);
            }
        }
        // Only active notices occupy space. Painting and native hit targets use the same layout.
        private Size LayoutNotices(Graphics g,bool draw=false,Rectangle[] rows=null) {
            if(ReminderCount==0) {
                var idle=Vertical ? new Size(D(5),D(40)) : new Size(D(40),D(5));
                if(draw) {
                    var bounds=new Rectangle(EdgeOrigin(idle),idle);
                    using var spine=new LinearGradientBrush(bounds,Color.FromArgb(133,156,156),Color.FromArgb(41,62,66),Vertical ? 90f : 0f);
                    g.FillRectangle(spine,bounds);
                }
                return idle;
            }
            using var label=new Font(Appearance.Family,Math.Max(11,Appearance.Size-3)*LayoutDpi/96f,GraphicsUnit.Pixel);
            using var number=new Font(Appearance.Family,(Appearance.Size+2)*LayoutDpi/96f,FontStyle.Bold,GraphicsUnit.Pixel);
            int line=Math.Max(label.Height,number.Height)+D(10), left=D(10), gap=D(9), right=D(9);
            var widths=new int[NoticeLabels.Length];
            var digits=new int[NoticeLabels.Length];
            int totalWidth=0, maxWidth=0, active=0;
            for(int i=0;i<NoticeLabels.Length;i++) {
                if(EdgeCount(i)==0) continue;
                int text=Piece(g,false,NoticeLabels[i],label,Color.Empty,0,0,0,typographic:true);
                digits[i]=Piece(g,false,EdgeCount(i).ToString(),number,Color.Empty,0,0,0,typographic:true);
                widths[i]=left+text+gap+digits[i]+right;
                totalWidth+=widths[i]; maxWidth=Math.Max(maxWidth,widths[i]); active++;
            }
            var size=Vertical ? new Size(maxWidth,active*line) : new Size(totalWidth,line);
            if(!draw && rows==null) return size;
            Point origin=draw ? EdgeOrigin(size) : Point.Empty;
            int offset=0;
            for(int i=0;i<widths.Length;i++) {
                if(widths[i]==0) continue;
                var row=Vertical ? new Rectangle(0,offset,maxWidth,line) : new Rectangle(offset,0,widths[i],line);
                if(rows!=null) rows[i]=row;
                if(draw) {
                    row.Offset(origin);
                    var ink=i==0 ? Colors.InputInk : Colors.Unread;
                    using var stripe=new SolidBrush(ink);
                    g.FillRectangle(stripe,row.Left+D(3),row.Top+D(7),Math.Max(1,D(2)),Math.Max(1,line-2*D(7)));
                    if(offset>0) {
                        using var separator=new Pen(Colors.Divider,Math.Max(1,D(1)));
                        if(Vertical) g.DrawLine(separator,row.Left,row.Top,row.Right-1,row.Top);
                        else g.DrawLine(separator,row.Left,row.Top,row.Left,row.Bottom-1);
                    }
                    Piece(g,true,NoticeLabels[i],label,Colors.Ink,row.Left+left,row.Top,line,typographic:true);
                    Piece(g,true,EdgeCount(i).ToString(),number,ink,row.Right-right-digits[i],row.Top,line,typographic:true);
                }
                offset+=Vertical ? line : row.Width;
            }
            return size;
        }
        private Size MeasureEdge(Graphics g,Size area) {
            edgeArea=area;
            var closed=LayoutNotices(g);
            if(Exposure<=0) return closed;
            var open=MeasureCapsule(g,area);
            return new Size(Interpolate(closed.Width,open.Width),Interpolate(closed.Height,open.Height));
        }
        // Draw and hit-test in the same moving coordinate system on all four edges.
        private Point EdgeOrigin(Size layer) => Vertical
            ? new Point(OpensForward ? 0 : Width-layer.Width,(Height-layer.Height)/2)
            : new Point((Width-layer.Width)/2,OpensForward ? 0 : Height-layer.Height);

        private sealed class EdgeButton : Button {
            internal bool FocusIndicator => Focused && ShowFocusCues;
            protected override void OnPaint(PaintEventArgs e) {
                if(Parent is MetricPill owner && owner.EdgeTab) {
                    using var frame=owner.RenderEdgeFrame();
                    e.Graphics.DrawImageUnscaled(frame,-Left,-Top);
                }
            }
        }
        public Button AddEdgeButton(int index) {
            var button=new EdgeButton {Name=EdgeNames[index],Tag=Labels[index],Visible=false,
                FlatStyle=FlatStyle.Flat,TabStop=true,Cursor=Cursors.Hand};
            button.FlatAppearance.BorderSize=0;
            edgeButtons[index]=button;Controls.Add(button);
            return button;
        }
        public void ArrangeEdgeButtons() {
            if(edgeButtons[0]==null) return;
            var rows=new Rectangle[edgeButtons.Length];
            if(EdgeTab) {
                using var g=CreateGraphics();
                var size=Exposure>=.5 ? MeasureCapsule(g,edgeArea,rows) : LayoutNotices(g,rows:rows);
                var origin=EdgeOrigin(size);
                for(int i=0;i<rows.Length;i++) {
                    if(rows[i].IsEmpty) continue;
                    rows[i].Offset(origin);
                    rows[i]=Rectangle.Intersect(rows[i],ClientRectangle);
                }
                if(DragGrip?.Parent==this) {
                    if(Exposure==1) DragGrip.Bounds=GripBounds(size);
                    DragGrip.Visible=Exposure==1;
                }
            }
            for(int i=0;i<rows.Length;i++) {
                var button=edgeButtons[i];
                if(button==null) continue;
                string value=i<3 ? EdgeCount(i).ToString() : i<Values.Length ? Values[i] : "";
                button.AccessibleName=DisplayLabel(i)+" "+value+" 个会话";
                bool visible=rows[i].Width>0 && rows[i].Height>0;
                if(visible) button.Bounds=rows[i];
                button.Enabled=!EmptyCategory(i);
                button.Visible=visible;
            }
        }

        private GraphicsPath EdgeOutline() {
            var bounds=(RectangleF)ClientRectangle;
            float radius=EdgeRadius;
            float overhang=(float)((1-Exposure)*radius);
            if(Vertical) {
                if(OpensForward) bounds.X-=overhang;
                bounds.Width+=overhang;
            } else {
                if(OpensForward) bounds.Y-=overhang;
                bounds.Height+=overhang;
            }
            return Outline(bounds,radius);
        }
        internal Region EdgeRegion() {
            using var outline=EdgeOutline();
            return new Region(outline);
        }

        private void DrawEdgeFocus(Graphics g) {
            foreach(var b in edgeButtons) if(b!=null && b.Visible && b.FocusIndicator)
                ControlPaint.DrawFocusRectangle(g,Rectangle.Inflate(b.Bounds,-1,-1));
        }
        private Bitmap RenderEdgeFrame() {
            if(!Vertical && Exposure==1) return RenderCapsuleFrame(Size);
            using var surface=new Bitmap(Width,Height,PixelFormat.Format32bppRgb);
            using(var g=Graphics.FromImage(surface)) {
                g.SmoothingMode=SmoothingMode.AntiAlias;
                g.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
                if(Exposure<1) {
                    g.Clear(Colors.Chrome);
                    LayoutNotices(g,draw:true);
                }
                if(Exposure==1) DrawNumberColumn(g,Size,edgeArea.Height);
                else if(Exposure>0) {
                    var open=MeasureCapsule(g,edgeArea);
                    using var panel=new Bitmap(open.Width,open.Height,PixelFormat.Format32bppRgb);
                    using(var pg=Graphics.FromImage(panel)) {
                        pg.SmoothingMode=SmoothingMode.AntiAlias;
                        DrawNumberColumn(pg,open,edgeArea.Height);
                    }
                    using var alpha=new ImageAttributes();
                    alpha.SetColorMatrix(new ColorMatrix {Matrix33=(float)Exposure});
                    g.DrawImage(panel,new Rectangle(EdgeOrigin(open),open),0,0,open.Width,open.Height,GraphicsUnit.Pixel,alpha);
                }
                DrawEdgeFocus(g);
            }
            var frame=new Bitmap(Width,Height,PixelFormat.Format32bppPArgb);
            try {
                using var output=Graphics.FromImage(frame);
                output.SmoothingMode=SmoothingMode.AntiAlias;
                output.PixelOffsetMode=PixelOffsetMode.Half;
                using var texture=new TextureBrush(surface,WrapMode.Clamp);
                using var outline=EdgeOutline();
                output.FillPath(texture,outline);
                return frame;
            } catch { frame.Dispose();throw; }
        }
    }
}
