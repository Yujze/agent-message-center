using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JieShou {
    public sealed class AppearanceDialog : Form {
        private const int WindowWidth=864, WindowHeight=510;
        private readonly AppearanceChoices page=new AppearanceChoices(AppearanceChoiceStyle.Navigation,"胶囊外观","位置与方向","关于");
        private readonly Panel about=new Panel {Name="appearance-about",AccessibleName="关于智能体消息中心"};
        private readonly PictureBox logo=new PictureBox {SizeMode=PictureBoxSizeMode.Zoom,AccessibleName="AMC 徽标",TabStop=false};
        private readonly Label wordmark=LabelFor("AMC"), englishName=LabelFor("Agent Message Center"), chineseName=LabelFor("智能体消息中心");
        private readonly Label versionLabel=LabelFor("");
        private readonly AppearanceChoices placement=new AppearanceChoices(AppearanceChoiceStyle.Text,"固定位置","记住上次拖动位置");
        private readonly AppearanceChoices anchors=new AppearanceChoices(AppearanceChoiceStyle.Grid,HudDock.Labels);
        private readonly AppearanceChoices autoHide=new AppearanceChoices(AppearanceChoiceStyle.Text,"关闭","开启");
        private readonly AppearanceDropDown display=new AppearanceDropDown("显示器");
        private readonly List<string> displayIds=new List<string>();
        private Screen[] screens;
        private HudDragPosition lastDrag;
        private MetricPill livePill;
        private readonly Label[] windowLabels={LabelFor("启动方式"),LabelFor("显示器"),LabelFor("贴边位置"),LabelFor("自动隐藏")};
        private readonly Label positionHint=LabelFor("");
        private readonly Control[] styleControls, windowControls;
        private readonly AppearanceChoices mode=new AppearanceChoices(AppearanceChoiceStyle.Text,"极简模式","丰富模式");
        private readonly AppearanceChoices theme=new AppearanceChoices(AppearanceChoiceStyle.Theme,"夜紫","深海","云白");
        private readonly AppearanceChoices shape=new AppearanceChoices(AppearanceChoiceStyle.Shape,"胶囊","圆角","直角");
        private readonly AppearanceDropDown family=new AppearanceDropDown("字体");
        private readonly AppearanceDropDown screenScale=new AppearanceDropDown("本屏缩放");
        private Dictionary<string,int> displayScales;
        private string scaleDisplayId,scalePickerKey,editorScreen;
        private readonly HudAppearance editorAppearance;
        private bool updatingScale,editorScaleQueued;
        private readonly AppearanceSlider size=new AppearanceSlider {Minimum=12,Maximum=20,LargeChange=2};
        private readonly AppearanceSlider opacity=new AppearanceSlider {Minimum=70,Maximum=100,LargeChange=5};
        private readonly HudButton color=new HudButton {Field=true}, clear=new HudButton {Text="随主题"};
        private readonly HudButton save=new HudButton {Text="保存",Primary=true,DialogResult=DialogResult.OK};
        private readonly HudButton cancel=new HudButton {Text="取消",Field=true,DialogResult=DialogResult.Cancel};
        private readonly HudButton reset=new HudButton {Text="恢复默认"};
        private readonly AppearanceChoices previewState=new AppearanceChoices(AppearanceChoiceStyle.Text,"常驻胶囊","无提醒","有提醒","悬停展开");
        private static readonly string[] IdleValues={"","","2","30","27"}, AlertValues={"1","1","2","30","27"};
        private readonly PillTally[] idleBreakdown, alertBreakdown;
        private readonly MetricPill sample=new MetricPill {TabStop=false,Cursor=Cursors.Default,
            Name="appearance-preview",AccessibleRole=AccessibleRole.Graphic};
        private readonly AppearancePreview preview=new AppearancePreview();
        private readonly Label previewLabel=new Label {Text="胶囊预览",TextAlign=ContentAlignment.MiddleLeft,
            UseCompatibleTextRendering=true,UseMnemonic=false};
        private readonly Label[] labels={LabelFor("胶囊模式"),LabelFor("主题"),LabelFor("形状"),LabelFor("强调色"),LabelFor("字体"),LabelFor("字号"),LabelFor("本屏缩放"),LabelFor("不透明度")};
        private readonly Label sizeValue=LabelFor(""), opacityValue=LabelFor("");
        private readonly Label saveError=new Label {Text="保存失败，请检查本机应用数据目录。",Visible=false,
            Name="appearance-save-error",TextAlign=ContentAlignment.MiddleLeft};
        private readonly Label styleHeading=LabelFor("胶囊样式"), typeHeading=LabelFor("字体与显示");
        private readonly Panel header=new Panel {Dock=DockStyle.Top,TabIndex=0}, footer=new Panel {Dock=DockStyle.Bottom,TabIndex=2};
        private readonly Panel headerLine=new Panel(), footerLine=new Panel();
        private readonly Panel pageContent=new Panel {Name="appearance-content",AutoScroll=true,TabStop=false};
        private readonly HudScrollBar pageScroll;
        private int dpi;
        private (Size Size,int Dpi,string Page,bool Vertical,bool Error) lastLayout;
        private bool loading, choosingColor, previewHover;
        private bool previewPreset;
        private HudDock currentDock;
        private HudDragPosition PreviewDrag => Selection.RememberPosition && !previewPreset ? lastDrag : null;
        private string accent;
        private Font uiFont, captionFont, previewFont, brandFont;
        private HudColors colors;
        public HudAppearance Selection { get; private set; }

        private static Label LabelFor(string text) => new Label {Text=text,TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false};
        public AppearanceDialog(HudAppearance initial,int ownerDpi,System.Collections.IDictionary icons,string version=null) {
            editorAppearance=initial.Copy();
            var running=new PillTally();
            running.Add("Codex"); running.Add("Codex");
            var unread=new PillTally(); unread.Add("Qoder");
            var input=new PillTally(); input.Add("Codex");
            idleBreakdown=new[]{new PillTally(),new PillTally(),running};
            alertBreakdown=new[]{input,unread,running};
            sample.AgentIcons=icons;
            logo.Image=icons?["amc"] as Image;
            versionLabel.Visible=!String.IsNullOrWhiteSpace(version);
            if(versionLabel.Visible) versionLabel.Text="版本 "+version.Trim();
            about.Controls.AddRange(new Control[]{logo,wordmark,englishName,chineseName,versionLabel});
            dpi=ownerDpi; Text="AMC 设置"; AccessibleName=Text; Name="appearance-dialog";
            FormBorderStyle=FormBorderStyle.FixedDialog; StartPosition=FormStartPosition.Manual;
            ShowInTaskbar=true; ShowIcon=false; MaximizeBox=false; MinimizeBox=false; AutoScaleMode=AutoScaleMode.None;
            DoubleBuffered=true;
            var installed=FontFamily.Families;
            try { family.Items.AddRange(installed.Select(f=>f.Name).Distinct().OrderBy(n=>n).ToArray()); }
            finally { foreach(var f in installed) f.Dispose(); }
            lastDrag=initial.LastDrag;
            LoadDisplays(initial.StartupDisplay);
            preview.Name="appearance-screen-preview";
            page.Name="appearance-page"; page.AccessibleName="设置类别"; page.SelectedItem="胶囊外观";
            display.Name="appearance-display"; display.AccessibleName="显示器";
            placement.Name="appearance-placement"; placement.AccessibleName="启动方式";
            anchors.Name="appearance-anchors"; anchors.AccessibleName="启动位置";
            autoHide.Name="appearance-autohide"; autoHide.AccessibleName="无提醒时自动隐藏";
            mode.Name="appearance-mode"; mode.AccessibleName="胶囊模式";
            shape.Name="appearance-shape"; theme.Name="appearance-theme"; family.Name="appearance-font";
            size.Name="appearance-size"; opacity.Name="appearance-opacity"; color.Name="appearance-accent";
            screenScale.Name="appearance-screen-scale"; screenScale.AccessibleName="本屏缩放";
            save.Name="appearance-save"; cancel.Name="appearance-cancel"; reset.Name="appearance-reset";
            shape.AccessibleName="形状"; theme.AccessibleName="主题"; family.AccessibleName="字体";
            size.AccessibleName="字号（像素）"; opacity.AccessibleName="不透明度（百分比）";
            sizeValue.TextAlign=opacityValue.TextAlign=ContentAlignment.MiddleRight;
            previewState.Name="appearance-preview-state"; previewState.AccessibleName="预览状态";
            preview.Controls.AddRange(new Control[]{previewLabel,previewState,sample});
            styleControls=labels.Cast<Control>().Concat(new Control[]{styleHeading,typeHeading,mode,theme,shape,color,clear,family,size,sizeValue,screenScale,opacity,opacityValue}).ToArray();
            windowControls=windowLabels.Cast<Control>().Concat(new Control[]{display,placement,anchors,autoHide,positionHint}).ToArray();
            pageContent.Controls.AddRange(styleControls); pageContent.Controls.AddRange(windowControls);
            pageContent.Controls.AddRange(new Control[]{preview,about});
            header.Controls.AddRange(new Control[]{page,headerLine});
            footer.Controls.AddRange(new Control[]{footerLine,reset,cancel,save,saveError});
            pageScroll=new HudScrollBar(pageContent) {Name="appearance-scroll",Dock=DockStyle.Fill,TabIndex=1};
            Controls.AddRange(new Control[]{pageScroll,header,footer});
            var interactive=new Control[]{page,preview,mode,theme,shape,color,clear,family,size,screenScale,opacity,placement,display,anchors,autoHide,reset,cancel,save};
            for(int i=0;i<interactive.Length;i++) interactive[i].TabIndex=i;
            AcceptButton=save; CancelButton=cancel;
            save.Click+=(s,e)=>Close(); cancel.Click+=(s,e)=>Close();
            mode.Changed+=(s,e)=>RefreshPreview();
            page.Changed+=(s,e)=>{previewHover=false;RefreshPreview();};
            placement.Changed+=(s,e)=>{ if(!loading) previewPreset=placement.SelectedItem=="固定位置"; RefreshPreview(); };
            anchors.Changed+=(s,e)=>{ if(!loading) previewPreset=true; RefreshPreview(); };
            preview.DockPicked+=(index,dock)=>{
                previewPreset=true;
                loading=true;
                try {
                    // Keep "follow primary" when clicking its own map.
                    if(display.SelectedIndex!=0 || !screens[index].Primary)
                        display.SelectedItem=(string)display.Items[index+1];
                    anchors.SelectedItem=dock.Label;
                } finally { loading=false; }
                RefreshPreview();
            };
            autoHide.Changed+=(s,e)=>{
                if(!loading) previewState.SelectedItem=autoHide.SelectedItem=="开启" ? "有提醒" : "常驻胶囊";
                RefreshPreview();
            };
            previewState.Changed+=(s,e)=>{previewHover=false; if(!loading && Selection!=null && page.SelectedItem=="胶囊外观") LayoutSample();};
            sample.MouseEnter+=(s,e)=>{
                if(!sample.EdgeTab || sample.EdgePeek) return;
                previewHover=true; LayoutSample();
            };
            sample.MouseLeave+=(s,e)=>{
                if(!previewHover || sample.ClientRectangle.Contains(sample.PointToClient(Cursor.Position))) return;
                previewHover=false; LayoutSample();
            };
            display.SelectedIndexChanged+=(s,e)=>{ if(!loading) previewPreset=true; RefreshPreview(); };
            theme.Changed+=(s,e)=>RefreshPreview(); shape.Changed+=(s,e)=>RefreshPreview();
            family.SelectedIndexChanged+=(s,e)=>RefreshPreview();
            screenScale.SelectedIndexChanged+=(s,e)=>{
                if(loading || updatingScale || scaleDisplayId==null) return;
                int index=screenScale.SelectedIndex;
                if(index<1) displayScales.Remove(scaleDisplayId);
                else displayScales[scaleDisplayId]=index==1 ? -1 : HudDisplayScale.Percentages[index-2];
                RefreshPreview();
            };
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
            reset.Click+=(s,e)=>{previewPreset=true;SetControls(new HudAppearance());};
            DpiChanged+=(s,e)=>{ e.Cancel=true; QueueEditorScale(); };
            LocationChanged+=(s,e)=>{ if(Visible && Screen.FromControl(this).DeviceName!=editorScreen) QueueEditorScale(); };
            ClientSize=new Size(D(WindowWidth),D(WindowHeight));
            SetEditorFonts(); SetControls(initial);
            ClientSizeChanged+=(s,e)=>{if(Selection!=null) RefreshPreview();};
        }
        private void QueueEditorScale() {
            if(editorScaleQueued || !IsHandleCreated || IsDisposed) return;
            editorScaleQueued=true;
            BeginInvoke((Action)(()=>{
                editorScaleQueued=false;
                if(IsDisposed) return;
                ApplyEditorScale(Screen.FromControl(this));
            }));
        }
        private void ApplyEditorScale(Screen monitor) {
            editorScreen=monitor.DeviceName;
            dpi=HudDisplayScale.For(monitor,editorAppearance);
            SetEditorFonts();
            FitTo(monitor.WorkingArea);
            Location=ClampTo(Location,monitor.WorkingArea);
            lastLayout=default;
            RefreshPreview();
        }
        public void OpenBeside(Form hud) {
            var monitor=Screen.FromControl(hud);
            editorScreen=monitor.DeviceName;
            var work=monitor.WorkingArea;
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
            // Creating the native window on a secondary display can rescale its
            // fonts even with AutoScaleMode.None. Apply the monitor metrics last.
            ApplyEditorScale(Screen.FromControl(this));
            FocusEditor();
        }

        private void FitTo(Rectangle work) {
            var requested=SizeFromClientSize(new Size(D(WindowWidth),D(WindowHeight)));
            Size=new Size(Math.Min(requested.Width,work.Width),Math.Min(requested.Height,work.Height));
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
            LayoutPage();
            save.Focus();
        }

        private int D(int n) => (int)Math.Round(n*dpi/96.0);
        private void AddDisplay(string id,string label) { displayIds.Add(id); display.Items.Add(label); }
        private static string ScreenLabel(Screen s) => s.DeviceName.Split('\\').Last().Replace("DISPLAY","屏幕 ");
        private void LoadDisplays(string selectedId) {
            screens=Screen.AllScreens;
            displayIds.Clear(); display.Items.Clear();
            AddDisplay("","主显示器（跟随系统）");
            foreach(var screen in screens)
                AddDisplay(HudDisplayIds.For(screen.DeviceName),$"{ScreenLabel(screen)} · {screen.Bounds.Width} × {screen.Bounds.Height}"+(screen.Primary ? " · 主屏" : ""));
            if(!displayIds.Contains(selectedId)) AddDisplay(selectedId,"上次选择的显示器（未连接）");
            display.SelectedItem=(string)display.Items[displayIds.IndexOf(selectedId)];
        }
        public void RefreshScreens() {
            loading=true;
            try { LoadDisplays(Selection.StartupDisplay); } finally { loading=false; }
            RefreshPreview();
            QueueEditorScale();
        }
        public void SetPositionSource(MetricPill pill,HudDragPosition remembered,HudDock dock) {
            livePill=pill; lastDrag=remembered; currentDock=dock; RefreshPreview();
        }
        private void BindScalePicker(Screen target) {
            string id=HudDisplayIds.For(target.DeviceName);
            int auto=HudDisplayScale.Automatic(target), system=HudDisplayScale.SystemDpi(target);
            displayScales.TryGetValue(id,out int saved);
            string key=id+"|"+target.DeviceName+"|"+auto+"|"+system+"|"+saved;
            if(scalePickerKey==key) return;
            scalePickerKey=key;scaleDisplayId=id;
            updatingScale=true;
            try {
                screenScale.Items.Clear();
                screenScale.Items.Add($"自动（{Math.Round(auto*100/96.0)}%）");
                screenScale.Items.Add($"跟随 Windows（{Math.Round(system*100/96.0)}%）");
                foreach(int p in HudDisplayScale.Percentages) screenScale.Items.Add(p+"%");
                int index=Array.IndexOf(HudDisplayScale.Percentages,saved);
                screenScale.SelectedItem=(string)screenScale.Items[saved==-1 ? 1 : index>=0 ? index+2 : 0];
                labels[6].Text=ScreenLabel(target)+" 缩放";
                screenScale.AccessibleName=labels[6].Text;
            } finally { updatingScale=false; }
        }
        private void ShowDesktopMap() {
            var drag=PreviewDrag;
            string desiredId=drag?.Display ?? Selection.StartupDisplay;
            int index=Array.FindIndex(screens,s=>s.DeviceName==desiredId || HudDisplayIds.For(s.DeviceName)==desiredId);
            bool missing=index<0 && !String.IsNullOrEmpty(desiredId);
            if(index<0) index=Math.Max(0,Array.FindIndex(screens,s=>s.Primary));
            var target=screens[index];
            int scale=HudDisplayScale.For(target,Selection);
            sample.LayoutDpi=scale;
            sample.Vertical=drag?.Vertical ?? Selection.StartupDock.Vertical;
            sample.EdgeTab=sample.EdgePeek=false;
            var demoValues=sample.Values; var demoBreakdown=sample.Breakdown; string demoText=sample.Text;
            Size measured;
            int slot;
            try {
                if(livePill!=null) { sample.Values=livePill.Values; sample.Breakdown=livePill.Breakdown; sample.Text=livePill.Text; }
                measured=sample.MeasureForArea(target.WorkingArea.Size);
                slot=ResolveSlot(target,measured,HudDisplayScale.SystemDpi(target));
                if(Selection.AutoHide && sample.Values.Length>0) {
                    sample.EdgeTab=true;
                    measured=sample.MeasureForArea(target.WorkingArea.Size);
                }
            } finally { sample.EdgeTab=false; sample.Values=demoValues; sample.Breakdown=demoBreakdown; sample.Text=demoText; }
            var pill=HudGeometry.Dock(target.WorkingArea,measured,slot,sample.Vertical);
            var labels=screens.Select(s=>ScreenLabel(s)+(s.Primary ? " · 主屏" : "")).ToArray();
            preview.SetMap(screens.Select(s=>s.Bounds).ToArray(),screens.Select(s=>s.WorkingArea).ToArray(),labels,index,pill);
            preview.MapCaption=missing ? "所选屏幕已断开，暂用主屏" :
                labels[index]+"  /  "+HudDock.FromAnchor(slot,sample.Vertical).Label+
                (drag!=null ? "（上次拖动）" : Selection.RememberPosition ? "（备用位置）" : "");
            preview.AccessibleName="屏幕分布，"+preview.MapCaption;
        }
        private int ResolveSlot(Screen screen,Size size,int dpi) {
            var drag=PreviewDrag;
            int slot=drag?.DockSlot ?? Selection.StartupDock.Anchor;
            if(drag!=null && !drag.DockSlot.HasValue) {
                var old=HudGeometry.Place(screen.WorkingArea,size,dpi,slot,true,drag.Right,drag.Bottom,drag.X,drag.Y);
                slot=HudGeometry.NearestDock(old,screen.WorkingArea,sample.Vertical);
            }
            return HudGeometry.DockSlot(slot,sample.Vertical);
        }
        public void SetAutoHide(bool enabled) => autoHide.SelectedItem=enabled ? "开启" : "关闭";
        private void SetControls(HudAppearance a) {
            loading=true;
            try {
                displayScales=new Dictionary<string,int>(a.DisplayScales,StringComparer.OrdinalIgnoreCase);
                mode.SelectedItem=a.PillMode; shape.SelectedItem=a.Shape; theme.SelectedItem=a.Theme;
                anchors.SelectedItem=a.StartupDock.Label;
                autoHide.SelectedItem=a.AutoHide ? "开启" : "关闭";
                previewState.SelectedItem=a.AutoHide ? "有提醒" : "常驻胶囊";
                previewHover=false;
                placement.SelectedItem=a.RememberPosition ? "记住上次拖动位置" : "固定位置";
                display.SelectedItem=(string)display.Items[displayIds.IndexOf(a.StartupDisplay)];
                if(!family.Items.Contains(a.Family)) family.Items.Insert(0,a.Family);
                family.SelectedItem=a.Family; size.Value=a.Size; opacity.Value=a.Opacity; accent=a.Accent;
            } finally { loading=false; }
            RefreshPreview();
        }
        private void Place(Control c,int x,int y,int w,int h) => c.SetBounds(D(x),D(y),D(w),D(h));
        private void ApplyControlFonts(Control parent) {
            foreach(Control child in parent.Controls) {
                child.Font=child==previewLabel || child==styleHeading || child==typeHeading ? captionFont : child==wordmark ? brandFont :
                    child==family && previewFont!=null ? previewFont : uiFont;
                ApplyControlFonts(child);
            }
        }
        private void SetEditorFonts() {
            SuspendLayout();
            try {
                var oldUi=uiFont; var oldCaption=captionFont; var oldBrand=brandFont;
                if(uiFont==null || uiFont.Size!=D(14))
                    uiFont=new Font("Microsoft YaHei UI",D(14),FontStyle.Regular,GraphicsUnit.Pixel);
                if(captionFont==null || captionFont.Size!=D(13))
                    captionFont=new Font("Microsoft YaHei UI",D(13),FontStyle.Bold,GraphicsUnit.Pixel);
                if(brandFont==null || brandFont.Size!=D(34))
                    brandFont=new Font("Segoe UI",D(34),FontStyle.Bold,GraphicsUnit.Pixel);
                Font=uiFont;
                // WinForms may have installed per-child fonts during WM_DPICHANGED.
                ApplyControlFonts(this);
                if(uiFont!=oldUi) oldUi?.Dispose();
                if(captionFont!=oldCaption) oldCaption?.Dispose();
                if(brandFont!=oldBrand) oldBrand?.Dispose();
            } finally { ResumeLayout(true); }
        }

        private bool PreviewVertical => livePill!=null && !previewPreset && PreviewDrag==null
            ? currentDock.Vertical : PreviewDrag?.Vertical ?? Selection.StartupDock.Vertical;

        private void LayoutPage() {
            bool style=page.SelectedItem=="胶囊外观", position=page.SelectedItem=="位置与方向";
            bool vertical=style && PreviewVertical;
            var key=(ClientSize,dpi,page.SelectedItem,vertical,saveError.Visible);
            if(lastLayout==key) return;
            int scrollY=lastLayout.Page==page.SelectedItem ? -pageContent.AutoScrollPosition.Y : 0;
            lastLayout=key;
            int width=(int)Math.Floor(ClientSize.Width*96.0/dpi);
            int pad=Math.Max(18,(int)Math.Ceiling(pageScroll.GutterWidth*96.0/dpi)+4);
            int inner=Math.Max(1,width-2*pad), gap=28, column=(inner-gap)/2;
            bool wide=inner>=730;
            int bodyTop=14, bottom;
            SuspendLayout();
            pageContent.SuspendLayout();
            try {
                int errorSpace=saveError.Visible ? 26 : 0;
                header.Height=D(52); footer.Height=D(60+errorSpace);
                Place(page,pad-4,5,Math.Min(inner,312),44);
                Place(headerLine,0,51,width,1);
                Place(footerLine,0,0,width,1);
                Place(saveError,pad,4,inner,22);
                Place(reset,pad-4,12+errorSpace,82,36);
                Place(cancel,width-pad-164,12+errorSpace,76,36);
                Place(save,width-pad-78,12+errorSpace,78,36);
                pageContent.AutoScrollPosition=Point.Empty;
                if(style) {
                    int previewWidth=wide && vertical ? column : inner;
                    int previewHeight=vertical ? 276 : 108;
                    LayoutPreview(pad,bodyTop,previewWidth,previewHeight);
                    if(wide && vertical) {
                        int right=pad+column+gap;
                        int next=LayoutStyleGroup(true,right,bodyTop,inner-column-gap);
                        bottom=LayoutStyleGroup(false,right,next+14,inner-column-gap);
                    } else {
                        int top=bodyTop+preview.Height*96/dpi+14;
                        int end=LayoutStyleGroup(true,pad,top,wide ? column : inner);
                        bottom=wide ? LayoutStyleGroup(false,pad+column+gap,top,inner-column-gap)
                                    : LayoutStyleGroup(false,pad,end+14,inner);
                    }
                } else if(position) {
                    int leftWidth=wide ? column : inner;
                    Place(preview,pad,bodyTop,leftWidth,180);
                    int next=PlaceWindowField(0,placement,pad,bodyTop+194,leftWidth,34);
                    next=PlaceWindowField(1,display,pad,next+8,leftWidth,34);
                    int x=wide ? pad+column+gap : pad;
                    int w=wide ? inner-column-gap : inner;
                    int top=wide ? bodyTop : next+16;
                    Place(windowLabels[2],x,top,w,24);
                    Place(anchors,x,top+29,w,144);
                    int end=PlaceWindowField(3,autoHide,x,top+190,w,34);
                    Place(positionHint,x,end+4,w,38);
                    bottom=Math.Max(next,end+42);
                } else {
                    int height=Math.Max(156,(int)(ClientSize.Height*96.0/dpi)-112-(saveError.Visible ? 26 : 0));
                    Place(about,pad,0,inner,height);
                    int x=Math.Max(0,(inner-274)/2), y=(height-138)/2;
                    Place(logo,x,y+2,50,50);
                    int textX=x+68, textWidth=Math.Max(1,inner-textX);
                    Place(wordmark,textX,y,textWidth,45); Place(englishName,textX,y+45,textWidth,25);
                    Place(chineseName,textX,y+71,textWidth,25); Place(versionLabel,textX,y+106,textWidth,25);
                    bottom=height;
                }
                display.DropDownHeight=family.DropDownHeight=screenScale.DropDownHeight=D(228);
                pageContent.AutoScrollMinSize=new Size(0,D(bottom+(style || position ? 14 : 0)));
            } finally { pageContent.ResumeLayout(true); ResumeLayout(true); }
            if(scrollY>0) pageContent.AutoScrollPosition=new Point(0,scrollY);
        }

        private void LayoutPreview(int x,int y,int width,int height) {
            bool stacked=width<410;
            Place(preview,x,y,width,height+(stacked ? 26 : 0));
            Place(previewLabel,12,6,78,24);
            int start=stacked ? 8 : Math.Max(92,width-336);
            Place(previewState,start,stacked ? 32 : 4,width-start-8,30);
        }

        private int LayoutStyleGroup(bool capsule,int x,int top,int width) {
            Place(capsule ? styleHeading : typeHeading,x,top,width,22);
            int fieldX=x+88, fieldWidth=width-88, y=top+27;
            void Row(int index,Control field,Control trailing=null,int trailingWidth=0) {
                Place(labels[index],x,y,84,32);
                int room=trailing==null ? fieldWidth : fieldWidth-trailingWidth-6;
                Place(field,fieldX,y,room,32);
                if(trailing!=null) Place(trailing,fieldX+room+6,y,trailingWidth,32);
                y+=38;
            }
            if(capsule) {
                Row(0,mode); Row(1,theme); Row(2,shape); Row(3,color,clear,68);
            } else {
                Row(4,family); Row(5,size,sizeValue,52); Row(6,screenScale); Row(7,opacity,opacityValue,52);
            }
            return y-6;
        }

        private int PlaceWindowField(int index,Control field,int x,int top,int width,int height) {
            bool stacked=width<340;
            Place(windowLabels[index],x,top,stacked ? width : 84,stacked ? 24 : height);
            int inset=stacked ? 0 : 88, y=stacked ? top+25 : top;
            Place(field,x+inset,y,width-inset,height);
            return y+height;
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
                Size=size.Value,DisplayScales=new Dictionary<string,int>(displayScales,StringComparer.OrdinalIgnoreCase),Opacity=opacity.Value,Accent=accent,StartupDock=HudDock.FromLabel(anchors.SelectedItem),
                StartupDisplay=displayIds[display.SelectedIndex],RememberPosition=placement.SelectedItem=="记住上次拖动位置",AutoHide=autoHide.SelectedItem=="开启"};
            bool windowPage=page.SelectedItem=="位置与方向";
            bool stylePage=page.SelectedItem=="胶囊外观";
            about.Visible=page.SelectedItem=="关于";
            preview.Visible=reset.Visible=stylePage || windowPage;
            foreach(var control in styleControls) control.Visible=stylePage;
            foreach(var control in windowControls) control.Visible=windowPage;
            LayoutPage();
            windowLabels[1].Text=Selection.RememberPosition ? "备用显示器" : "显示器";
            windowLabels[2].Text=Selection.RememberPosition ? "备用位置" : "贴边位置";
            positionHint.Text="有提醒时显示文字短签，无提醒时收成细线。";
            colors=new HudColors(Selection); pageContent.BackColor=BackColor=colors.Surface; ForeColor=colors.Ink;
            englishName.ForeColor=chineseName.ForeColor=versionLabel.ForeColor=colors.Muted;
            CaptionTheme();
            preview.Palette=colors; preview.LayoutDpi=dpi; preview.BackColor=colors.Surface;
            previewLabel.BackColor=colors.Track; previewLabel.ForeColor=colors.Muted;
            headerLine.BackColor=footerLine.BackColor=colors.Divider;
            footer.BackColor=colors.Chrome;
            styleHeading.ForeColor=typeHeading.ForeColor=colors.Ink;
            foreach(var label in labels.Concat(windowLabels)) label.ForeColor=colors.Muted;
            saveError.ForeColor=colors.InputInk;
            foreach(var rail in new[]{mode,theme,shape,page,placement,anchors,autoHide,previewState}) rail.Style(colors,dpi);
            positionHint.ForeColor=colors.Muted;
            display.LayoutDpi=dpi; display.Palette=colors; display.BackColor=colors.Chrome; display.ForeColor=colors.Ink;
            display.ItemHeight=D(32);
            screenScale.LayoutDpi=dpi; screenScale.Palette=colors; screenScale.BackColor=colors.Chrome; screenScale.ForeColor=colors.Ink;
            screenScale.ItemHeight=D(32);
            family.LayoutDpi=dpi; family.Palette=colors; family.BackColor=colors.Chrome; family.ForeColor=colors.Ink;
            // Only the font field and the sample use the chosen family. Editing
            // appearance must not shift the other labels or buttons.
            if(previewFont==null || previewFont.OriginalFontName!=Selection.Family || previewFont.Size!=D(14)) {
                var old=previewFont;
                previewFont=new Font(Selection.Family,D(14),FontStyle.Regular,GraphicsUnit.Pixel);
                family.Font=previewFont;
                old?.Dispose();
            } else family.Font=previewFont;
            family.ItemHeight=Math.Max(D(32),family.Font.Height+D(4));
            pageScroll.Palette=colors;
            foreach(var button in new[]{color,clear,save,cancel,reset}) {
                button.LayoutDpi=dpi; button.Palette=colors; button.BackColor=button.Parent.BackColor;
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
            sample.Values=AlertValues; sample.Breakdown=alertBreakdown;
            sample.PreviewOpacity=true;
            previewState.Visible=previewLabel.Visible=sample.Visible=stylePage;
            if(!stylePage && !windowPage) return;
            if(windowPage && screens.Length>0) {
                ShowDesktopMap();
                preview.Invalidate(true);
                return;
            }
            preview.ClearMap();
            preview.AccessibleName=previewLabel.Text;
            LayoutSample();
            family.Invalidate(); preview.Invalidate(true);
        }

        private void LayoutSample() {
            var area=Rectangle.FromLTRB(D(9),previewState.Bottom+D(5),preview.ClientSize.Width-D(9),preview.ClientSize.Height-D(6));
            var drag=PreviewDrag;
            string id=drag?.Display ?? Selection.StartupDisplay;
            var target=screens.FirstOrDefault(s=>s.DeviceName==id || HudDisplayIds.For(s.DeviceName)==id) ?? Screen.PrimaryScreen;
            bool showCurrent=livePill!=null && !previewPreset && drag==null;
            if(showCurrent && livePill.FindForm() is Form hud) target=Screen.FromControl(hud);
            if(target==null || area.Width<=0 || area.Height<=0) return;
            BindScalePicker(target);
            int realDpi=HudDisplayScale.For(target,Selection);
            sample.LayoutDpi=realDpi;
            string state=previewState.SelectedItem;
            bool idle=state=="无提醒";
            sample.Values=idle ? IdleValues : AlertValues;
            sample.Breakdown=idle ? idleBreakdown : alertBreakdown;
            // Resolve legacy drag offsets using the regular capsule, as the desktop does.
            sample.EdgeTab=sample.EdgePeek=false;
            Size work=target.WorkingArea.Size;
            sample.Vertical=PreviewVertical;
            int slot=showCurrent ? currentDock.Anchor : ResolveSlot(target,sample.MeasureForArea(work),HudDisplayScale.SystemDpi(target));
            sample.OpensForward=sample.Vertical ? slot%3==0 : slot/3==0;
            sample.EdgeTab=state!="常驻胶囊";
            sample.EdgePeek=sample.EdgeTab && (state=="悬停展开" || previewHover);
            Size desired=sample.MeasureForArea(work);
            // Keep monitor scale when it fits. Shrink both axes together and keep
            // the simulated work area's proportions so rows wrap as on the target.
            while(desired.Width>area.Width || desired.Height>area.Height) {
                double fit=Math.Min(area.Width/(double)desired.Width,area.Height/(double)desired.Height);
                int next=Math.Max(1,(int)Math.Floor(sample.LayoutDpi*fit));
                if(next>=sample.LayoutDpi) break;
                sample.LayoutDpi=next;
                desired=sample.MeasureForArea(new Size(Math.Max(1,work.Width*next/realDpi),Math.Max(1,work.Height*next/realDpi)));
            }
            sample.Bounds=HudGeometry.Dock(area,desired,slot,sample.Vertical);
            preview.SetSampleEdge(area,sample.Vertical,sample.OpensForward);
            sample.AccessibleName=sample.EdgeTab && !sample.EdgePeek
                ? "贴边提醒预览，"+sample.NoticeCaption
                : "预览 "+sample.Caption(true);
            sample.Invalidate();
        }

        protected override void Dispose(bool disposing) {
            base.Dispose(disposing);
            if(disposing) { previewFont?.Dispose(); captionFont?.Dispose(); uiFont?.Dispose(); brandFont?.Dispose(); }
        }
    }
}
