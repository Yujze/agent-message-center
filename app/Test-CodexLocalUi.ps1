# Run through Start-Reminder.ps1 -UiTest -CodexLocal with the test fixture.
$window.Show()
[Windows.Forms.Application]::DoEvents()
$deadline = [datetime]::UtcNow.AddSeconds(10)
while ($localView.Status -eq 'Loading' -and [datetime]::UtcNow -lt $deadline) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 35
}
if ($localView.Status -ne 'Ready' -or $localView.Rows.Count -ne 3) { throw '未从不同目录读取全部测试会话' }
if ($expanded -or $localChrome.Pill.Text -notmatch '^进行中 1 · 任务 3 · 已完成 1$') { throw '收起状态缺少实际统计' }
if ($hudTips.GetToolTip($localChrome.Pill)) { throw '收起的胶囊不应弹出悬停说明' }
Add-Type -Path "$PSScriptRoot/Test-HudScrollBar.cs"
function Test-ScrollGutter($content,$hostControl) {
    $rail=$hostControl.Controls['hud-scroll-vertical']
    $native=[JieShou.Tests.ScrollGesture]::NativeTrackAfterRepaint($content.Handle)
    $clip=$content.Parent.RectangleToScreen($content.Parent.ClientRectangle)
    if (!$rail.Visible -or $clip.IntersectsWith($native) -or $rail.Width -le 0 -or
        $rail.RectangleToScreen($rail.ClientRectangle).Left -ne $clip.Right) { throw "系统滚动条未与可见区域隔开：$($hostControl.Name)" }
    $frame=[Drawing.Bitmap]::new($rail.Width,$rail.Height)
    try {
        $rail.DrawToBitmap($frame,$rail.ClientRectangle)
        if ($frame.GetPixel(0,0).ToArgb() -ne $content.BackColor.ToArgb()) {throw '系统重绘后轨道底色未跟随主题'}
    } finally { $frame.Dispose() }
    $down=[Drawing.Point]::new([int]($rail.Width/2),[int]($rail.DeviceDpi/96*5))
    [JieShou.Tests.ScrollGesture]::DragClient($rail.Handle,$down,[Drawing.Point]::new(0,$rail.Height))
}
$work = [Windows.Forms.Screen]::FromControl($window).WorkingArea
$mockPrimary=[pscustomobject]@{DeviceName='fixture-main'; Primary=$true}
$mockSecondary=[pscustomobject]@{DeviceName='fixture-left'; Primary=$false}
$secondaryArea=[Drawing.Rectangle]::new(-1920,-160,1920,1040)
$prefs=[JieShou.HudAppearance]::new()
# Use the same 1080p resolution on two physical sizes, plus a rotated panel,
# constrained 720p, 1440p and 4K. Windows' own zoom is always the automatic floor.
foreach($case in @(
    @(1920,1080,344,195,1040,120,0,144), @(1920,1080,540,310,1040,96,0,96),
    @(1080,1920,344,195,1872,120,0,144), @(1280,720,177,100,680,96,0,120),
    @(2560,1440,597,336,1380,96,0,108), @(3840,2160,344,195,2090,240,0,240),
    @(1920,1080,0,0,1040,120,0,120), @(1920,1080,0,0,1040,120,143,144))) {
    $actual=[JieShou.HudDisplayScale]::AutoDpi([Drawing.Size]::new($case[0],$case[1]),
        [Drawing.Size]::new($case[2],$case[3]),[Drawing.Size]::new($case[0],$case[4]),$case[5],$case[6])
    if($actual -ne $case[7]) { throw "屏幕自动缩放错误：$case 得到 $actual" }
}
$edid=[byte[]]::new(128)
1..6 | ForEach-Object { $edid[$_]=255 }
$edid[54]=1; $edid[66]=88; $edid[67]=195; $edid[68]=16
if([JieShou.HudDisplayScale]::PanelMillimeters($edid) -ne [Drawing.Size]::new(344,195)) {throw '未读出便携屏详细时序中的尺寸'}
$originalPlacement=$placement.Clone()
foreach($monitor in [Windows.Forms.Screen]::AllScreens) {
    $area=$monitor.WorkingArea
    Move-ReminderHud ($area.Left+30) ($area.Top+30) $area
    [Windows.Forms.Application]::DoEvents()
    $expected=[JieShou.HudDisplayScale]::For($monitor,$appearance)
    $measured=$localChrome.Pill.MeasureForArea($area.Size)
    if($localChrome.Pill.LayoutDpi -ne $expected -or [Math]::Abs($hudFonts.Name.Size-$appearance.Size*$expected/96.0) -gt .01 -or
        !$area.Contains($window.Bounds) -or $window.ClientSize -ne $measured) { throw "跨屏拖动未按目标屏幕重绘 $($monitor.DeviceName) window=$($window.Bounds) expected=$measured" }
}
function Test-EditorFonts($dialog,$screen) {
    $expected=[Math]::Round(14*[JieShou.HudDisplayScale]::For($screen,$appearance)/96)
    $tabs=$dialog.Controls.Find('appearance-page',$true)[0]
    $picker=$dialog.Controls.Find('appearance-font',$true)[0]
    $saveButton=$dialog.Controls.Find('appearance-save',$true)[0]
    foreach($control in $dialog,$tabs.Controls[0],$picker,$saveButton) {
        if([Math]::Abs($control.Font.Size-$expected) -gt .01) {throw "设置字号错误 $($screen.DeviceName) $($control.Name) 应为 $expected，实际 $($control.Font.Size)"}
    }
    $picker.DroppedDown=$true
    try {
        [Windows.Forms.Application]::DoEvents()
        if([Math]::Abs($picker.Options.Font.Size-$expected) -gt .01) {throw '字体下拉列表未采用目标屏幕的字号'}
    } finally {$picker.DroppedDown=$false}
}
$localChrome.Pill.PerformClick();$localChrome.Surface.FinishReveal()
foreach($monitor in [Windows.Forms.Screen]::AllScreens) {
    $area=$monitor.WorkingArea
    Move-ReminderHud ($area.Left+30) ($area.Top+30) $area
    [Windows.Forms.Application]::DoEvents()
    $expected=[JieShou.HudDisplayScale]::For($monitor,$appearance)
    $row=$list.Controls | Where-Object {$_ -is [JieShou.LocalRow]} | Select-Object -First 1
    if(!$row -or [Math]::Abs($row.TitleFont.Size-$appearance.Size*$expected/96.0) -gt .01 -or
        [Math]::Abs($header.Font.Size-($appearance.Size+3)*$expected/96.0) -gt .01 -or
        $row.Width -gt $list.ClientSize.Width -or $row.Height -lt $row.ContentHeight($row.Width) -or !$area.Contains($window.Bounds)) {
        throw "跨屏后展开列表的字体或行高错误 $($monitor.DeviceName)"
    }
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $dialog=$localChrome.AppearanceDialog
    try {
        Test-EditorFonts $dialog $monitor
        if($monitor.Primary) {
            foreach($other in [Windows.Forms.Screen]::AllScreens | Where-Object DeviceName -ne $monitor.DeviceName) {
                $dialog.Location=[Drawing.Point]::new($other.WorkingArea.Left+8,$other.WorkingArea.Top+8)
                [Windows.Forms.Application]::DoEvents()
                Test-EditorFonts $dialog $other
            }
        }
    } finally { $dialog.Close() }
}
$localChrome.Toggle.PerformClick();$localChrome.Surface.FinishReveal()
$script:placement=$originalPlacement
Update-ReminderWindow
[Windows.Forms.Application]::DoEvents()
$runningPoint=[Drawing.Point]::new(($localChrome.Pill.GripWidth+(Get-HudPixels 10)),[int]($window.Height/2))
[JieShou.Tests.ScrollGesture]::DragClient($localChrome.Pill.Handle,$runningPoint,[Drawing.Point]::Empty)
$localChrome.Surface.FinishReveal()
if (!$expanded -or $localView.Attention -cne '进行中' -or $list.Controls.Count -ne 1) {throw '点击普通胶囊的进行中数字未进入对应清单'}
$localChrome.AllSessions.PerformClick()
if ($list.Controls.Count -ne 3) {throw '完整会话列表入口丢失'}
$localChrome.Toggle.PerformClick();$localChrome.Surface.FinishReveal()
foreach ($axis in '横向','竖向') {
    $placement.Vertical=$axis -eq '竖向'
    Update-ReminderWindow
    $pill=$localChrome.Pill
    foreach ($i in 4,3) {
        $hitBoxes=$pill.GetType().GetField('statusBounds',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($pill)
        $box=$hitBoxes[$i]
        if ($box.IsEmpty -or !$pill.ClientRectangle.Contains($box)) { throw "统计区域超出胶囊 $axis / $i" }
        $hit=[Drawing.Point]::new(($box.Left+$box.Width/2),($box.Top+$box.Height/2))
        [JieShou.Tests.ScrollGesture]::DragClient($pill.Handle,$hit,[Drawing.Point]::Empty)
        $localChrome.Surface.FinishReveal()
        if (!$expanded -or ($i -eq 4 -and ($localView.Attention -ne '已完成' -or $list.Controls.Count -ne 1 -or
            !$localChrome.ReminderFilters[3].Selected)) -or ($i -eq 3 -and ($localView.Attention -or $list.Controls.Count -ne 3))) {
            throw "点击胶囊统计后筛选或清单错误 $axis / $i"
        }
        $localChrome.Toggle.PerformClick();$localChrome.Surface.FinishReveal()
    }
}
$placement.Vertical=$false;Update-ReminderWindow
$prefs.StartupDisplay=$mockSecondary.DeviceName
foreach ($label in [JieShou.HudDock]::Labels) {
    $dock=[JieShou.HudDock]::FromLabel($label)
    $pixel=[JieShou.HudGeometry]::Dock($secondaryArea,[Drawing.Size]::new(1,1),$dock.Anchor,$dock.Vertical)
    if ([JieShou.HudDock]::At($pixel.Location,$secondaryArea,'Bottom').Label -ne $label) {throw "吸附落点错误 $label"}
}
$corner=[Drawing.Point]::new(($secondaryArea.Right-1),$secondaryArea.Top)
if ([JieShou.HudDock]::At($corner,$secondaryArea,'Right').Label -ne '右边靠上' -or
    [JieShou.HudDock]::At($corner,$secondaryArea,'Bottom').Label -ne '上边靠右') {throw '角落等距时选择了错误的边'}
foreach ($idx in 0..8) {
    foreach ($vertical in $true,$false) {
        $prefs.Orientation=if ($vertical) { '竖向' } else { '横向' }
        $prefs.StartupAnchor=[JieShou.HudAppearance]::Anchors[$idx]
        $testPlacement=Get-ReminderStartupPlacement $prefs
        $r=Get-ReminderHudBounds $testPlacement $secondaryArea 120 180 144
        $slot=[JieShou.HudGeometry]::DockSlot($idx,$vertical)
        $xs=if ($vertical) { -1920,0,-120 } else { -1660,-1020,-380 }
        $ys=if ($vertical) { -77,270,617 } else { -160,0,700 }
        if ($r.X -ne $xs[$slot%3] -or $r.Y -ne $ys[[int][Math]::Floor($slot/3)] -or
            [JieShou.HudGeometry]::NearestDock($r,$secondaryArea,$vertical) -ne $slot) { throw "副屏六个贴边位置错误：$vertical / $idx / $r" }
        $panel=[JieShou.HudGeometry]::Expand($r,[Drawing.Size]::new(650,710),$secondaryArea,$vertical,144)
        if (!$secondaryArea.Contains($panel) -or !$panel.Contains($r)) { throw '展开位置脱离胶囊或越过工作区' }
    }
}
if ((Get-ReminderHudScreen $testPlacement @($mockPrimary)) -ne $mockPrimary -or
    (Get-ReminderHudScreen $testPlacement @($mockPrimary,$mockSecondary)) -ne $mockSecondary) { throw '断开或重连显示器时丢失了首选屏幕' }
Set-ReminderHudPlacement $testPlacement ([Drawing.Rectangle]::new(-165,650,120,180)) $secondaryArea 144
$resized=Get-ReminderHudBounds $testPlacement ([Drawing.Rectangle]::new(0,0,2560,1400)) 160 240 192
if ($resized.Right -ne 2500 -or $resized.Bottom -ne 1333) { throw '跨屏缩放后没有保留工作区边距' }
if ((Get-ReminderStartupPlacement $prefs).Positioned) { throw '固定位置模式意外记住了临时拖动' }
Move-ReminderHud ($work.Left+40) ($work.Top+40) $work
function Test-MessageGrip($expectedHost,$handle=$dragGrip) {
    $anchor=$window.Location
    $wasExpanded=$expanded
    $pt=[Drawing.Point]::new([int]($handle.Width/2),[int]($handle.Height/2))
    $hit=$expectedHost.PointToClient($handle.PointToScreen($pt))
    if ($expectedHost.GetChildAtPoint($hit) -ne $handle -or !$handle.Visible) { throw "拖动区域无法命中：$($handle.Name)" }
    [JieShou.Tests.ScrollGesture]::DragClient($handle.Handle,$pt,[Drawing.Point]::Empty)
    if ($expanded -ne $wasExpanded -or $anchor -ne $window.Location) { throw '单击消息握把误切换视图或移动浮窗' }
    $oldDock=[JieShou.HudDock]::FromAnchor($placement.Anchor,$placement.Vertical)
    $origin=$handle.PointToScreen($pt)
    $release=[Drawing.Point]::new(($origin.X+24),($origin.Y+16))
    [JieShou.Tests.ScrollGesture]::DragClient($handle.Handle,$pt,[Drawing.Point]::new(24,16))
    $dock=[JieShou.HudDock]::At($release,[Windows.Forms.Screen]::FromPoint($release).WorkingArea,$oldDock.Edge)
    if ($expanded -ne $wasExpanded -or !$placement.Docked -or $placement.Anchor -ne $dock.Anchor -or $placement.Vertical -ne $dock.Vertical -or $handle.Capture) { throw '松开握把没有按落点吸边和转向' }
}
Test-MessageGrip $localChrome.Pill
$appearance.PillMode='丰富模式'
Update-ReminderWindow
Test-MessageGrip $localChrome.Pill
$appearance.PillMode='极简模式'
Update-ReminderWindow
if (!$localChrome.Surface.IsActive -or $window.Region) { throw "胶囊未使用逐像素透明窗口 $($localChrome.Surface.LastError)" }
# Exercise layout and rendered pixels without changing the desktop resolution.
$probe=[JieShou.MetricPill]::new()
try {
    $probe.Appearance=$appearance.Copy()
    $probe.Appearance.Size=20
    $probe.Colors=$hudColors
    $probe.AgentIcons=$agentIcons
    $probe.Values=[string[]]@('36','36','36','120','48')
    $tally=[JieShou.PillTally]::new()
    foreach ($agent in 'Codex','DSH','Qoder') { foreach ($i in 1..12) { $tally.Add($agent) } }
    $probe.Breakdown=[JieShou.PillTally[]]@($tally,$tally,$tally)
    $wrapped=$false
    foreach ($display in @(@(1280,720,96),@(1280,720,120),@(1280,720,144),@(1920,1080,96),@(1920,1080,144),
                            @(2560,1440,120),@(2560,1440,168),@(3840,2160,144),@(3840,2160,192),@(3840,2160,240))) {
        $probe.LayoutDpi=$display[2]
        foreach ($mode in '极简模式','丰富模式') {
            $probe.Appearance.PillMode=$mode
            $probe.Size=$probe.MeasureForWidth($display[0])
            if ($probe.RequiredWidth() -gt $display[0]) {
                if ($probe.Height -le [Math]::Round(($probe.Appearance.Size+22)*$probe.LayoutDpi/96.0)) { throw '窄屏丰富模式没有换行' }
                $wrapped=$true
            }
            $frame=$probe.RenderFrame()
            try {
                if ($frame.Width -gt $display[0] -or $frame.Height -gt $display[1] -or
                    $frame.GetPixel(0,0).A -ne 0 -or $frame.GetPixel([int]($frame.Width/2),[int]($frame.Height/2)).A -ne 255) { throw '胶囊填充或尺寸错误' }
                $levels=[Collections.Generic.HashSet[int]]::new()
                for ($y=0;$y -lt $frame.Height/2;$y++) {
                    for ($x=0;$x -lt $frame.Height/2;$x++) {
                        $alpha=$frame.GetPixel($x,$y).A
                        if ($alpha -ne $frame.GetPixel($frame.Width-1-$x,$frame.Height-1-$y).A) { throw '胶囊两端不对称' }
                        if ($alpha -gt 0 -and $alpha -lt 255) { [void]$levels.Add($alpha) }
                    }
                }
                if ($levels.Count -lt 12) { throw "胶囊边缘缺少透明过渡，DPI $($display[2])" }
            } finally { $frame.Dispose() }
            $probe.Vertical=$true
            $area=[Drawing.Size]::new($display[0],$display[1]-48)
            $probe.Size=$probe.MeasureForArea($area)
            $verticalFrame=$probe.RenderFrame()
            try {
                $grip=$probe.GripBounds($probe.Size)
                if ($probe.Width -gt $area.Width -or $probe.Height -gt $area.Height -or $grip.Width -ne $probe.GripWidth -or
                    $grip.Contains([int]($probe.Width-20*$probe.LayoutDpi/96),[int]($grip.Height/2)) -or
                    $grip.Bottom -ge $probe.Height/2 -or $verticalFrame.GetPixel(0,0).A -ne 0 -or
                    $probe.Caption($true) -notmatch '待输入 36' -or $probe.Caption() -notmatch '总数 120 · 已完成 48') { throw "竖向胶囊尺寸、握把或计数错误：$mode / $display" }
                if ($mode -eq '极简模式') {
                    $simpleHeight=$probe.Height
                    if ($probe.Caption($true) -match 'Codex') { throw '竖向极简模式出现来源明细' }
                } elseif ($probe.Height -le $simpleHeight -or $probe.Caption($true) -notmatch 'Codex 12、DSH 12、Qoder 12') {
                    throw '竖向丰富模式缺少每段的来源行'
                }
            } finally { $verticalFrame.Dispose() }
            $probe.Vertical=$false
        }
    }
    if (!$wrapped) { throw '缺少窄屏多行胶囊覆盖' }
} finally { $probe.Dispose() }
$localView.LastJson = ''
$deadline = [datetime]::UtcNow.AddSeconds(8)
while (!$localView.LastJson -and [datetime]::UtcNow -lt $deadline) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}
if (!$localView.LastJson -or $expanded) { throw '浮窗收起后没有继续刷新' }
$savedRows = $localView.Rows
$localView.Rows = @($savedRows[0]) * 123
Update-ReminderWindow
if ($localChrome.Pill.Width -lt $localChrome.Pill.RequiredWidth() -or $localChrome.Pill.Values[3] -ne '123') {
    throw '多位统计数字超出单行空间'
}
$localView.Rows = $savedRows
Update-ReminderWindow
$capsuleBounds=$window.Bounds
function Get-RevealBounds {
    if (!$window.Region) { return $window.Bounds }
    $g=$window.CreateGraphics()
    try { $clip=[Drawing.Rectangle]::Round($window.Region.GetBounds($g)) } finally { $g.Dispose() }
    $clip.Offset($window.Location)
    return $clip
}
function Wait-HudMotion {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1600) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 3
    }
    if ($localChrome.Surface.IsRevealing) { throw '浮窗动画未能结束' }
}
function Send-TestOutsidePress([IntPtr]$Target) {
    # Exercise the same press dispatch on real HWNDs without clicking another application.
    $watcher=$localChrome.OutsideClicks
    $method=$watcher.GetType().GetMethod('CheckPress',[Reflection.BindingFlags]'NonPublic,Instance')
    $method.Invoke($watcher,@($Target))
    [Windows.Forms.Application]::DoEvents()
}
$localChrome.Pill.PerformClick()
if ([JieShou.SessionActivityAnimation]::MotionAllowed) {
    if (!$localChrome.Surface.IsRevealing) { throw '点击胶囊没有开始展开' }
    $canvas=$window.Size
    $row=$list.Controls[0]
    $rowHandle=$row.Handle
    $rowBounds=$row.Bounds
    $heights=[Collections.Generic.List[int]]::new()
    $heights.Add((Get-RevealBounds).Height)
    $observe=[EventHandler]{ $h=(Get-RevealBounds).Height; if (!$heights.Contains($h)) { $heights.Add($h) } }
    $window.add_RegionChanged($observe)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $refreshed=$false
    while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1500) {
        [Windows.Forms.Application]::DoEvents()
        if ($window.Top -ne $capsuleBounds.Top) { throw '展开时标题栏离开了胶囊上边缘' }
        if ($canvas -ne $window.Size -or $rowHandle -ne $row.Handle -or $rowBounds -ne $row.Bounds) { throw '卷帘展开时重新布局了列表' }
        if (!$refreshed -and $heights.Count -ge 2) { Update-ReminderWindow; $refreshed=$true }
        Start-Sleep -Milliseconds 4
    }
    $window.remove_RegionChanged($observe)
    if ($localChrome.Surface.IsRevealing -or $heights.Count -lt 3 -or $heights[0] -ge $window.Height) { throw '展开跳过了中间帧或未能结束' }
    for ($i=1;$i -lt $heights.Count;$i++) { if ($heights[$i] -le $heights[$i-1]) { throw '刷新后展开高度倒退' } }
    $end=$window.Bounds
    Update-ReminderWindow
    if ($window.Bounds -ne $end -or $localChrome.Surface.IsRevealing) { throw '普通刷新重新播放了展开动画' }
} elseif ($localChrome.Surface.IsRevealing) { throw '系统关闭动画时仍然播放展开' }
$panelBounds=$window.Bounds
Send-TestOutsidePress $list.Controls[0].Handle
$localChrome.Range.PerformClick()
$filterPopup=$localChrome.Range.ContextMenuStrip
Send-TestOutsidePress $filterPopup.Handle
if (!$expanded -or !$filterPopup.Visible) { throw '列表内或下拉菜单内点击误收起' }
$filterPopup.Close()
Send-TestOutsidePress ([JieShou.Tests.ScrollGesture]::GetDesktopWindow())
if ($expanded) { throw '关闭自动隐藏时，点击外部没有收回胶囊' }
if ([JieShou.SessionActivityAnimation]::MotionAllowed) {
    if (!$localChrome.Surface.IsRollingUp -or !$list.Visible) { throw '点击收起没有保留列表开始上卷' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ((Get-RevealBounds).Height -gt ($panelBounds.Height+$capsuleBounds.Height)/2 -and $watch.ElapsedMilliseconds -lt 1200) {
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 3
    }
    $middle=Get-RevealBounds
    if (!$localChrome.Surface.IsRollingUp -or $middle.Height -le $capsuleBounds.Height) { throw '上卷没有经过中间高度' }
    Update-ReminderWindow
    if ((Get-RevealBounds) -ne $middle) { throw '刷新打断了上卷' }
    $localChrome.Toggle.PerformClick()
    if ($localChrome.Surface.IsRollingUp -or (Get-RevealBounds) -ne $middle) { throw '上卷中重新展开时窗口跳位' }
    Wait-HudMotion
    if ($window.Bounds -ne $panelBounds -or !$list.Visible) { throw '反向展开后列表未恢复' }
    $localChrome.Toggle.PerformClick()
}
Wait-HudMotion
if (!$localChrome.Surface.IsActive -or $window.Bounds -ne $capsuleBounds -or $list.Visible) { throw '上卷结束后胶囊位置或交互错误' }
Move-ReminderHud ($work.Right-$window.Width-8) ($work.Bottom-$window.Height-12) $work
$edgeBounds=$window.Bounds
$localChrome.Pill.PerformClick()
$watch=[Diagnostics.Stopwatch]::StartNew()
while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1500) {
    [Windows.Forms.Application]::DoEvents()
    if (!$work.Contains((Get-RevealBounds))) { throw '贴边展开超出了工作区' }
    Start-Sleep -Milliseconds 4
}
if ($window.Top -ge $edgeBounds.Top -or $window.Right -ne $edgeBounds.Right -or !$work.Contains((Get-RevealBounds))) { throw '屏幕底部展开方向或水平锚点错误' }
$localChrome.Toggle.PerformClick()
while ($localChrome.Surface.IsRollingUp -and $watch.ElapsedMilliseconds -lt 2000) {
    [Windows.Forms.Application]::DoEvents()
    if (!$work.Contains((Get-RevealBounds))) { throw '贴边上卷超出了工作区' }
    Start-Sleep -Milliseconds 4
}
if ($window.Bounds -ne $edgeBounds) { throw '屏幕底部收起时胶囊位置变化' }
Move-ReminderHud $capsuleBounds.Left $capsuleBounds.Top $work
$localChrome.Pill.PerformClick()
$localChrome.Surface.FinishReveal()
if ($window.Controls.Find('local-activity', $true).Count -or $window.Controls.Find('local-folder', $true).Count) {
    throw '全局会话入口显示错误'
}
if ($localChrome.Surface.IsActive -or !$window.Region) { throw '展开后未恢复原生控件绘制' }
# A one-off missing catalog holds the last verified rows. A repeated failure must become visible.
function Read-FixtureOnce {
    $localView.NextRead=[datetime]::MinValue
    Update-LocalSessionList
    $deadline=[datetime]::UtcNow.AddSeconds(4)
    while ($localView.Reader -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 15
        Update-LocalSessionList
    }
    if ($localView.Reader) { throw '测试索引读取超时' }
}
$localTimer.Stop()
$fixtureHome=$env:CODEX_HOME
$absent=Join-Path $fixtureHome 'absent-catalog'
try {
    $kept=$list.Controls[0]
    $env:CODEX_HOME=$absent
    Read-FixtureOnce
    if (!$localView.RetryingRead -or $localView.Status -ne 'Ready' -or $list.Controls[0] -ne $kept) { throw '单次索引中断清除了会话' }
    $env:CODEX_HOME=$fixtureHome
    Read-FixtureOnce
    if ($localView.RetryingRead -or $localView.Status -ne 'Ready' -or $list.Controls[0] -ne $kept) { throw '索引恢复后没有复用会话行' }
    $env:CODEX_HOME=$absent
    Read-FixtureOnce
    Read-FixtureOnce
    if ($localView.RetryingRead -or $localView.Status -ne 'Unavailable' -or $localView.Rows.Count) { throw '持续失联仍显示旧统计' }
} finally {
    $env:CODEX_HOME=$fixtureHome
    Read-FixtureOnce
    $localTimer.Start()
}
Test-MessageGrip $localChrome.Band
Test-MessageGrip $localChrome.Band $header
$baseTheme = $appearance.Theme
$baseSize = $appearance.Size
foreach ($themeName in '夜紫','深海','云白') {
    $appearance.Theme = $themeName
    $appearance.Size = if ($themeName -eq '云白') { 20 } else { $baseSize }
    Set-HudAppearance
    Update-ReminderWindow
    foreach ($trigger in $localChrome.Range,$localChrome.Sort) {
        [void]$window.Activate()
        [Windows.Forms.Application]::DoEvents()
        $trigger.PerformClick()
        [Windows.Forms.Application]::DoEvents()
        $popup = $trigger.ContextMenuStrip
        try {
            if (!$popup.Visible -or $popup.BackColor -ne $hudColors.Chrome -or !$popup.Font.Equals($trigger.Font)) {
                throw '展开的下拉菜单未使用当前主题和字体'
            }
            if (@($popup.Items | Where-Object Checked).Count -ne 1) { throw '菜单需要一个当前选项' }
            foreach ($entry in $popup.Items) {
                if (!$popup.ClientRectangle.Contains($entry.Bounds) -or $entry.Height -lt $trigger.Font.Height) {
                    throw '下拉选项被裁切'
                }
            }
            if (!([Windows.Forms.Screen]::FromControl($trigger).WorkingArea.Contains($popup.Bounds))) { throw '菜单超出屏幕工作区' }
        } finally { $popup.Close(); [Windows.Forms.Application]::DoEvents() }
    }
}
$appearance.Theme = $baseTheme
$appearance.Size = $baseSize
Set-HudAppearance
Update-ReminderWindow
foreach ($row in $localView.Rows) {
    $button = $list.Controls.Find("local-Codex-$($row.id)", $true)
    if ($button.Count -ne 1 -or (Get-LocalCodexUri $button[0].Tag) -cne "codex://threads/$($row.id)") {
        throw '会话按钮与目标不匹配'
    }
}
if ($header.Text -ne '智能体消息中心' -or @(Get-ReminderWaiting $state).Count -ne 0) { throw '最近一轮状态进入了等待计数' }
if (Get-LocalCodexUri 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') { throw '允许跳转到列表外的会话' }
if (Get-LocalCodexUri 'codex://settings') { throw '允许自定义跳转地址' }
$shortHeight = $list.Controls.Find("local-Codex-$($localView.Rows[0].id)",$true)[0].Height
$originalRows = $localView.Rows
$originalSources = $localView.Sources
$localView.Sources = @{Codex='ready';Qoder='ready';DSH='ready'}
$clock = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()
$day = 86400000L
# An old main chat is present as context for its active side chats. It counts only if it matches.
$familySaved=$localView.Rows; $savedDays=$localView.Days
$mainId='fa000000-0000-4000-8000-000000000001'
$sideA='fa000000-0000-4000-8000-000000000002'; $sideB='fa000000-0000-4000-8000-000000000003'
$sideC='fa000000-0000-4000-8000-000000000004'
$shellLaunch=(Get-Item Function:Start-ReminderUri).ScriptBlock
$workerStart=(Get-Item Function:Start-LocalNavigationWorker).ScriptBlock
$script:familyRequest=$null
Set-Item Function:Start-LocalNavigationWorker { param($kind,$payload,$fallback) $script:familyRequest=$payload }
$script:familyUri=$null
Set-Item Function:Start-ReminderUri { param($uri) $script:familyUri=$uri }
function Test-SideChatRail($control,[bool]$continues) {
    $frame=[Drawing.Bitmap]::new($control.Width,$control.Height)
    try {
        $control.DrawToBitmap($frame,$control.ClientRectangle)
        $x=Get-HudPixels 37
        $surface=$frame.GetPixel($x-3,2).ToArgb()
        if ($frame.GetPixel($x,2).ToArgb() -eq $surface -or
            ($frame.GetPixel($x,$control.Height-3).ToArgb() -ne $surface) -ne $continues) {
            throw "侧聊引线在入口、子项之间未接齐或末项未收尾 $($control.Name)"
        }
    } finally { $frame.Dispose() }
}
try {
    $localView.Days=1
    $localView.Rows=@(
        @{agent='Codex';id=$mainId;name='核对月度报告';turn='completed';activity=$clock-3*$day;message=$clock-3*$day;created=$clock-4*$day}
        @{agent='Codex';id=$sideA;rootId=$mainId;parentId=$mainId;name='确认统计口径';turn='inProgress';needsInput=1;activity=$clock;message=$clock-200;created=$clock-400}
        @{agent='Codex';id=$sideB;rootId=$mainId;parentId=$sideA;name='复核汇总公式';turn='completed';unread=1;finished=$clock-5;activity=$clock;message=$clock-5;created=$clock-300}
        @{agent='Codex';id=$sideC;rootId=$mainId;parentId=$mainId;name='整理原始数据';turn='inProgress';activity=$clock;message=$clock-100;created=$clock-280}
        @{agent='Qoder';id=$mainId;desktop=$true;name='排版校对';turn='completed';activity=$clock;message=$clock;created=$clock-100}
    )
    Update-ReminderWindow
    $headerRow=$list.Controls[0]; $groupButton=$list.Controls[1]
    if ($headerRow.Tag -cne $mainId -or $headerRow.Detail -notmatch '主会话.*筛选时段外' -or
        $groupButton.Name -cne "sidechats-$mainId" -or $groupButton.AccessibleName -notmatch '展开 3 个侧聊.*1 待输入.*1 完成未读.*1 进行中' -or
        $list.Controls.Count -ne 3 -or $localChrome.Section.Text -ne '4 个会话' -or
        ($localChrome.Pill.Values -join ',') -ne '1,1,1,4,2') { throw '收起的主侧聊分组遗漏提醒、顺序或重复计数' }
    Test-SideChatRail $groupButton $false
    $groupButton.PerformClick()
    if ($list.Controls.Count -ne 6 -or $list.Controls[2].Tag -cne $sideB -or
        $list.Controls[2].Detail -notmatch '侧聊' -or $list.Controls[2].Indicator -ne 'CompletedUnread' -or
        $groupButton.AccessibleName -notmatch '^收起') { throw '侧聊展开或置顶错误' }
    foreach ($i in 1..3) { Test-SideChatRail $list.Controls[$i] $true }
    Test-SideChatRail $list.Controls[4] $false
    if ($familyUri) { throw '展开侧聊意外打开了应用' }
    $list.Controls.Find("local-Codex-$sideA",$false)[0].PerformClick()
    if ($familyUri -cne "codex://threads/$mainId") { throw '侧聊行交给系统的目标不是主会话' }
    if ($familyRequest.rootId -cne $mainId -or $familyRequest.steps.Count -ne 1 -or $familyRequest.steps[0].id -cne $sideA) { throw '行点击没有选中具体侧聊' }
    $plan=(Get-LocalNavigationTarget Codex $sideB).Payload
    if (($plan.steps.id -join '/') -cne "$sideA/$sideB" -or $plan.rootTitle -cne '核对月度报告') { throw '嵌套侧聊路径错误' }
    $script:familyRequest=$null
    Open-LocalHudSession Codex $mainId
    if ($familyRequest) { throw '主会话意外开启了侧聊' }
    $localView.Rows[1].desktopTitle='精确 标题' + ('甲' * 85)
    if ((Get-LocalNavigationTarget Codex $sideA).Payload.steps[0].title -cne $localView.Rows[1].desktopTitle) { throw '侧聊定位使用了截断标题' }
    $localView.Rows[3].desktopTitle=$localView.Rows[1].desktopTitle
    $ambiguous=Get-LocalNavigationTarget Codex $sideA
    if ($ambiguous.Worker -or !$ambiguous.Notice -or $ambiguous.Uri -cne "codex://threads/$mainId") { throw '同名侧聊没有安全退回主会话' }
    [void]$localView.Rows[1].Remove('desktopTitle'); [void]$localView.Rows[3].Remove('desktopTitle')
    foreach ($id in $sideA,$sideB,$sideC,$mainId) {
        if ((Get-LocalNavigationTarget Codex $id).Uri -cne "codex://threads/$mainId") { throw '侧聊没有定位到根主会话' }
    }
    if ((Get-LocalNavigationTarget Qoder $mainId).Uri -cne "qoder://chat/open?sessionId=$mainId") { throw '同 ID 的其他来源被并入了主会话' }
    Update-ReminderWindow
    if ($list.Controls[1] -ne $groupButton -or $list.Controls.Count -ne 6) { throw '刷新重置了分组展开状态' }
    $localView.Rows[0].activity=$clock
    Update-ReminderWindow
    if ($localChrome.Section.Text -ne '5 个会话' -or $headerRow.Detail -notmatch '主会话.*已完成') { throw '主会话匹配时自身状态与计数错误' }
    $localView.Rows += @(foreach ($i in 1..12) {
        @{agent='DSH';id="family-page-$i";name="独立会话 $i";turn='completed';activity=$clock;message=$clock-$i;created=$clock-$i}
    })
    Update-ReminderWindow
    if (!$localChrome.Next.Visible -or $list.Controls[0] -ne $headerRow -or $list.Controls[1] -ne $groupButton) { throw '按分组分页拆散了优先会话' }
    $localChrome.Next.PerformClick()
    if ($list.Controls.Find("sidechats-$mainId",$false).Length -or $list.Controls.Find("local-Codex-$sideA",$false).Length) { throw '同组侧聊跨页重复' }
    $localChrome.Prev.PerformClick()
    $groupButton=$list.Controls.Find("sidechats-$mainId",$false)[0]
    if (!$list.Controls.Find("local-Codex-$sideA",$false).Length) { throw '分页回来后分组展开状态丢失' }
    $groupButton.PerformClick()
    $localView.Rows=@($localView.Rows | Where-Object { $_.agent -cne 'DSH' })
    $localView.Rows[1].rootId=$null
    Update-ReminderWindow
    $detached=$list.Controls.Find("local-Codex-$sideA",$false)[0]
    if ($detached.CanOpen -or $detached.Detail -notmatch '主会话不可用' -or (Get-LocalCodexUri $sideA)) { throw '失去主会话后仍会单独打开侧聊' }
} finally {
    Set-Item Function:Start-ReminderUri $shellLaunch
    Set-Item Function:Start-LocalNavigationWorker $workerStart
    [void]$localChrome.ExpandedGroups.Remove($mainId)
    $localView.Rows=$familySaved; $localView.Days=$savedDays
    Update-ReminderWindow
}
$shared = $originalRows[0].id
$localView.Rows = @(
    @{agent='Codex';id=$shared;name='A';created=$clock-4*$day;message=$clock-1000;activity=$clock-1000;turn='inProgress'},
    @{agent='Qoder';id=$shared;name='B';created=$clock-4*$day;message=$clock-2*$day;activity=$clock-2*$day;turn='unknown'},
    @{agent='DSH';id='d';name='C';created=$clock-10000;message=$null;activity=$clock-10000;turn='unknown'},
    @{agent='DSH';id='old';name='old';created=$clock-9*$day;message=$clock-8*$day;activity=$clock-8*$day;turn='unknown'}
)
Update-ReminderWindow
if ($list.Controls.Count -ne 3 -or $list.Controls[0].Text -ne 'A' -or $list.Controls[2].Text -ne 'C') { throw '默认时间或消息排序错误' }
if (($localChrome.Pill.Values -join ',') -cne ',,1,3,0') { throw '混合来源的筛选统计错误' }
$mixed = @(foreach ($i in 1..29) {
    $turn = if ($i -le 2) { 'inProgress' } elseif ($i -le 26) { 'completed' } elseif ($i -eq 27) { 'idle' } else { 'unknown' }
    @{agent='Codex';id="exact-$i";turn=$turn}
})
$localView.Sources.Qoder = 'partial'
$counts = Get-LocalAttention $mixed @() ([datetimeoffset]::UtcNow)
$localView.Sources.Qoder = 'ready'
if (($counts.Values -join ',') -cne ',,2,29,24') { throw '未知状态或部分来源影响了已列出会话的精确计数' }
if ($list.Controls[1].CanOpen -or $list.Controls[1].Agent -ne 'Qoder') { throw '混合来源行复用了 Codex 跳转' }
if ((Get-LocalNavigationTarget Qoder $shared) -or (Get-LocalNavigationTarget Codex $shared).Uri -cne "codex://threads/$shared") { throw '相同 ID 路由混淆' }
if (!$list.Controls[2].CanOpen) { throw 'DSH 会话应可打开' }
# Compare rendered frames with two simultaneous agents, a waiting row and an unread completion.
function Get-BitmapHash($bitmap) {
    $stream = [IO.MemoryStream]::new()
    try {
        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray()))
    } finally { $stream.Dispose() }
}
function Get-RowFrame($row) {
    $bitmap = [Drawing.Bitmap]::new($row.Width,$row.Height)
    try {
        $row.DrawToBitmap($bitmap,$row.ClientRectangle)
        Get-BitmapHash $bitmap
    } finally { $bitmap.Dispose() }
}
$priorRows = $localView.Rows
$priorBadges = $localView.DshBadges
$localTimer.Stop()
try {
    $localView.Rows = @(
        @{agent='Codex'; id='motion-a'; name='并行任务 A'; turn='inProgress'; activity=$clock; message=$clock},
        @{agent='DSH'; id='motion-b'; name='并行任务 B'; desktopTitle='并行任务 B'; turn='completed'; activity=$clock; message=$clock-1},
        @{agent='Qoder'; id='motion-c'; name='等待回答'; turn='inProgress'; needsInput=1; activity=$clock; message=$clock-2},
        @{agent='Codex'; id='motion-d'; name='完成未读'; turn='completed'; unread=1; finished=$clock-1; activity=$clock; message=$clock-3}
    )
    $localView.DshBadges = @{'并行任务 B'='running'}
    Update-ReminderWindow
    [Windows.Forms.Application]::DoEvents()
    $rows = @($list.Controls)
    if (($rows.Indicator -join ',') -ne 'CompletedUnread,Running,Running,Attention') { throw '行指示器没有采用会话的最终状态' }
    $allowed = [JieShou.SessionActivityAnimation]::MotionAllowed
    if ($localChrome.ActivityAnimation.Enabled -ne $allowed) { throw '动效没有遵循 Windows 动画设置' }
    $before = @($rows | ForEach-Object { Get-RowFrame $_ })
    $end = [datetime]::UtcNow.AddMilliseconds(300)
    do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } while ([datetime]::UtcNow -lt $end)
    for ($i=0; $i -lt $rows.Count; $i++) {
        if (((Get-RowFrame $rows[$i]) -ne $before[$i]) -ne ($allowed -and $rows[$i].Indicator -eq 'Running')) { throw "会话行 $i 的动效与状态不符" }
    }
    # A new message moves an existing native row; a no-op refresh keeps its HWND, focus and position.
    $moving=$rows[3]
    $hwnd=$moving.Handle
    $startTop=$moving.Top
    $destination=$rows[1].Top
    $localView.Rows[2].message=$clock+100
    Update-ReminderWindow
    if (![object]::ReferenceEquals($moving,$list.Controls[1]) -or $moving.Handle -ne $hwnd) { throw '会话换位时重建了原生行' }
    if ($allowed) {
        if (!$list.IsReordering) { throw '新消息换位没有启动动效' }
        $seenBetween=$false
        $until=[datetime]::UtcNow.AddMilliseconds(430)
        do {
            [Windows.Forms.Application]::DoEvents()
            if ($moving.Top -gt $destination -and $moving.Top -lt $startTop) { $seenBetween=$true }
            Start-Sleep -Milliseconds 6
        } while ($list.IsReordering -and [datetime]::UtcNow -lt $until)
        if (!$seenBetween -or $list.IsReordering) { throw '会话换位缺少中间帧或没有结束' }
    }
    if ($moving.Top -ne $destination) { throw '会话动画最终位置错误' }
    $moving.Focus() | Out-Null
    $localView.Rows[2].name='更新后的标题'
    Update-ReminderWindow
    if ($moving.Handle -ne $hwnd -or $moving.Text -ne '更新后的标题' -or $list.IsReordering -or !$moving.Focused) { throw '原位刷新丢失焦点、标题或误触发换位' }
    $localView.Rows[2].message=$clock-2
    Update-ReminderWindow
    if ($allowed) {
        # Retarget before the first move finishes. Keep the latest order as the final layout.
        $localView.Rows[2].message=$clock+101
        Update-ReminderWindow
        $localView.Rows[2].message=$clock-2
        Update-ReminderWindow
        $until=[datetime]::UtcNow.AddMilliseconds(420)
        do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 8 } while ($list.IsReordering -and [datetime]::UtcNow -lt $until)
        if ($list.IsReordering -or $moving.Top -ne $startTop -or $list.Controls[3].Handle -ne $hwnd) { throw '连续换位的最终位置或句柄有误' }
    }
    $localView.Rows[0].turn = 'completed'
    Update-ReminderWindow
    if (($list.Controls.Indicator -join ',') -ne 'CompletedUnread,None,Running,Attention') { throw '一个任务完成时影响了其他进行中任务' }
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    if ($localChrome.ActivityAnimation.Enabled) { throw '收起后列表动效仍在运行' }
    $localChrome.Pill.PerformClick()
    if ($localChrome.ActivityAnimation.Enabled -ne $allowed) { throw '展开后列表动效没有恢复' }
    $localView.DshBadges.Clear()
    Update-ReminderWindow
    if ($localChrome.ActivityAnimation.Enabled) { throw '最后一个运行任务结束后仍在刷新动效' }
    # Both unread sessions would fall on page two without priority. Their two time orders disagree.
    $regular = @(foreach ($i in 1..12) {
        @{agent='Codex';id="priority-$i";turn='completed';activity=$clock;message=$clock-$i;created=$clock-$i}
    })
    $recent = @{agent='Qoder';id='shared';name='近期完成';turn='completed';unread=1;finished=$clock-100;activity=$clock;message=$clock-100;created=$clock-400}
    $older = @{agent='Codex';id='shared';name='较早完成';turn='completed';unread=1;finished=$clock-2*$day;activity=$clock-2*$day;message=$clock-2*$day;created=$clock-300}
    $localView.Rows = $regular + @($recent,$older)
    Update-ReminderWindow
    if ($list.Controls.Count -ne 12 -or $list.Controls[0].Agent -ne 'Qoder' -or $list.Controls[1].Agent -ne 'Codex' -or
        $list.Controls[0].Indicator -ne 'CompletedUnread' -or $list.Controls[1].Indicator -ne 'CompletedUnread' -or
        $localChrome.Pill.Values[1] -ne '1') { throw '完成未读没有跨页置顶，或 24 小时胶囊计数发生变化' }
    $localChrome.Sort.ContextMenuStrip.Items[1].PerformClick()
    if ($list.Controls[0].Text -ne '较早完成' -or $list.Controls[1].Text -ne '近期完成') { throw '置顶组没有沿用最新创建排序' }
    $older.unread=0
    Update-ReminderWindow
    if ($list.Controls[0].Text -ne '近期完成' -or $list.Controls[1].Indicator -ne 'None') { throw '已读后未解除置顶' }
    $localChrome.Next.PerformClick()
    if ($list.Controls[$list.Controls.Count-1].Text -ne '较早完成' -or $list.Controls[$list.Controls.Count-1].Indicator -ne 'None') { throw '已读会话没有回到普通排序的位置' }
    $localChrome.Sort.ContextMenuStrip.Items[0].PerformClick()
} finally {
    $localView.Rows=$priorRows; $localView.DshBadges=$priorBadges
    Update-ReminderWindow
    $localTimer.Start()
}
$when = [datetimeoffset]::FromUnixTimeMilliseconds($clock)
$focused = @(
    @{agent='Codex';id=$shared;turn='inProgress'},
    @{agent='Qoder';id=$shared;turn='completed';finished=$clock-100;unread=1},
    @{agent='DSH';id='d';turn='inProgress';needsInput=1},
    @{agent='Codex';id='running';turn='inProgress'},
    @{agent='Codex';id='old';turn='completed';finished=$clock-86400000L;unread=1},
    @{agent='Codex';id='read';turn='completed';finished=$clock-100;unread=0},
    @{agent='Codex';id='unverified';turn='completed';finished=$clock-100}
)
$requests = @(@{Event=@{TaskId=$shared}},@{Event=@{TaskId=$shared}})
$signals = Get-LocalAttention $focused $requests $when
if (($signals.Values -join ',') -cne '2,1,1,7,4' -or $signals.Labels["Qoder/$shared"] -ne '完成未读') { throw '提醒优先级、跨 Agent 或去重错误' }
if ($signals.Breakdown[0].ByAgent['Codex'] -ne 1 -or $signals.Breakdown[0].ByAgent['DSH'] -ne 1 -or
    $signals.Breakdown[1].ByAgent['Qoder'] -ne 1 -or $signals.Breakdown[2].ByAgent['Codex'] -ne 1) { throw '应用计数与最终会话状态不一致' }
$focused[1].desktop = $true
$nativeBadges=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$localView.QoderSnapshot = @{Badges=$nativeBadges; StartedAt=$clock-1000}
$nativeBadges[$shared]='waiting'
$nativeWaiting = Get-LocalAttention $focused $requests $when
if ($nativeWaiting.Breakdown[0].ByAgent['Qoder'] -ne 1 -or $nativeWaiting.Breakdown[1].Total -ne 0 -or
    ($nativeWaiting.Values -join ',') -ne '3,,1,7,3') { throw 'Qoder 实时待输入应优先于磁盘上的完成状态' }
$nativeBadges[$shared]='running'
$nativeRunning=Get-LocalAttention $focused $requests $when
if ($nativeRunning.Labels["Qoder/$shared"] -cne '进行中' -or ($nativeRunning.Values -join ',') -ne '2,,2,7,3') {
    throw 'Qoder 开始新一轮时仍显示上轮已完成，或运行计数错误'
}
$nativeBadges.Clear()
$offscreen=@(@{agent='Qoder';id='live';desktop=$true;turn='unknown';bufferedSince=$clock},
             @{agent='Qoder';id='stale';desktop=$true;turn='unknown';bufferedSince=$clock-2000},
             @{agent='Qoder';id='ide';turn='unknown';bufferedSince=$clock})
$buffered=Get-LocalAttention $offscreen @() $when
if ($buffered.Labels['Qoder/live'] -cne '进行中' -or $buffered.Values[2] -ne '1') { throw 'Qoder 缓冲跨进程或跨来源误计' }
$nativeBadges['live']='waiting'
if (((Get-LocalAttention $offscreen @() $when).Values -join ',') -ne '1,,0,3,0') { throw 'Qoder 待输入仍计入运行中' }
$localView.QoderSnapshot=$null
if ((Get-LocalAttention $offscreen @() $when).Values[2] -ne '0') { throw 'Qoder 离线后仍使用运行缓冲' }
$before = $localView.Rows
try {
    $localView.Rows = @($focused | ForEach-Object { $_.activity=$clock; $_.created=$clock; $_.message=$clock; $_ })
    Update-ReminderWindow
    if ($localChrome.Pill.Caption() -ne '待输入 1 · 完成未读 1 · 进行中 2 · 任务 7 · 已完成 4' -or
        $list.Controls.Find("local-Qoder-$shared",$true)[0].Detail -notlike '*完成未读' -or
        $list.Controls.Find('local-DSH-d',$true)[0].Detail -notlike '*待输入') { throw '胶囊与展开列表的提醒不一致' }
    $pill = $localChrome.Pill
    $nativeBadges[$shared]='running'
    $localView.QoderSnapshot=@{Badges=$nativeBadges; StartedAt=$clock-1000}
    Update-ReminderWindow
    if ($list.Controls.Find("local-Qoder-$shared",$true)[0].Indicator -ne 'Running' -or
        ($pill.Values -join ',') -ne '1,,3,7,3') { throw 'Qoder 运行标记没有同步到行和胶囊' }
    $localView.QoderSnapshot=$null
    Update-ReminderWindow
    $simpleWidth = $pill.RequiredWidth()
    $appearance.PillMode = '丰富模式'
    Set-HudAppearance
    Update-ReminderWindow
    if ($pill.AccessibleName -ne '待输入 1（DSH 1） · 完成未读 1（Qoder 1） · 进行中 2（Codex 2） · 任务 7 · 已完成 4' -or
        $pill.RequiredWidth() -le $simpleWidth) { throw '丰富模式缺少按状态分组的应用和数量' }
    $available = Get-HudPixels 250
    $wrapped = $pill.MeasureForWidth($available)
    if ($wrapped.Width -gt $available -or $wrapped.Height -le (Get-HudPixels ($appearance.Size+22))) { throw '窄屏没有按状态换行' }
    $localChrome.Agents[3].PerformClick()
    if ($pill.AccessibleName -ne '完成未读 1（Qoder 1） · 进行中 0 · 任务 1 · 已完成 1') { throw '丰富模式没有跟随应用筛选' }
} finally {
    $localChrome.Agents[0].PerformClick()
    $appearance.PillMode='极简模式'
    Set-HudAppearance
    $localView.Rows = $before
    Update-ReminderWindow
}
$beforeRows = $localView.Rows
try {
    $case = @{agent='DSH'; id='native'; desktopTitle='标记测试'; turn='completed'; finished=$clock-100; activity=$clock-100}
    $localView.Rows = @($case)
    $localView.DshBadges = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($pair in @(@('running',',,1,1,0','进行中'),@('waiting','1,,0,1,0','待输入'),@('unread',',1,0,1,1','完成未读'))) {
        $localView.DshBadges[$case.desktopTitle] = $pair[0]
        $native = Get-LocalAttention @($case) @() $when
        if (($native.Values -join ',') -ne $pair[1] -or $native.Labels['DSH/native'] -ne $pair[2]) { throw "DSH 侧栏状态错误 $($pair[0])" }
    }
    if ((Get-LocalAttention @($case) @() $when.AddDays(1)).Values[1]) { throw 'DSH 旧完成标记进入了 24 小时提醒' }
    $localView.Rows += @{agent='DSH';id='other';desktopTitle=$case.desktopTitle;activity=0}
    if ((Get-LocalAttention @($case) @() $when).Values[1]) { throw '跨筛选范围的 DSH 重名错误地收到了提醒' }
    $localView.Rows = @($case)
    $localView.DshBadges.Clear()
    if ((Get-LocalAttention @($case) @() $when).Values[1]) { throw 'DSH 无标记时仍显示完成未读' }
} finally { $localView.Rows=$beforeRows; $localView.DshBadges=$null }
$focused[1].unread = 0
if ((Get-LocalAttention $focused $requests $when).Values[1]) { throw '原应用读回执没有清除提醒' }
$focused[1].unread = 1
$localView.NextExpiry=[datetime]::MaxValue
$signals = Get-LocalAttention $focused @() $when
if ($localView.NextExpiry -ne $when.AddMilliseconds(86400000-100).UtcDateTime) { throw '完成未读到期时间错误' }
$expired = Get-LocalAttention $focused @() $when.AddDays(1)
if ($expired.Values[1] -or $expired.Values[0] -ne '1') { throw '未读提醒超时或失效请求仍在计数' }
$localView.Rows[1].desktop = $true
if ((Get-LocalNavigationTarget Qoder $shared).Uri -cne "qoder://chat/open?sessionId=$shared") { throw 'Qoder 独立版链接错误' }
$localView.Rows[2].desktopTitle = '同名'
$localView.Rows[3].desktopTitle = '同名'
if ((Get-LocalNavigationTarget DSH 'd').Unique) { throw 'DSH 重名应留给用户选择' }
$localView.Rows[3].desktopTitle = '另一个标题'
if (!(Get-LocalNavigationTarget DSH 'd').Unique) { throw 'DSH 唯一标题无法定位' }
Update-ReminderWindow
if (!$list.Controls[1].CanOpen -or $list.Controls[1].Agent -ne 'Qoder') { throw 'Qoder 独立版跳转不可用' }
$localChrome.Sort.ContextMenuStrip.Items[1].PerformClick()
if ($list.Controls[0].Text -ne 'C' -or $localView.Sort -ne 'created') { throw '最新创建排序未生效' }
$localChrome.Range.ContextMenuStrip.Items[0].PerformClick()
if ($list.Controls.Count -ne 2 -or $localView.Days -ne 1) { throw '近 24 小时未生效' }
$localChrome.Agents[3].PerformClick()
if ($list.Controls[0] -isnot [Windows.Forms.Label]) { throw '空来源状态错误' }
$localChrome.Toggle.PerformClick()
Wait-HudMotion
if ($expanded -or ($localChrome.Pill.Values -join ',') -cne ',,0,0,0') { throw '空范围收起后未显示精确的零' }
$localChrome.Pill.PerformClick()
$localChrome.Range.ContextMenuStrip.Items[2].PerformClick()
$localChrome.Toggle.PerformClick()
Wait-HudMotion
if (($localChrome.Pill.Values -join ',') -cne ',,0,1,0' -or $localChrome.Pill.AccessibleDescription -notmatch 'Qoder.*全部时间') { throw 'Qoder 胶囊统计与范围不符' }
$localChrome.Pill.PerformClick()
if ($list.Controls[0].Text -ne 'B' -or $list.Controls[0].Agent -ne 'Qoder') { throw '选择单个来源失败' }
$localView.Sources.DSH='unavailable'
$localChrome.Agents[2].PerformClick()
if ($localChrome.Pill.AccessibleName -ne 'DSH 暂不可读' -or $localChrome.Pill.Values.Length -ne 0 -or
    $localChrome.Section.Text -ne '会话数未知') { throw '索引不可读时显示了确定的零计数' }
$localChrome.Agents[1].PerformClick()
if (($localChrome.Pill.Values -join ',') -cne ',,1,1,0') { throw '其他来源失联影响了 Codex 计数' }
$localView.Sources.DSH='missing'
$localChrome.Agents[2].PerformClick()
if ($localChrome.Pill.AccessibleName -ne '未找到 DSH 索引' -or $localChrome.Pill.Values.Length) { throw '未安装来源误报零会话' }
$localView.Sources.DSH='ready'
$localChrome.Agents[0].PerformClick()
if ($list.Controls.Count -ne 4) { throw '全部时间漏掉旧会话' }
$localChrome.Range.ContextMenuStrip.Items[1].PerformClick()
$localChrome.Sort.ContextMenuStrip.Items[0].PerformClick()
$localView.Rows = @(@{agent='DSH';id='boundary';activity=$clock-$day;message=$clock-$day})
$localView.Days = 1
if (@(Get-VisibleSessions ([datetimeoffset]::FromUnixTimeMilliseconds($clock))).Count -ne 1 -or
    @(Get-VisibleSessions ([datetimeoffset]::FromUnixTimeMilliseconds($clock+1))).Count) { throw '滚动时间边界未生效' }
$localView.Rows[0].turn = 'completed'
$localView.Rows[0].activity = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()-$day+500
$localChrome.Toggle.PerformClick()
Wait-HudMotion
if (($localChrome.Pill.Values -join ',') -ne ',,0,1,1') { throw '收起后的已完成计数错误' }
$savedRead = $localView.NextRead
$localView.NextRead = [datetime]::UtcNow.AddMinutes(1)
Start-Sleep -Milliseconds 560
Update-LocalSessionList
if (($localChrome.Pill.Values -join ',') -ne ',,0,0,0') { throw '索引未变时，收起的胶囊未移除过期会话' }
$localView.NextRead = $savedRead
$localChrome.Pill.PerformClick()
$localView.Days = 7
$localView.Rows = @(foreach ($index in 1..14) {
    @{ agent='Codex'; id=[guid]::NewGuid().ToString(); turn='completed'; created=$clock-$index; activity=$clock-$index; message=$clock-$index;
       name=('核对本地项目会话的显示、跳转与等待状态 ' * 4) }
})
Update-ReminderWindow
[Windows.Forms.Application]::DoEvents()
$first = $list.Controls[0]
if ($first.Height -le $shortHeight -or $first.Height -lt $first.ContentHeight()) { throw '长标题未获得足够的换行高度' }
if ($localView.NextExpiry -gt [datetime]::Today.AddDays(1).ToUniversalTime()) { throw '跨午夜的日期标签未安排刷新' }
if (!$list.VerticalScroll.Visible -or $list.HorizontalScroll.Visible) { throw '长列表应仅纵向滚动' }
$list.AutoScrollPosition = [Drawing.Point]::Empty
Test-ScrollGutter $list $localScrollBar
$endOffset = -$list.AutoScrollPosition.Y
if ($endOffset -le 0 -or $endOffset -ne $list.VerticalScroll.Maximum-$list.VerticalScroll.LargeChange+1) { throw '会话滑块未到达列表底部' }
Update-ReminderWindow
$localChrome.Agents[0].PerformClick()
if (-$list.AutoScrollPosition.Y -ne $endOffset) { throw '会话刷新丢失了滚动位置' }
if (!$localScrollBar.ScrollKey('Home') -or $list.AutoScrollPosition.Y -ne 0 -or !$localScrollBar.ScrollKey('PageDown') -or
    $list.AutoScrollPosition.Y -ge 0) { throw '会话列表键盘滚动失败' }
if ($localChrome.Next.Bottom -gt $localScrollBar.Top -or $window.ClientSize.Height-$localScrollBar.Bottom -gt (Get-HudPixels 6)) {
    throw '分页或列表底部仍占用多余空间'
}
$localChrome.Next.PerformClick()
if ($localView.Page -ne 1 -or !$list.Controls.Find("local-Codex-$($localView.Rows[-1].id)",$true).Count -or
    $localChrome.Next.Enabled -or !$localChrome.Prev.Enabled) { throw '不能浏览最后一页' }
$localChrome.Agents[0].PerformClick()
$localChrome.Sort.ContextMenuStrip.Items[0].PerformClick()
if ($localView.Page -ne 1) { throw '重复选择当前来源或排序重置了页码' }
$localChrome.Prev.PerformClick()
if ($localView.Page -ne 0) { throw '不能返回第一页' }
if ($localChrome.Pill.Values[3] -ne '14') { throw '统计只覆盖当前页' }
$localView.Sources = $originalSources
$localView.Rows = $originalRows
Update-ReminderWindow
$localChrome.Toggle.PerformClick()
Wait-HudMotion
if ($localChrome.Range.Visible -or $localChrome.Agents[0].Visible -or $list.Visible -or $window.Height -ne (Get-HudPixels ($appearance.Size + 22))) { throw '收起后应为单行' }
$localChrome.Pill.PerformClick()
if (!$list.Visible -or $window.Controls.Find("local-activity",$true).Count) { throw '再次展开后缺少操作入口' }
$prefsFile = Join-Path ([IO.Path]::GetTempPath()) ("hud-appearance-{0}.json" -f [guid]::NewGuid())
$previousPath = $appearancePath
$script:appearancePath = $prefsFile
try {
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor = $localChrome.AppearanceDialog
    $editorSize=$editor.Size
    $pageHost=$editor.Controls['appearance-scroll']
    $pageContent=$editor.Controls.Find('appearance-content',$true)[0]
    $tabs=$editor.Controls.Find('appearance-page',$true)[0]
    $saveButton=$editor.Controls.Find('appearance-save',$true)[0]
    foreach ($fraction in .7,.8) {
        $editor.Height=[int]($editorSize.Height*$fraction)
        [Windows.Forms.Application]::DoEvents()
        $navRect=$tabs.RectangleToScreen($tabs.ClientRectangle)
        $saveRect=$saveButton.RectangleToScreen($saveButton.ClientRectangle)
        Test-ScrollGutter $pageContent $pageHost
        if($saveButton.RectangleToScreen($saveButton.ClientRectangle) -ne $saveRect -or $tabs.RectangleToScreen($tabs.ClientRectangle) -ne $navRect -or
            !$editor.RectangleToScreen($editor.ClientRectangle).Contains($saveRect)) { throw '滚动设置时导航或保存按钮离开了固定位置' }
        if ($pageContent.AutoScrollPosition.Y -ge 0 -or !$pageHost.ScrollKey('Home')) { throw '设置页拖动或返回顶部失败' }
    }
    $editor.Width=Get-HudPixels 420
    $narrowBounds=$editor.Bounds
    foreach($tab in '胶囊外观','位置与方向','关于','胶囊外观') {
        $tabs.SelectedItem=$tab
        [Windows.Forms.Application]::DoEvents()
        if($editor.Bounds -ne $narrowBounds -or $pageContent.HorizontalScroll.Visible) {throw "窄屏切换 $tab 改变窗口位置或需要横向滚动"}
    }
    $modeField=$editor.Controls.Find('appearance-mode',$true)[0]
    $fontField=$editor.Controls.Find('appearance-font',$true)[0]
    if($fontField.Top -le $modeField.Bottom -or $modeField.Left -ne $fontField.Left) { throw '窄屏没有堆叠设置分组' }
    $editor.Size=$editorSize
    if($editor.ClientSize.Width -ge (Get-HudPixels 800) -and ($fontField.Left -le $modeField.Right -or $fontField.Top -ne $modeField.Top)) {
        throw '宽屏横向预览下的设置分组没有并排对齐'
    }
    if (!$editor.Visible -or $editor.Modal -or !$window.Enabled -or !$editor.TopMost -or $window.TopMost) { throw '设置遮挡主窗或阻断主窗操作' }
    Send-TestOutsidePress $editor.Handle
    Send-TestOutsidePress ([JieShou.Tests.ScrollGesture]::GetDesktopWindow())
    if (!$expanded -or !$editor.Visible) { throw '编辑设置时外部点击打断了列表或编辑器' }
    if (!([Windows.Forms.Screen]::FromControl($window).WorkingArea.Contains($editor.Bounds))) { throw '设置窗口超出工作区' }
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    if (![object]::ReferenceEquals($editor,$localChrome.AppearanceDialog)) { throw '重复打开了多个设置窗口' }
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    if ($expanded -or !$editor.Visible) { throw '设置打开时主窗不能收起' }
    $localChrome.Pill.PerformClick()
    $modes = $editor.Controls.Find('appearance-mode',$true)[0]
    $sample = $editor.Controls.Find('appearance-preview',$true)[0]
    $page=$editor.Controls.Find('appearance-page',$true)[0]
    $page.SelectedItem='关于'
    $about=$editor.Controls.Find('appearance-about',$true)[0]
    $appVersion=(Get-Content -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Raw).Trim()
    if (!$about.Visible -or $sample.Visible -or $about.Controls.Text -notcontains 'AMC' -or
        $about.Controls.Text -notcontains 'Agent Message Center' -or $about.Controls.Text -notcontains "版本 $appVersion" -or !$about.Controls[0].Image) { throw '关于页缺少品牌标识或当前版本' }
    $page.SelectedItem='胶囊外观'
    $horizontalPreviewHeight=$sample.Parent.Height
    $minimalFrame = Get-RowFrame $sample
    $modes.Controls.Find('丰富模式',$false)[0].PerformClick()
    if ($sample.AccessibleName -notmatch '进行中 2（Codex 2）' -or (Get-RowFrame $sample) -eq $minimalFrame -or
        !$sample.Parent.ClientRectangle.Contains($sample.Bounds) -or !$sample.AgentIcons['codex'] -or !$sample.AgentIcons['dsh'] -or
        $appearance.PillMode -ne '极简模式') { throw '丰富模式预览或应用时机错误' }
    $modes.SelectedItem = '极简模式'
    $choice = $editor.Controls.Find('appearance-font',$true)[0]
    if ($choice.Options.DrawMode -ne 'OwnerDrawFixed' -or $choice.BackColor -ne $hudColors.Chrome) { throw '外观下拉框未跟随主题' }
    $choice.DroppedDown = $true
    [Windows.Forms.Application]::DoEvents()
    if (!$choice.DroppedDown) { throw '外观选项未展开' }
    if ($choice.Items.Count -gt $choice.DropDownHeight/$choice.ItemHeight) {
        $selected = $choice.SelectedIndex
        $choice.Options.TopIndex = 0
        Test-ScrollGutter $choice.Options $choice.Options.Parent.Parent
        [Windows.Forms.Application]::DoEvents()
        if (!$choice.DroppedDown -or $choice.SelectedIndex -ne $selected -or $choice.Options.TopIndex -eq 0) { throw '拖动字体滑块意外关闭下拉框或选中了其他字体' }
        $choice.Options.SelectedIndex=($selected+1)%$choice.Items.Count
        $choice.DroppedDown=$false
        if ($choice.SelectedIndex -ne $selected) { throw '关闭下拉时意外提交了浏览中的字体' }
        $choice.DroppedDown=$true
        if ($choice.Options.SelectedIndex -ne $selected) { throw '重新展开没有定位到当前字体' }
        $choice.Options.SelectedIndex=($selected+1)%$choice.Items.Count
        $keyMessage=[Windows.Forms.Message]::Create($choice.Options.Handle,0x100,[IntPtr]27,[IntPtr]1)
        if (!$choice.Options.PreProcessMessage([ref]$keyMessage) -or $choice.DroppedDown -or !$editor.Visible -or
            $choice.SelectedIndex -ne $selected) { throw 'Esc 取消字体选择时意外提交或关闭了设置' }
        $choice.DroppedDown=$true
        $newFont=($selected+1)%$choice.Items.Count
        $choice.Options.SelectedIndex=$newFont
        $keyMessage=[Windows.Forms.Message]::Create($choice.Options.Handle,0x100,[IntPtr]13,[IntPtr]1)
        if (!$choice.Options.PreProcessMessage([ref]$keyMessage) -or $choice.DroppedDown -or !$editor.Visible -or
            $choice.SelectedIndex -ne $newFont -or $editor.Selection.Family -ne $choice.SelectedItem) { throw 'Enter 未正确提交字体选择' }
        $choice.SelectedItem=[string]$choice.Items[$selected]

    }
    $choice.DroppedDown = $false
    $rail = $editor.Controls.Find('appearance-shape',$true)[0]
    $rail.Controls.Find('圆角',$false)[0].PerformClick()
    if ($editor.Selection.Shape -ne '圆角' -or !$rail.Controls.Find('圆角',$false)[0].Checked) { throw '形状选择没有更新预览' }
    $editor.Controls.Find('appearance-shape',$true)[0].SelectedItem = '直角'
    $editor.Controls.Find('appearance-theme',$true)[0].SelectedItem = '云白'
    $editor.Controls.Find('appearance-size',$true)[0].Value = 20
    $editor.Controls.Find('appearance-opacity',$true)[0].Value = 75
    $sample = $editor.Controls.Find('appearance-preview',$true)[0]
    if ($sample.Appearance.Shape -ne '直角' -or $sample.Appearance.Size -ne 20 -or $sample.Appearance.Opacity -ne 75 -or
        $sample.Appearance.Theme -ne '云白' -or $sample.Width -lt $sample.RequiredWidth()) { throw '修改外观没有更新预览' }
    $modes.SelectedItem = '丰富模式'
    if (!$sample.Parent.ClientRectangle.Contains($sample.Bounds)) { throw '大字号丰富模式预览超出范围' }
    [IO.File]::WriteAllText($prefsFile,'{"Theme":"云白"}')
    $legacy=[JieShou.HudAppearance]::Load($prefsFile)
    if ($legacy.Orientation -ne '横向' -or $legacy.StartupAnchor -ne '右下' -or $legacy.StartupDisplay -or $legacy.RememberPosition -or $legacy.AutoHide) { throw '旧设置没有沿用主屏底边右段及常驻模式' }
    if ($legacy.PillMode -ne '极简模式' -or $legacy.Theme -ne '云白') { throw '旧版设置迁移错误' }
    [IO.File]::WriteAllText($prefsFile,'{"Orientation":"竖向","StartupAnchor":"右下","RememberPosition":true,"LastDrag":{"Display":"fixture-left","DockSlot":0}}')
    $migrated=[JieShou.HudAppearance]::Load($prefsFile)
    $migrated.StartupDock=[JieShou.HudDock]::FromLabel('下边靠右')
    $migrated.Save($prefsFile)
    $restored=Get-ReminderStartupPlacement ([JieShou.HudAppearance]::Load($prefsFile))
    if (!$restored.Vertical -or $restored.Anchor -ne 0 -or $restored.Display -ne 'fixture-left') {throw '更改备用位置覆盖了旧版记住的吸附边'}
    $scalePicker=$editor.Controls.Find('appearance-screen-scale',$true)[0]
    $targetScreen=[Windows.Forms.Screen]::FromControl($window)
    $scaleId=[JieShou.HudDisplayIds]::For($targetScreen.DeviceName)
    if($scalePicker.SelectedItem -notlike '自动*' -or $legacy.DisplayScales.Count) { throw '旧设置未默认采用自动缩放' }
    $scalePicker.SelectedItem='175%'
    if($editor.Selection.DisplayScales[$scaleId] -ne 175 -or $appearance.DisplayScales.Count -or
        [JieShou.HudDisplayScale]::For($targetScreen,$editor.Selection) -ne 168) {throw '本屏缩放没有正确预览或提前写入配置'}
    foreach($other in [Windows.Forms.Screen]::AllScreens | Where-Object DeviceName -ne $targetScreen.DeviceName) {
        if([JieShou.HudDisplayScale]::For($other,$editor.Selection) -ne [JieShou.HudDisplayScale]::Automatic($other)) {throw '本屏缩放改变了其他显示器'}
    }
    $scalePicker.SelectedItem=$scalePicker.Items[1]
    if([JieShou.HudDisplayScale]::For($targetScreen,$editor.Selection) -ne [JieShou.HudDisplayScale]::SystemDpi($targetScreen)) {throw '跟随 Windows 缩放失效'}
    $scalePicker.SelectedItem='175%'
    $selected = $editor.Selection.Copy()
    $selected.Accent = '#730DA1'
    $selected.Save($prefsFile)
    $readBack = [JieShou.HudAppearance]::Load($prefsFile)
    if($readBack.DisplayScales[$scaleId] -ne 175) { throw '单屏缩放未持久化' }
    if ($readBack.PillMode -ne '丰富模式' -or $readBack.Accent -cne '#730DA1' -or $readBack.Theme -ne '云白' -or $readBack.Opacity -ne 75 -or
        $readBack.Shape -ne '直角' -or $readBack.Family -ne $selected.Family -or $readBack.Size -ne 20) { throw '外观设置未正确保存' }
    $editor.Controls.Find('appearance-reset',$true)[0].PerformClick()
    if($editor.Selection.DisplayScales.Count -or $scalePicker.SelectedItem -notlike '自动*') { throw '恢复默认未清除自定义屏幕缩放' }
    if ($editor.Selection.PillMode -ne '极简模式' -or $editor.Selection.Shape -ne '胶囊' -or $editor.Selection.Opacity -ne 100 -or $editor.Selection.Size -ne 15) { throw '恢复默认失败' }
    if ($appearance.Shape -ne '胶囊' -or $appearance.Theme -ne '夜紫') { throw '预览更改了已应用的外观' }
    $editor.Controls.Find('appearance-theme',$true)[0].SelectedItem = '深海'
    $modes.SelectedItem = '丰富模式'
    $editor.Controls.Find('appearance-page',$true)[0].SelectedItem='位置与方向'
    $grid=$editor.Controls.Find('appearance-anchors',$true)[0]
    $grid.SelectedItem='右边靠上'
    $map=$editor.Controls.Find('appearance-screen-preview',$true)[0]
    if ($sample.Visible -or $map.MarkerBounds.IsEmpty) { throw '位置设置没有显示实际屏幕地图' }
    $rightPreview=$map.MarkerBounds.Left
    $grid.SelectedItem='左边靠上'
    if ($map.MarkerBounds.Left -ge $rightPreview -or !$map.SelectedScreenBounds.Contains($map.MarkerBounds)) { throw '九宫格预览没有随启动位置变化' }
    if (@($grid.Controls | Where-Object Visible).Count -ne 12 -or $editor.Controls.Find('appearance-direction',$true).Count) {throw '位置设置应直接选择四边十二个位置'}
    foreach($label in [JieShou.HudDock]::Labels) {
        $option=[JieShou.HudDock]::FromLabel($label)
        $point=$map.GetType().GetMethod('DockPoint',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($map,@($option))
        $click=[Windows.Forms.MouseEventArgs]::new('Left',1,$point.X,$point.Y,0)
        $map.GetType().GetMethod('OnMouseClick',[Reflection.BindingFlags]'NonPublic,Instance').Invoke($map,@($click))
        if ($grid.SelectedItem -ne $label -or $sample.Vertical -ne $option.Vertical -or $map.MapCaption -notlike "*$label*") {throw "地图点选未同步 $label"}
    }
    $grid.SelectedItem='右边居中'
    if (!$sample.Vertical -or $sample.Visible -or !$map.SelectedScreenBounds.Contains($map.MarkerBounds) -or $appearance.Orientation -ne '横向') { throw '竖向设置未隔离或屏幕地图标记越界' }
    $pages=$editor.Controls.Find('appearance-page',$true)[0]
    $pages.SelectedItem='胶囊外观'
    if ($sample.Parent.Height -le $horizontalPreviewHeight -or $sample.AccessibleName -notmatch '完成未读 1（Qoder 1）' -or !$sample.Parent.ClientRectangle.Contains($sample.Bounds)) { throw '竖向丰富模式预览缺少来源或高度未适应方向' }
    $modes.SelectedItem='极简模式'
    if ($sample.AccessibleName -match 'Codex|Qoder' -or $sample.AccessibleName -notmatch '完成未读 1 · 进行中 2 · 总数 30 · 已完成 27' -or !$sample.Parent.ClientRectangle.Contains($sample.Bounds)) { throw '竖向极简模式预览计数或布局错误' }
    $states=$editor.Controls.Find('appearance-preview-state',$true)[0]
    $states.Controls['无提醒'].PerformClick()
    $idle=$sample.Bounds
    if (!$sample.EdgeTab -or $sample.EdgePeek -or $sample.ReminderCount -or $sample.Height -le 4*$sample.Width -or
        $sample.OpensForward -or $editor.Selection.AutoHide) {throw '设置里的无提醒墨尺没有贴右边，或预览修改了实际自动隐藏设置'}
    $mouseEnter=$sample.GetType().GetMethod('OnMouseEnter',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$mouseEnter.Invoke($sample,@([EventArgs]::Empty))
    if (!$sample.EdgePeek -or $sample.ReminderCount -or $sample.AccessibleName -notmatch '进行中 2' -or
        $sample.Right -ne $idle.Right -or $sample.Width -le $idle.Width) {throw '无提醒墨尺的悬停预览改变了状态或贴边位置'}
    $states.Controls['有提醒'].PerformClick()
    if (!$sample.EdgeTab -or $sample.EdgePeek -or $sample.ReminderCount -ne 2 -or $sample.Width -le $idle.Width -or
        $sample.AccessibleName -ne '贴边提醒预览，2 条提醒，待输入 1，完成未读 1' -or $sample.Right -ne $idle.Right) {throw '双提醒短签预览的计数或贴边位置错误'}
    $states.Controls['悬停展开'].PerformClick()
    $compactHeight=$sample.Height
    $modes.SelectedItem='丰富模式'
    if (!$sample.EdgePeek -or $sample.AccessibleName -notmatch 'Qoder' -or $sample.Height -le $compactHeight -or
        $sample.Top -le $states.Bottom -or !$sample.Parent.ClientRectangle.Contains($sample.Bounds)) {throw '悬停数字栏未跟随丰富模式或超出了预览区'}
    $states.Controls['常驻胶囊'].PerformClick()
    if ($sample.EdgeTab -or $sample.EdgePeek) {throw '常驻胶囊仍然显示墨尺'}
    $modes.SelectedItem='极简模式'
    $pages.SelectedItem='位置与方向'
    # Three side-by-side displays, with the capsule at the middle of the right edge.
    $screens3=[Drawing.Rectangle[]]@([Drawing.Rectangle]::new(-2560,0,2560,1440),[Drawing.Rectangle]::new(0,-480,3840,2400),[Drawing.Rectangle]::new(3840,0,2560,1440))
    $map.SetMap($screens3,$screens3,@('屏幕 3','屏幕 1 · 主屏','屏幕 2'),2,[Drawing.Rectangle]::new(6190,600,210,240))
    $frame=[Drawing.Bitmap]::new($map.Width,$map.Height)
    try {
        $map.DrawToBitmap($frame,$map.ClientRectangle)
        $screen=$map.SelectedScreenBounds
        $cy=$screen.Top+[int]($screen.Height/2)
        $inkRows=0
        for ($y=$cy-[int]($screen.Height/4);$y -lt $cy+[int]($screen.Height/4);$y++) {
            for ($x=$screen.Left+[int]($screen.Width/4);$x -lt $screen.Right-[int]($screen.Width/4);$x++) {
                if ($frame.GetPixel($x,$y).R -gt 140) { $inkRows++; break }
            }
        }
        if ($inkRows -lt $map.Font.Size*.65) { throw '三屏预览的屏幕名称被截断或被贴边标记挤开' }
    } finally { $frame.Dispose() }
    $displays=[Drawing.Rectangle[]]@([Drawing.Rectangle]::new(-1080,-500,1080,1920),[Drawing.Rectangle]::new(0,0,1920,1080))
    $areas=[Drawing.Rectangle[]]@([Drawing.Rectangle]::new(-1080,-500,1080,1860),[Drawing.Rectangle]::new(0,0,1920,1030))
    $map.SetMap($displays,$areas,@('屏幕 2','屏幕 1'),0,[Drawing.Rectangle]::new(-80,1100,60,250))
    $leftScreen=$map.SelectedScreenBounds
    if (!$leftScreen.Contains($map.MarkerBounds) -or $map.MarkerBounds.Height -le $map.MarkerBounds.Width) { throw '副屏竖向位置标记错误' }
    $map.SetMap($displays,$areas,@('屏幕 2','屏幕 1'),1,[Drawing.Rectangle]::new(12,12,380,40))
    if ($leftScreen.Right -ne $map.SelectedScreenBounds.Left -or $leftScreen.Top -ge $map.SelectedScreenBounds.Top -or
        !$map.SelectedScreenBounds.Contains($map.MarkerBounds) -or $map.MarkerBounds.Height -ge $map.MarkerBounds.Width) { throw '屏幕地图未保留负坐标、竖屏或主副屏排列' }
    $editor.CancelButton.PerformClick()
    if ($appearance.StartupAnchor -ne '右下' -or $appearance.Orientation -ne '横向') { throw '取消时误应用了位置或方向' }
    if ($localChrome.AppearanceDialog -or !$editor.IsDisposed -or !$window.TopMost -or $appearance.PillMode -ne '极简模式' -or $appearance.Theme -ne '夜紫') { throw '取消后主窗或外观状态错误' }
    $menu.Items[0].PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor = $localChrome.AppearanceDialog
    $editor.Controls.Find('appearance-theme',$true)[0].SelectedItem = '云白'
    $editor.Controls.Find('appearance-mode',$true)[0].SelectedItem = '丰富模式'
    $editor.Controls.Find('appearance-page',$true)[0].SelectedItem='位置与方向'
    $editor.Controls.Find('appearance-anchors',$true)[0].SelectedItem='左边靠上'
    $editor.Controls.Find('appearance-placement',$true)[0].SelectedItem='记住上次拖动位置'
    # A regular file in the parent path makes Save fail without changing user preferences.
    $script:appearancePath = Join-Path $prefsFile 'invalid.json'
    $editor.AcceptButton.PerformClick()
    if (!$editor.Visible -or !$editor.Controls.Find('appearance-save-error',$true)[0].Visible -or $appearance.Theme -ne '夜紫') { throw '保存失败时丢失了编辑或误应用外观' }
    $script:appearancePath = $prefsFile
    $editor.AcceptButton.PerformClick()
    if ($localChrome.AppearanceDialog -or !$editor.IsDisposed -or !$window.TopMost -or $appearance.Theme -ne '云白' -or
        $localChrome.Pill.Appearance.PillMode -ne '丰富模式' -or [JieShou.HudAppearance]::Load($prefsFile).PillMode -ne '丰富模式' -or
        [JieShou.HudAppearance]::Load($prefsFile).Theme -ne '云白') { throw '保存后未恢复主窗或未应用设置' }
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    $saved=[JieShou.HudAppearance]::Load($prefsFile)
    $expected=Get-ReminderHudBounds (Get-ReminderStartupPlacement $saved) $work $window.Width $window.Height $localDpi
    if (!$localChrome.Pill.Vertical -or !$saved.RememberPosition -or $saved.StartupAnchor -ne '左上' -or $window.Bounds -ne $expected) { throw '保存后未按新位置或方向展示' }
    Test-MessageGrip $localChrome.Pill
    $saved=[JieShou.HudAppearance]::Load($prefsFile)
    $restored=Get-ReminderStartupPlacement $saved
    if (!$saved.LastDrag -or $window.Bounds -ne (Get-ReminderHudBounds $restored $work $window.Width $window.Height $localDpi)) { throw '未能从磁盘还原拖动位置' }
    $scopeBefore="$($localView.Agent)|$($localView.Days)|$($localView.Sort)"
    if ($menu.Items['orientation-横向'] -or $menu.Items['orientation-竖向']) {throw '右键菜单仍有手动转向'}
    foreach($label in '上边居中','左边靠上') {
        $dock=[JieShou.HudDock]::FromLabel($label)
        $target=[JieShou.HudGeometry]::Dock($work,[Drawing.Size]::new(1,1),$dock.Anchor,$dock.Vertical).Location
        $down=[Drawing.Point]::new(4,4)
        $origin=$dragGrip.PointToScreen($down)
        [JieShou.Tests.ScrollGesture]::DragClient($dragGrip.Handle,$down,[Drawing.Point]::new(($target.X-$origin.X),($target.Y-$origin.Y)))
        $loaded=[JieShou.HudAppearance]::Load($prefsFile)
        $restored=Get-ReminderStartupPlacement $loaded
        if($localChrome.Pill.Vertical -ne $dock.Vertical -or $restored.Vertical -ne $dock.Vertical -or $restored.Anchor -ne $dock.Anchor -or
            $window.Bounds -ne (Get-ReminderHudBounds $restored $work $window.Width $window.Height)) {throw "跨边拖动后没有恢复 $label"}
    }
    $verticalBounds=$window.Bounds
    $localChrome.Pill.PerformClick()
    Wait-HudMotion
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    if ($window.Bounds -ne $verticalBounds -or !$localChrome.Surface.IsActive -or "$($localView.Agent)|$($localView.Days)|$($localView.Sort)" -ne $scopeBefore) { throw '竖向收起后位置或筛选变化' }
    Move-ReminderHud ($work.Right-$window.Width-8) ($work.Top+12) $work
    $rightPill=$window.Bounds
    $localChrome.Pill.PerformClick()
    $canvas=$window.Bounds
    $row=$list.Controls | Where-Object { $_ -is [JieShou.LocalRow] } | Select-Object -First 1
    $rowBounds=$row.Bounds
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($localChrome.Surface.IsRevealing -and $timer.ElapsedMilliseconds -lt 1600) {
        [Windows.Forms.Application]::DoEvents()
        $clip=Get-RevealBounds
        if ($clip.Right -ne $rightPill.Right -or $clip.Top -ne $rightPill.Top -or $window.Bounds -ne $canvas -or
            $row.Bounds -ne $rowBounds) { throw '右侧竖向展开时窗口、文字或贴边位置移动' }
        Start-Sleep -Milliseconds 4
    }
    if ($window.Width -le $rightPill.Width -or $localChrome.Toggle.Glyph -ne 'Next' -or
        (Get-RevealBounds) -ne $window.Bounds -or $row.Width -gt $list.ClientSize.Width -or
        $row.Height -lt $row.ContentHeight($row.Width)) { throw '竖向展开后列表正文或右侧被裁切' }
    $textProbe=[JieShou.LocalRow]::new()
    $branchProbe=[JieShou.SideChatToggle]::new()
    try {
        $textProbe.Bind('核对会话','Codex','Codex 侧聊 · 已完成','今天 09:00','','None',$false,$null,$hudColors,$hudFonts.Name,$hudFonts.Small,$localDpi,$true,$false,'Last')
        $narrow=Get-HudPixels 180
        $baseline=$textProbe.ContentHeight($narrow)
        $textProbe.Bind('核对会话','Codex','Codex 侧聊 · 已完成 · 主会话不可用','今天 09:00','','None',$false,$null,$hudColors,$hudFonts.Name,$hudFonts.Small,$localDpi,$true,$false,'Last')
        if ($textProbe.ContentHeight($narrow) -le $baseline) { throw '较长状态行缺少换行空间' }
        $textProbe.Bind(('核对任务记录 AMC_Session_2026_' * 8),'Codex','Codex 侧聊 · 已完成','今天 09:00','','None',$false,$null,$hudColors,$hudFonts.Name,$hudFonts.Small,$localDpi,$true,$false,'Last')
        if ($textProbe.ContentHeight($narrow) -le $textProbe.ContentHeight($row.Width)) { throw '中英文长标题忽略了可用宽度' }
        $branchProbe.Bind(30,10,10,10,$true,$hudColors,$hudFonts.Small,$localDpi)
        if ($branchProbe.ContentHeight($narrow) -le $branchProbe.ContentHeight((Get-HudPixels 448))) { throw '侧聊摘要未按宽度换行' }
    } finally { $textProbe.Dispose(); $branchProbe.Dispose() }
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    if ($window.Bounds -ne $rightPill) { throw '右侧竖向胶囊未沿原路收起' }
    $localChrome.Pill.PerformClick()
    $localChrome.Surface.FinishReveal()
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor = $localChrome.AppearanceDialog
    $editor.Close()
    if ($localChrome.AppearanceDialog -or !$window.TopMost -or !$window.Enabled) { throw '关闭设置后主窗没有恢复' }
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor=$localChrome.AppearanceDialog
    $editor.Controls.Find('appearance-page',$true)[0].SelectedItem='位置与方向'
    $slots=$editor.Controls.Find('appearance-anchors',$true)[0]
    $editor.Controls.Find('appearance-placement',$true)[0].SelectedItem='固定位置'
    $slots.SelectedItem='右边居中'
    $editor.Controls.Find('appearance-autohide',$true)[0].SelectedItem='开启'
    $editor.Controls.Find('appearance-page',$true)[0].SelectedItem='胶囊外观'
    $sample=$editor.Controls.Find('appearance-preview',$true)[0]
    if ($sample.OpensForward -or !$sample.EdgeTab -or $sample.EdgePeek -or $sample.ReminderCount -ne 2) { throw '开启自动隐藏后外观预览应显示右侧双提醒短签' }
    $editor.AcceptButton.PerformClick()
    if (!([JieShou.HudAppearance]::Load($prefsFile).AutoHide)) { throw '自动隐藏设置未保存' }
    $shortcut=$menu.Items['toggle-autohide']
    $shortcut.PerformClick()
    if ($shortcut.Checked -or $appearance.AutoHide -or [JieShou.HudAppearance]::Load($prefsFile).AutoHide) { throw '右键关闭自动隐藏没有生效' }
    $shortcut.PerformClick()
    if (!$shortcut.Checked -or !$appearance.AutoHide -or ![JieShou.HudAppearance]::Load($prefsFile).AutoHide) { throw '右键开启自动隐藏没有生效' }
    $savedRows=$localView.Rows; $savedAgent=$localView.Agent; $savedNext=$localView.NextRead
    $localView.NextRead=[datetime]::UtcNow.AddMinutes(2)
    $localView.Agent='所有 Agent'
    $stamp=[datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()
    $run=@{agent='Codex'; id=[guid]::NewGuid().ToString(); turn='inProgress'; name='运行'; activity=$stamp}
    $wait=@{agent='Codex'; id=[guid]::NewGuid().ToString(); turn='completed'; name='待输入'; activity=$stamp; needsInput=1; finished=$stamp; unread=1}
    $unseen=@{agent='Qoder'; id='fixture-unread'; turn='completed'; name='未读'; activity=$stamp; unread=1; finished=$stamp}
    $localView.Rows=@($run)
    Update-ReminderWindow
    $localChrome.Toggle.PerformClick()
    Wait-HudMotion
    $away=[Drawing.Point]::new($work.Left,$work.Top)
    $localChrome.HoverUntil=0
    Update-LocalDockHover $away 10000
    $pill=$localChrome.Pill
    if (!$pill.EdgeTab -or $pill.ReminderCount -ne 0 -or $pill.OpensForward -or $window.Right -ne $work.Right -or
        $window.Width -ne (Get-HudPixels 5) -or $window.Height -ne (Get-HudPixels 40) -or $dragGrip.Visible) { throw "无提醒时未显示右侧墨尺细线：$($window.Bounds)" }
    $rail=$window.Bounds
    $oldUnread=$unseen.Clone();$oldUnread.id='older-completion';$oldUnread.finished=$stamp-90000000L
    $localView.Rows=@($run,$wait,$unseen,$oldUnread)
    Update-ReminderWindow
    if (!$pill.EdgeTab -or $pill.ReminderCount -ne 2 -or $window.Width -le $rail.Width -or $pill.AccessibleName -notmatch '2 条提醒') { throw '新消息未显示准确的提醒数量' }
    $localView.Agent='Codex'; Update-ReminderWindow
    if ($pill.ReminderCount -ne 1) { throw '提醒角标没有跟随 Agent 筛选' }
    $localView.Agent='所有 Agent'; Update-ReminderWindow
    $inputTab=$pill.Controls['edge-input'];$unreadTab=$pill.Controls['edge-unread']
    $at=[Drawing.Point]::new(($work.Right-2),($window.Top+[int]($inputTab.Height/2)))
    $compactBounds=$window.Bounds
    $wasPolling=$localTimer.Enabled
    try {
        $localTimer.Stop()
        Update-LocalDockHover $at 11000
        $settle=[Diagnostics.Stopwatch]::StartNew()
        while($settle.ElapsedMilliseconds -lt 200) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 5 }
        if (!$pill.EdgeTab -or !$pill.EdgePeek -or !$dragGrip.Visible -or $window.Right -ne $compactBounds.Right -or
            [Math]::Abs(($window.Top+$window.Height/2)-($compactBounds.Top+$compactBounds.Height/2)) -gt 1 -or $window.Width -le $compactBounds.Width -or
            $pill.GetChildAtPoint([Drawing.Point]::new(($inputTab.Right-2),($inputTab.Top+[int]($inputTab.Height/2)))) -ne $inputTab -or
            $pill.GetChildAtPoint([Drawing.Point]::new(($unreadTab.Right-2),($unreadTab.Top+[int]($unreadTab.Height/2)))) -ne $unreadTab) {
            throw '墨尺悬停未在原边缘展开数字栏，或握把、状态行未正确命中'
        }
    } finally { if($wasPolling){$localTimer.Start()} }
    Update-LocalDockHover $away 11100
    if (!$pill.EdgePeek) { throw '移出后立即收起，缺少悬停缓冲' }
    Update-LocalDockHover $away 12000
    if ($pill.EdgePeek) { throw '悬停结束未收回墨尺' }
    $localView.Agent='所有 Agent'; Update-ReminderWindow
    foreach($axis in '横向','竖向') {
        $probe=[JieShou.MetricPill]::new()
        try {
            $probe.Appearance=$appearance.Copy();$probe.Vertical=$axis -eq '竖向'
            $probe.Colors=$hudColors;$probe.EdgeTab=$true
            $buttons=@(foreach($index in 0,1,2) { $probe.AddEdgeButton($index) })
            foreach($counts in @(@(0,1),@(2,0),@(12,26))) {
                $probe.Breakdown=@([JieShou.PillTally]::new(),[JieShou.PillTally]::new())
                for ($i=0;$i -lt 2;$i++) {
                    for ($j=0;$j -lt $counts[$i];$j++) { $probe.Breakdown[$i].Add('Codex') }
                }
                foreach ($edge in $false,$true) {
                    $probe.OpensForward=$edge
                    $probe.Size=$probe.MeasureForArea($work.Size)
                    $probe.ArrangeEdgeButtons()
                    $frame=$probe.RenderFrame()
                    try {
                        if($axis -eq '竖向') { $x=if($edge){0}else{$frame.Width-1};$corner=$frame.GetPixel($x,0);$outer=$frame.GetPixel($frame.Width-1-$x,0) }
                        else { $y=if($edge){0}else{$frame.Height-1};$corner=$frame.GetPixel(0,$y);$outer=$frame.GetPixel(0,$frame.Height-1-$y) }
                        if ($corner.A -ne 255 -or $outer.A -gt 10 -or $buttons[2].Visible) {throw "短签边缘或提醒类型错误 $axis $edge"}
                        $visibleArea=0
                        for($i=0;$i -lt 2;$i++) {
                            $button=$buttons[$i]
                            if ($button.Visible -ne ($counts[$i] -gt 0)) {throw '数量为零的短签仍然占位，或有效提醒丢失'}
                            if (!$button.Visible) {continue}
                            $box=$button.Bounds
                            $visibleArea+=$box.Width*$box.Height
                            $color=if($i -eq 0) {$hudColors.InputInk} else {$hudColors.Unread}
                            if ($button.AccessibleName -ne "$($button.Tag) $($counts[$i]) 个会话" -or
                                $frame.GetPixel(($box.Left+4),[int]($box.Top+$box.Height/2)).ToArgb() -ne $color.ToArgb()) {throw '短签的标签、数量或类别色错误'}
                        }
                        if ($visibleArea -ne $frame.Width*$frame.Height) {throw '短签仍有空白占位'}
                        if ($counts[0] -and $counts[1]) {
                            if ($probe.Vertical -and $buttons[0].Bottom -ne $buttons[1].Top) {throw '竖向短签未将待输入放在上行'}
                            if (!$probe.Vertical -and $buttons[0].Right -ne $buttons[1].Left) {throw '横向短签未将待输入放在左侧'}
                        }
                    } finally {$frame.Dispose()}
                }
            }
        } finally {$probe.Dispose()}
    }
    foreach ($name in 'edge-completed','edge-total') {
        $localChrome.DockHover=$true;Update-ReminderWindow
        $button=$pill.Controls[$name]
        $hit=[Drawing.Point]::new(($button.Left+$button.Width/2),($button.Top+$button.Height/2))
        if (!$button.Visible -or $pill.GetChildAtPoint($hit) -ne $button) { throw "悬停数字栏的统计项没有命中 $name" }
        $button.PerformClick();$localChrome.Surface.FinishReveal()
        if (!$expanded -or ($name -eq 'edge-total' -and ($localView.Attention -or $list.Controls.Count -ne 4)) -or
            ($name -eq 'edge-completed' -and ($localView.Attention -ne '已完成' -or $list.Controls.Count -ne 2 -or
             $list.Controls.Tag -notcontains $unseen.id -or $list.Controls.Tag -notcontains $oldUnread.id))) {
            throw "悬停数字栏统计与对应清单不一致 $name"
        }
        $localChrome.Toggle.PerformClick();$localChrome.Surface.FinishReveal()
    }
    $inputTab.PerformClick();$localChrome.Surface.FinishReveal()
    if (!$expanded -or $localView.Attention -ne '待输入' -or @($list.Controls | Where-Object { $_ -is [JieShou.LocalRow] }).Count -ne 1 -or
        $list.Controls[0].Tag -ne $wait.id -or $pill.ReminderCount -ne 2) {throw '待输入短签没有打开匹配列表，或提前消费了提醒'}
    $wait.needsInput=0;$wait.turn='inProgress';Update-ReminderWindow
    if ($pill.ReminderCount -ne 1 -or $localChrome.EmptyHint.Text -ne '已处理完' -or
        !$localChrome.ReminderFilters[0].Enabled -or !$localChrome.ReminderFilters[0].Selected) {throw '清零后未保留所选分类或缺少已处理完提示'}
    $localChrome.ReminderFilters[1].PerformClick()
    if (!$localChrome.ReminderFilters[1].Selected -or $localChrome.ReminderFilters[0].Enabled -or $localChrome.ReminderFilters[0].Text -ne '待输入 0' -or
        $list.Controls.Count -ne 1 -or $list.Controls[0].Tag -ne $unseen.id) {throw '展开后不能直接切换另一枚短签'}
    $localChrome.ReminderFilters[0].PerformClick()
    if ($localView.Attention -ne '完成未读') { throw '数量为零的分类仍可点击' }
    $wait.needsInput=1;Update-ReminderWindow
    if (!$localChrome.ReminderFilters[0].Enabled) { throw '新的待输入会话没有恢复分类入口' }
    $wait.needsInput=0;Update-ReminderWindow
    $localChrome.AllSessions.PerformClick()
    if ($localView.Attention -or $localChrome.Section.Text -ne '4 个会话') {throw '无法从提醒列表返回全部会话'}
    $localChrome.Toggle.PerformClick(); $localChrome.Surface.FinishReveal()
    $unreadTab.PerformClick();$localChrome.Surface.FinishReveal()
    if ($localView.Attention -ne '完成未读' -or $list.Controls.Count -ne 1 -or $list.Controls[0].Tag -ne $unseen.id) {throw '完成未读短签没有遵循 24 小时提醒范围'}
    $unseen.unread=0;Update-ReminderWindow
    if (!$expanded -or !$list.Visible -or $pill.ReminderCount -ne 0) { throw '已读回执未清零或干扰了展开列表' }
    Send-TestOutsidePress ([JieShou.Tests.ScrollGesture]::GetDesktopWindow()); Wait-HudMotion
    if ($expanded -or !$pill.EdgeTab -or $pill.EdgePeek) { throw '自动隐藏开启时外部点击没有直接收回墨尺' }
    $localChrome.HoverUntil=0; Update-LocalDockHover $away 13000
    if ($window.Bounds -ne $rail) { throw '提醒清零后没有回到原贴边位置' }
    # Check the column's Chinese labels at the target DPI and the rich-only source row.
    $edgeProbe=[JieShou.MetricPill]::new()
    try {
        $edgeProbe.Appearance=$appearance.Copy();$edgeProbe.Vertical=$true
        $edgeProbe.EdgeTab=$edgeProbe.EdgePeek=$true
        $edgeProbe.Colors=$hudColors; $edgeProbe.AgentIcons=$agentIcons
        $edgeProbe.Values=[string[]]@('1','1','2','30','27')
        $edgeProbe.Breakdown=@(0..2 | ForEach-Object {[JieShou.PillTally]::new()})
        $edgeProbe.Breakdown[0].Add('Codex');$edgeProbe.Breakdown[1].Add('Qoder')
        $edgeProbe.Breakdown[2].Add('Codex');$edgeProbe.Breakdown[2].Add('DSH')
        $buttons=@(foreach($index in 0..4) { $edgeProbe.AddEdgeButton($index) })
        $edgeProbe.Vertical=$false
        foreach ($mode in '极简模式','丰富模式') {
            $edgeProbe.Appearance.PillMode=$mode
            foreach ($width in 420,1920) {
                $area=[Drawing.Size]::new($width,1080)
                $edgeProbe.EdgeTab=$false
                $edgeProbe.Size=$edgeProbe.MeasureForArea($area);$edgeProbe.ArrangeEdgeButtons()
                $normal=$edgeProbe.RenderFrame()
                $regions=$edgeProbe.GetType().GetField('statusBounds',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($edgeProbe).Clone()
                $edgeProbe.EdgeTab=$true
                $edgeProbe.Size=$edgeProbe.MeasureForArea($area);$edgeProbe.ArrangeEdgeButtons()
                $peek=$edgeProbe.RenderFrame()
                try {
                    if ($peek.Size -ne $normal.Size -or $peek.Width -le $peek.Height) {throw "横向悬停后丢失横向胶囊尺寸：$mode / $width"}
                    if ((Get-BitmapHash $peek) -ne (Get-BitmapHash $normal)) {throw '横向悬停与常驻胶囊像素不一致'}
                    for ($i=0;$i -lt $buttons.Count;$i++) {
                        if (!$buttons[$i].Visible -or $buttons[$i].Bounds -ne $regions[$i]) {throw "横向悬停点击区域错误：$($buttons[$i].Tag)"}
                    }
                } finally { $normal.Dispose();$peek.Dispose() }
            }
        }
        $edgeProbe.Vertical=$true
        $edgeProbe.Appearance.PillMode='极简模式'
        foreach ($scale in 96,144,192,288) {
            $edgeProbe.LayoutDpi=$scale
            $edgeProbe.Size=$edgeProbe.MeasureForArea($work.Size);$edgeProbe.ArrangeEdgeButtons()
            $frame=$edgeProbe.RenderFrame()
            try {
                foreach($btn in $buttons[0..1]) {
                    $minX=$btn.Right; $maxX=-1; $minY=$btn.Bottom; $maxY=-1; $smoothed=$false
                    for ($y=$btn.Top+1;$y -lt $btn.Bottom-2;$y++) {
                        for ($x=$btn.Left+[int](32*$scale/96);$x -lt $btn.Right;$x++) {
                            $color=$frame.GetPixel($x,$y)
                            if ($color.A -ne 255 -or $color.R -lt 120) {continue}
                            $minX=[Math]::Min($minX,$x); $maxX=[Math]::Max($maxX,$x)
                            $minY=[Math]::Min($minY,$y); $maxY=[Math]::Max($maxY,$y)
                            if ($color.R -lt 215) {$smoothed=$true}
                        }
                    }
                    $em=$appearance.Size*$scale/96.0
                    if (!$smoothed -or $maxX-$minX+1 -lt ($btn.Tag.Length-.35)*$em -or $maxY-$minY+1 -lt .68*$em) {
                        throw "隐藏短签文字缺字、字号过小或缺少抗锯齿：$($btn.Tag) $scale DPI"
                    }
                }
            } finally {$frame.Dispose()}
            $simple=$edgeProbe.Size
            $edgeProbe.Appearance.PillMode='丰富模式'
            $edgeProbe.Size=$edgeProbe.MeasureForArea($work.Size); $edgeProbe.ArrangeEdgeButtons()
            if ($edgeProbe.Height -le $simple.Height -or !$edgeProbe.ClientRectangle.Contains($buttons[2].Bounds) -or
                $edgeProbe.Caption($true) -notmatch '进行中 2（Codex 1、DSH 1）') {throw '墨尺悬停的丰富模式缺少来源或运行状态'}
            $edgeProbe.Appearance.PillMode='极简模式'
        }
    } finally {$edgeProbe.Dispose()}
    $pill.PerformClick()
    $settle=[Diagnostics.Stopwatch]::StartNew()
    while($settle.ElapsedMilliseconds -lt 220) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 5 }
    if(!$pill.EdgePeek -or $expanded -or !$dragGrip.Visible -or !$pill.Controls['edge-running'].Visible) {throw '空闲墨尺不能唤出有运行入口的数字栏'}
    $pill.Controls['edge-running'].PerformClick();$localChrome.Surface.FinishReveal()
    if ($localView.Attention -cne '进行中' -or $list.Controls.Count -ne 2 -or $pill.ReminderCount -ne 0) { throw '提醒清零后无法从短签查看进行中会话' }
    $priorSources=$localView.Sources
    $localView.Sources=@{Codex='ready';Qoder='ready';DSH='ready'}
    $extra=@(foreach ($i in 1..14) { @{agent='DSH';id="running-$i";name="并行会话 $i";activity=$stamp;turn='inProgress'} })
    $child=@{agent='Codex';id='running-child';parentId=$run.id;rootId=$run.id;activity=$stamp;turn='inProgress'}
    $localView.Rows+=$extra+@($child)
    Update-ReminderWindow
    if ($localChrome.Section.Text -ne '17 个会话' -or $list.Controls.Count -ne 17 -or $localChrome.Next.Visible -or
        $list.Controls.Tag -notcontains $child.id -or $list.Controls.Tag -notcontains 'running-14' -or !$list.VerticalScroll.Visible) {throw '完整进行中列表截断了跨页会话或侧聊'}
    $localChrome.Agents[2].PerformClick()
    $extra[0].turn='completed'; Update-ReminderWindow
    if ($list.Controls.Count -ne 13 -or $localChrome.ReminderFilters[2].Text -ne '进行中 13' -or $list.Controls.Tag -contains 'running-1') {throw '进行中列表没有随 Agent 或最新状态刷新'}
    $list.AutoScrollPosition=[Drawing.Point]::new(0,60)
    $offset=$list.AutoScrollPosition.Y
    $firstRow=$list.Controls[0]
    $down=[Drawing.Point]::new(5,5)
    $origin=$header.PointToScreen($down)
    $target=[Drawing.Point]::new(($work.Left+[int]($work.Width/2)),($work.Bottom-1))
    [JieShou.Tests.ScrollGesture]::DragClient($header.Handle,$down,[Drawing.Point]::new(($target.X-$origin.X),($target.Y-$origin.Y)))
    if (!$expanded -or $pill.Vertical -or $window.Bottom -ne $work.Bottom -or $localView.Attention -ne '进行中' -or
        $localView.Agent -ne 'DSH' -or $offset -ge 0 -or $list.AutoScrollPosition.Y -ne $offset -or $list.Controls[0] -ne $firstRow) {throw '展开列表跨边拖动时丢失筛选、滚动位置或行控件'}
    $localChrome.Toggle.PerformClick(); Wait-HudMotion
    if (!$pill.EdgeTab -or $pill.Vertical -or $window.Bottom -ne $work.Bottom) {throw '列表跨边后未收回底边墨尺'}
    $edgePoint=[Drawing.Point]::new(($window.Left+[int]($window.Width/2)),($window.Bottom-1))
    foreach ($alert in $false,$true) {
        if ($alert) { $extra[1].needsInput=1 }
        Update-ReminderWindow
        $hiddenBounds=$window.Bounds
        $pill.EdgeTab=$false
        $openSize=$pill.MeasureForArea($work.Size)
        $pill.EdgeTab=$true
        Update-LocalDockHover $edgePoint 30000
        if (!$pill.EdgePeek -or $pill.Vertical -or $window.Size -ne $openSize -or !$dragGrip.Visible -or
            !$pill.Controls['edge-running'].Visible) {throw "横向唤回首帧仍有中间状态，提醒=$alert"}
        $hoverFrame=$pill.RenderFrame()
        $pill.EdgeTab=$false
        $regularFrame=$pill.RenderFrame()
        try {
            if ((Get-BitmapHash $regularFrame) -ne (Get-BitmapHash $hoverFrame)) {throw '横向唤回首帧与常驻胶囊像素不一致'}
        } finally { $regularFrame.Dispose(); $hoverFrame.Dispose(); $pill.EdgeTab=$true }
        Update-LocalDockHover $away 30150
        if (!$pill.EdgePeek) {throw '横向悬停缓冲未保留'}
        Update-LocalDockHover $away 31000
        if ($pill.EdgePeek -or $window.Bounds -ne $hiddenBounds -or $dragGrip.Visible -or $pill.Controls['edge-running'].Visible) {
            throw "横向收回首帧没有直接显示墨尺，提醒=$alert"
        }
    }
    $localView.Rows=$savedRows; $localView.Agent=$savedAgent; $localView.NextRead=$savedNext; $localView.Sources=$priorSources
} finally {
    $script:appearancePath = $previousPath
    if ($editor -and !$editor.IsDisposed) { $editor.Close() }
    if ([IO.File]::Exists($prefsFile)) { [IO.File]::Delete($prefsFile) }
}
$localView.Status = 'Unavailable'
if (Get-LocalCodexUri $localView.Rows[0].id) { throw '失联时保留了会话跳转' }
'本地 Codex 浮窗回归通过。'
