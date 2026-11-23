using System;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    public sealed class AppearanceDialog : Form {
        private const int ContentWidth=488, ContentHeight=543;
        private readonly AppearanceChoices mode=new AppearanceChoices(AppearanceChoiceStyle.Text,"极简模式","丰富模式");
        private readonly AppearanceChoices theme=new AppearanceChoices(AppearanceChoiceStyle.Theme,"夜紫","深海","云白");
        private readonly AppearanceChoices shape=new AppearanceChoices(AppearanceChoiceStyle.Shape,"胶囊","圆角","直角");
        private readonly AppearanceFontBox family=new AppearanceFontBox();
        private readonly AppearanceSlider size=new AppearanceSlider {Minimum=12,Maximum=20,LargeChange=2};
        private readonly AppearanceSlider opacity=new AppearanceSlider {Minimum=70,Maximum=100,LargeChange=5};
        private readonly HudButton color=new HudButton {Field=true}, clear=new HudButton {Text="随主题"};
        private readonly HudButton save=new HudButton {Text="保存",Primary=true,DialogResult=DialogResult.OK};
        private readonly HudButton cancel=new HudButton {Text="取消",Field=true,DialogResult=DialogResult.Cancel};
        private readonly HudButton reset=new HudButton {Text="恢复默认"};
        private readonly MetricPill sample=new MetricPill {TabStop=false,Cursor=Cursors.Default,Values=new[]{"","","3","6","3"},
            Name="appearance-preview",AccessibleRole=AccessibleRole.Graphic};
        private readonly AppearancePreview preview=new AppearancePreview();
        private readonly Label previewLabel=LabelFor("胶囊预览");
        private readonly Label[] labels={LabelFor("胶囊模式"),LabelFor("主题"),LabelFor("形状"),LabelFor("强调色"),LabelFor("字体"),LabelFor("字号"),LabelFor("不透明度")};
        private readonly Label sizeValue=LabelFor(""), opacityValue=LabelFor("");
        private readonly Label saveError=new Label {Text="保存失败，请检查本机应用数据目录。",Visible=false,
            Name="appearance-save-error",TextAlign=ContentAlignment.MiddleLeft};
        private readonly Panel divider=new Panel(), footerLine=new Panel();
        private readonly HudScrollBar fontScroll, pageScroll;
        private int dpi;
        private bool loading, choosingColor;
        private string accent;
        private Font uiFont, captionFont, previewFont;
        private HudColors colors;
        public HudAppearance Selection { get; private set; }

        private static Label LabelFor(string text) => new Label {Text=text,TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false};
        public AppearanceDialog(HudAppearance initial,int ownerDpi,System.Collections.IDictionary icons) {
            var running=new PillTally();
            running.Add("Codex"); running.Add("Codex"); running.Add("DSH");
            sample.Breakdown=new[]{new PillTally(),new PillTally(),running};
            sample.AgentIcons=icons;
            dpi=ownerDpi; Text="浮窗外观"; AccessibleName=Text; Name="appearance-dialog";
            FormBorderStyle=FormBorderStyle.FixedDialog; StartPosition=FormStartPosition.Manual;
            ShowInTaskbar=true; ShowIcon=false; MaximizeBox=false; MinimizeBox=false; AutoScaleMode=AutoScaleMode.None;
            DoubleBuffered=true;
            var installed=FontFamily.Families;
            try { family.Items.AddRange(installed.Select(f=>f.Name).Distinct().OrderBy(n=>n).ToArray()); }
            finally { foreach(var f in installed) f.Dispose(); }
            mode.Name="appearance-mode"; mode.AccessibleName="胶囊模式";
            shape.Name="appearance-shape"; theme.Name="appearance-theme"; family.Name="appearance-font";
            size.Name="appearance-size"; opacity.Name="appearance-opacity"; color.Name="appearance-accent";
            save.Name="appearance-save"; cancel.Name="appearance-cancel"; reset.Name="appearance-reset";
            shape.AccessibleName="形状"; theme.AccessibleName="主题"; family.AccessibleName="字体";
            size.AccessibleName="字号（像素）"; opacity.AccessibleName="不透明度（百分比）";
            sizeValue.TextAlign=opacityValue.TextAlign=ContentAlignment.MiddleRight;
            preview.Controls.AddRange(new Control[]{previewLabel,sample});
            Controls.AddRange(labels);
            Controls.AddRange(new Control[]{preview,mode,theme,shape,color,clear,divider,family,size,sizeValue,opacity,opacityValue,
                footerLine,reset,cancel,save,saveError});
            var interactive=new Control[]{mode,theme,shape,color,clear,family,size,opacity,reset,cancel,save};
            for(int i=0;i<interactive.Length;i++) interactive[i].TabIndex=i;
            fontScroll=new HudScrollBar(family.Options); pageScroll=new HudScrollBar(this);
            AcceptButton=save; CancelButton=cancel;
            save.Click+=(s,e)=>Close(); cancel.Click+=(s,e)=>Close();
            mode.Changed+=(s,e)=>RefreshPreview();
            theme.Changed+=(s,e)=>RefreshPreview(); shape.Changed+=(s,e)=>RefreshPreview();
            family.SelectedIndexChanged+=(s,e)=>RefreshPreview();
            size.ValueChanged+=(s,e)=>RefreshPreview(); opacity.ValueChanged+=(s,e)=>RefreshPreview();
            color.Click+=(s,e)=>{
                using var picker=new ColorDialog {FullOpen=true, Color=colors.Accent};
                choosingColor=true;
                bool wasTopMost=TopMost;
                try {
                    TopMost=false;
                    if(picker.ShowDialog(this)!=DialogResult.OK) return;
                    accent=ColorTranslator.ToHtml(Color.FromArgb(picker.Color.R,picker.Color.G,picker.Color.B));
                } finally {
                    choosingColor=false;
                    if(!IsDisposed) { TopMost=wasTopMost; Activate(); }
                }
                RefreshPreview();
            };
            clear.Click+=(s,e)=>{accent="";RefreshPreview();};
            reset.Click+=(s,e)=>SetControls(new HudAppearance());
            DpiChanged+=(s,e)=>{
                dpi=e.DeviceDpiNew;
                BeginInvoke((Action)(()=>{
                    if (IsDisposed) return;
                    LayoutAtDpi();
                    var work=Screen.FromControl(this).WorkingArea;
                    FitTo(work);
                    Location=ClampTo(Location,work);
                    RefreshPreview();
                }));
            };
            LayoutAtDpi(); SetControls(initial);
        }
        public void OpenBeside(Form hud) {
            var work = Screen.FromControl(hud).WorkingArea;
            // Bounds include the non-client frame. Scroll on small work areas so
            // the Save and Cancel buttons remain reachable.
            FitTo(work);
            var anchor = hud.Bounds;
            int gap = D(8);
            int left = anchor.Right + gap;
            if (left + Width > work.Right) left = anchor.Left - gap - Width;
            int top = anchor.Top + (anchor.Height - Height) / 2;
            if (left < work.Left) {
                left = anchor.Left + (anchor.Width - Width) / 2;
                if (anchor.Bottom + gap + Height <= work.Bottom) top = anchor.Bottom + gap;
                else if (anchor.Top - gap - Height >= work.Top) top = anchor.Top - gap - Height;
            }
            Location = ClampTo(new Point(left,top),work);
            TopMost = true;
            Show(hud);
            FocusEditor();
        }

        private void FitTo(Rectangle work) {
            AutoScroll = true;
            AutoScrollMinSize = new Size(D(ContentWidth-20),D(ContentHeight));
            Size = new Size(Math.Min(Width,work.Width),Math.Min(Height,work.Height));
        }

        private Point ClampTo(Point p, Rectangle work) => new Point(
            Math.Clamp(p.X,work.Left,Math.Max(work.Left,work.Right-Width)),
            Math.Clamp(p.Y,work.Top,Math.Max(work.Top,work.Bottom-Height)));

        public void FocusEditor() {
            if (choosingColor) return;
            if (!Visible) Show();
            BringToFront();
            Activate();
        }

        public void ShowSaveError() {
            saveError.Visible = true;
            save.Focus();
        }

        private int D(int n) => (int)Math.Round(n*dpi/96.0);
        private void SetControls(HudAppearance a) {
            loading=true;
            try {
                mode.SelectedItem=a.PillMode; shape.SelectedItem=a.Shape; theme.SelectedItem=a.Theme;
                if(!family.Items.Contains(a.Family)) family.Items.Insert(0,a.Family);
                family.SelectedItem=a.Family; size.Value=a.Size; opacity.Value=a.Opacity; accent=a.Accent;
            } finally { loading=false; }
            RefreshPreview();
        }
        private void Place(Control c,int x,int y,int w,int h) => c.SetBounds(D(x),D(y),D(w),D(h));
        private void LayoutAtDpi() {
            SuspendLayout();
            try {
                AutoScrollPosition=Point.Empty;
                var oldUi=uiFont; var oldCaption=captionFont;
                Font=uiFont=new Font("Microsoft YaHei UI",D(14),FontStyle.Regular,GraphicsUnit.Pixel);
                previewLabel.Font=captionFont=new Font("Microsoft YaHei UI",D(13),FontStyle.Bold,GraphicsUnit.Pixel);
                oldUi?.Dispose(); oldCaption?.Dispose();
                ClientSize=new Size(D(ContentWidth),D(ContentHeight));
                Place(preview,24,16,440,104); Place(previewLabel,16,9,80,22);
                int[] rows={135,182,229,276,344,391,438};
                for(int i=0;i<rows.Length;i++) Place(labels[i],26,rows[i],80,36);
                Place(mode,116,rows[0],348,36);
                Place(theme,116,rows[1],348,36); Place(shape,116,rows[2],348,36);
                Place(color,116,rows[3],144,34); Place(clear,268,rows[3],72,34);
                Place(divider,24,327,440,1); Place(family,116,rows[4],348,36);
                family.DropDownHeight=D(228);
                Place(size,116,rows[5],266,36); Place(sizeValue,388,rows[5],74,36);
                Place(opacity,116,rows[6],266,36); Place(opacityValue,388,rows[6],74,36);
                Place(footerLine,24,489,440,1); Place(reset,19,498,84,34);
                Place(cancel,296,498,76,34); Place(save,382,498,82,34);
                Place(saveError,24,474,440,15);
            } finally { ResumeLayout(true); }
        }

        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr handle,int attr,ref int value,int size);
        private void CaptionTheme() {
            if (!IsHandleCreated || colors==null) return;
            int dark=Selection.Theme=="云白" ? 0 : 1;
            int face=ColorTranslator.ToWin32(colors.Surface), ink=ColorTranslator.ToWin32(colors.Ink);
            DwmSetWindowAttribute(Handle,20,ref dark,4);
            DwmSetWindowAttribute(Handle,35,ref face,4);
            DwmSetWindowAttribute(Handle,36,ref ink,4);
        }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); CaptionTheme(); }

        private void RefreshPreview() {
            if(loading) return;
            Selection=new HudAppearance {PillMode=mode.SelectedItem,Shape=shape.SelectedItem,Theme=theme.SelectedItem,Family=(string)family.SelectedItem,
                Size=size.Value,Opacity=opacity.Value,Accent=accent};
            colors=new HudColors(Selection); BackColor=colors.Surface; ForeColor=colors.Ink;
            CaptionTheme();
            preview.Palette=colors; preview.LayoutDpi=dpi; preview.BackColor=colors.Surface;
            previewLabel.BackColor=colors.Track; previewLabel.ForeColor=colors.Muted;
            divider.BackColor=footerLine.BackColor=colors.Divider;
            mode.Style(colors,dpi); theme.Style(colors,dpi); shape.Style(colors,dpi);
            family.LayoutDpi=dpi; family.Palette=colors; family.BackColor=colors.Chrome; family.ForeColor=colors.Ink;
            // Only the font field and the sample use the chosen family. Editing
            // appearance must not shift the other labels or buttons.
            if(previewFont==null || previewFont.OriginalFontName!=Selection.Family || previewFont.Size!=D(14)) {
                var old=previewFont;
                family.Font=previewFont=new Font(Selection.Family,D(14),FontStyle.Regular,GraphicsUnit.Pixel);
                old?.Dispose();
            }
            family.ItemHeight=Math.Max(D(32),family.Font.Height+D(4));
            fontScroll.Palette=colors; pageScroll.Palette=colors;
            foreach(var button in new[]{color,clear,save,cancel,reset}) {
                button.LayoutDpi=dpi; button.Palette=colors; button.BackColor=colors.Surface;
                button.ForeColor=button==clear || button==reset ? colors.Muted : colors.Ink;
                button.Invalidate();
            }
            color.Text=ColorTranslator.ToHtml(colors.Accent);
            color.Swatch=colors.Accent; color.AccessibleName="选择强调色 "+color.Text;
            clear.Enabled=!String.IsNullOrEmpty(accent);
            sizeValue.Text=size.Value+" px"; opacityValue.Text=opacity.Value+"%";
            size.AccessibleDescription=sizeValue.Text; opacity.AccessibleDescription=opacityValue.Text;
            foreach(var slider in new[]{size,opacity}) {
                slider.BackColor=colors.Surface; slider.Palette=colors; slider.LayoutDpi=dpi; slider.Invalidate();
            }
            sample.BackColor=colors.Track; sample.Appearance=Selection; sample.Colors=colors; sample.LayoutDpi=dpi;
            sample.PreviewOpacity=true;
            sample.AccessibleName="预览 "+sample.Caption(true);
            Size desired=sample.MeasureForWidth(preview.Width-D(12));
            sample.SetBounds((preview.Width-desired.Width)/2,D(64)-desired.Height/2,desired.Width,desired.Height);
            family.Invalidate(); preview.Invalidate(true);
        }

        protected override void Dispose(bool disposing) {
            base.Dispose(disposing);
            if(disposing) { previewFont?.Dispose(); captionFont?.Dispose(); uiFont?.Dispose(); }
        }
    }
}
