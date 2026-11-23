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
Add-Type -Path "$PSScriptRoot/Test-HudScrollBar.cs"
$work = [Windows.Forms.Screen]::FromControl($window).WorkingArea
Move-ReminderHud ($work.Left+40) ($work.Top+40) $work
function Test-MessageGrip($expectedHost) {
    $anchor=$window.Location
    $wasExpanded=$expanded
    $pt=[Drawing.Point]::new([int]($dragGrip.Width/2),[int]($dragGrip.Height/2))
    if ($expectedHost.GetChildAtPoint($pt) -ne $dragGrip -or !$dragGrip.Visible -or $dragGrip.AccessibleRole -ne 'Grip') { throw '消息握把未覆盖图标区域' }
    [JieShou.Tests.ScrollGesture]::DragClient($dragGrip.Handle,$pt,[Drawing.Point]::Empty)
    if ($expanded -ne $wasExpanded -or $anchor -ne $window.Location) { throw '单击消息握把误切换视图或移动浮窗' }
    [JieShou.Tests.ScrollGesture]::DragClient($dragGrip.Handle,$pt,[Drawing.Point]::new(24,16))
    if ($expanded -ne $wasExpanded -or $window.Left -ne $anchor.X+24 -or $window.Top -ne $anchor.Y+16 -or $dragGrip.Capture) { throw '消息握把拖动或释放失败' }
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
function Wait-HudMotion {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1600) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 3
    }
    if ($localChrome.Surface.IsRevealing) { throw '浮窗动画未能结束' }
}
$localChrome.Pill.PerformClick()
if ([JieShou.SessionActivityAnimation]::MotionAllowed) {
    if (!$localChrome.Surface.IsRevealing) { throw '点击胶囊没有开始展开' }
    $heights=[Collections.Generic.List[int]]::new()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $refreshed=$false
    while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1500) {
        [Windows.Forms.Application]::DoEvents()
        if ($window.Top -ne $capsuleBounds.Top) { throw '展开时标题栏离开了胶囊上边缘' }
        if (!$heights.Contains($window.Height)) { $heights.Add($window.Height) }
        if (!$refreshed -and $heights.Count -ge 2) { Update-ReminderWindow; $refreshed=$true }
        Start-Sleep -Milliseconds 4
    }
    if ($localChrome.Surface.IsRevealing -or $heights.Count -lt 3 -or $heights[0] -ge $window.Height) { throw '展开跳过了中间帧或未能结束' }
    for ($i=1;$i -lt $heights.Count;$i++) { if ($heights[$i] -le $heights[$i-1]) { throw '刷新后展开高度倒退' } }
    $end=$window.Bounds
    Update-ReminderWindow
    if ($window.Bounds -ne $end -or $localChrome.Surface.IsRevealing) { throw '普通刷新重新播放了展开动画' }
} elseif ($localChrome.Surface.IsRevealing) { throw '系统关闭动画时仍然播放展开' }
$panelBounds=$window.Bounds
$header.PerformClick()
if ([JieShou.SessionActivityAnimation]::MotionAllowed) {
    if (!$localChrome.Surface.IsRollingUp -or !$list.Visible) { throw '点击收起没有保留列表开始上卷' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($window.Height -gt ($panelBounds.Height+$capsuleBounds.Height)/2 -and $watch.ElapsedMilliseconds -lt 1200) {
        [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 3
    }
    $middle=$window.Bounds
    if (!$localChrome.Surface.IsRollingUp -or $middle.Height -le $capsuleBounds.Height) { throw '上卷没有经过中间高度' }
    Update-ReminderWindow
    if ($window.Bounds -ne $middle) { throw '刷新打断了上卷' }
    $header.PerformClick()
    if ($localChrome.Surface.IsRollingUp -or $window.Bounds -ne $middle) { throw '上卷中重新展开时窗口跳位' }
    Wait-HudMotion
    if ($window.Bounds -ne $panelBounds -or !$list.Visible) { throw '反向展开后列表未恢复' }
    $header.PerformClick()
}
Wait-HudMotion
if (!$localChrome.Surface.IsActive -or $window.Bounds -ne $capsuleBounds -or $list.Visible) { throw '上卷结束后胶囊位置或交互错误' }
Move-ReminderHud ($work.Right-$window.Width-8) ($work.Bottom-$window.Height-12) $work
$edgeBounds=$window.Bounds
$localChrome.Pill.PerformClick()
$watch=[Diagnostics.Stopwatch]::StartNew()
while ($localChrome.Surface.IsRevealing -and $watch.ElapsedMilliseconds -lt 1500) {
    [Windows.Forms.Application]::DoEvents()
    if (!$work.Contains($window.Bounds)) { throw '贴边展开超出了工作区' }
    Start-Sleep -Milliseconds 4
}
if ($window.Top -ge $edgeBounds.Top -or $window.Right -ne $edgeBounds.Right -or !$work.Contains($window.Bounds)) { throw '屏幕底部展开方向或水平锚点错误' }
$header.PerformClick()
while ($localChrome.Surface.IsRollingUp -and $watch.ElapsedMilliseconds -lt 2000) {
    [Windows.Forms.Application]::DoEvents()
    if (!$work.Contains($window.Bounds)) { throw '贴边上卷超出了工作区' }
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
        $groupButton.Name -cne "sidechats-$mainId" -or $groupButton.AccessibleName -notmatch '展开侧聊 3.*1 待输入.*1 完成未读.*1 进行中' -or
        $list.Controls.Count -ne 3 -or $localChrome.Section.Text -ne '4 个会话' -or
        ($localChrome.Pill.Values -join ',') -ne '1,1,1,4,2') { throw '收起的主侧聊分组遗漏提醒、顺序或重复计数' }
    $groupButton.PerformClick()
    if ($list.Controls.Count -ne 6 -or $list.Controls[2].Tag -cne $sideB -or
        $list.Controls[2].Detail -notmatch '侧聊' -or $list.Controls[2].Indicator -ne 'CompletedUnread' -or
        $groupButton.AccessibleName -notmatch '^收起') { throw '侧聊展开或置顶错误' }
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
function Get-RowFrame($row) {
    $bitmap = [Drawing.Bitmap]::new($row.Width,$row.Height)
    $stream = [IO.MemoryStream]::new()
    try {
        $row.DrawToBitmap($bitmap,$row.ClientRectangle)
        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray()))
    } finally { $bitmap.Dispose(); $stream.Dispose() }
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
$localView.QoderWaiting = @($shared)
$nativeWaiting = Get-LocalAttention $focused $requests $when
if ($nativeWaiting.Breakdown[0].ByAgent['Qoder'] -ne 1 -or $nativeWaiting.Breakdown[1].Total -ne 0 -or
    ($nativeWaiting.Values -join ',') -ne '3,,1,7,3') { throw 'Qoder 实时待输入应优先于磁盘上的完成状态' }
$localView.QoderWaiting = @()
$before = $localView.Rows
try {
    $localView.Rows = @($focused | ForEach-Object { $_.activity=$clock; $_.created=$clock; $_.message=$clock; $_ })
    Update-ReminderWindow
    if ($localChrome.Pill.Caption() -ne '待输入 1 · 完成未读 1 · 进行中 2 · 任务 7 · 已完成 4' -or
        $list.Controls.Find("local-Qoder-$shared",$true)[0].Detail -notlike '*完成未读' -or
        $list.Controls.Find('local-DSH-d',$true)[0].Detail -notlike '*待输入') { throw '胶囊与展开列表的提醒不一致' }
    $pill = $localChrome.Pill
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
[JieShou.Tests.ScrollGesture]::DragToEnd($list.Handle,$false)
$endOffset = -$list.AutoScrollPosition.Y
if ($endOffset -le 0 -or $endOffset -ne $list.VerticalScroll.Maximum-$list.VerticalScroll.LargeChange+1) { throw '会话滑块未到达列表底部' }
Update-ReminderWindow
$localChrome.Agents[0].PerformClick()
if (-$list.AutoScrollPosition.Y -ne $endOffset) { throw '会话刷新丢失了滚动位置' }
if (!$localScrollBar.ScrollKey('Home') -or $list.AutoScrollPosition.Y -ne 0 -or !$localScrollBar.ScrollKey('PageDown') -or
    $list.AutoScrollPosition.Y -ge 0) { throw '会话列表键盘滚动失败' }
if ($localChrome.Next.Bottom -gt $list.Top -or $window.ClientSize.Height-$list.Bottom -gt (Get-HudPixels 6)) {
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
    if (!$editor.Visible -or $editor.Modal -or !$window.Enabled -or !$editor.TopMost -or $window.TopMost) { throw '设置遮挡主窗或阻断主窗操作' }
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
    $minimalFrame = Get-RowFrame $sample
    $modes.Controls.Find('丰富模式',$false)[0].PerformClick()
    if ($sample.AccessibleName -notmatch '进行中 3（Codex 2、DSH 1）' -or (Get-RowFrame $sample) -eq $minimalFrame -or
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
        [JieShou.Tests.ScrollGesture]::DragToEnd($choice.Options.Handle,$false)
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
    if ($legacy.PillMode -ne '极简模式' -or $legacy.Theme -ne '云白') { throw '旧版设置迁移错误' }
    $selected = $editor.Selection.Copy()
    $selected.Accent = '#730DA1'
    $selected.Save($prefsFile)
    $readBack = [JieShou.HudAppearance]::Load($prefsFile)
    if ($readBack.PillMode -ne '丰富模式' -or $readBack.Accent -cne '#730DA1' -or $readBack.Theme -ne '云白' -or $readBack.Opacity -ne 75 -or
        $readBack.Shape -ne '直角' -or $readBack.Family -ne $selected.Family -or $readBack.Size -ne 20) { throw '外观设置未正确保存' }
    $editor.Controls.Find('appearance-reset',$true)[0].PerformClick()
    if ($editor.Selection.PillMode -ne '极简模式' -or $editor.Selection.Shape -ne '胶囊' -or $editor.Selection.Opacity -ne 100 -or $editor.Selection.Size -ne 15) { throw '恢复默认失败' }
    if ($appearance.Shape -ne '胶囊' -or $appearance.Theme -ne '夜紫') { throw '预览更改了已应用的外观' }
    $editor.Controls.Find('appearance-theme',$true)[0].SelectedItem = '深海'
    $modes.SelectedItem = '丰富模式'
    $editor.CancelButton.PerformClick()
    if ($localChrome.AppearanceDialog -or !$editor.IsDisposed -or !$window.TopMost -or $appearance.PillMode -ne '极简模式' -or $appearance.Theme -ne '夜紫') { throw '取消后主窗或外观状态错误' }
    $menu.Items[0].PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor = $localChrome.AppearanceDialog
    $editor.Controls.Find('appearance-theme',$true)[0].SelectedItem = '云白'
    $editor.Controls.Find('appearance-mode',$true)[0].SelectedItem = '丰富模式'
    # A regular file in the parent path makes Save fail without changing user preferences.
    $script:appearancePath = Join-Path $prefsFile 'invalid.json'
    $editor.AcceptButton.PerformClick()
    if (!$editor.Visible -or !$editor.Controls.Find('appearance-save-error',$true)[0].Visible -or $appearance.Theme -ne '夜紫') { throw '保存失败时丢失了编辑或误应用外观' }
    $script:appearancePath = $prefsFile
    $editor.AcceptButton.PerformClick()
    if ($localChrome.AppearanceDialog -or !$editor.IsDisposed -or !$window.TopMost -or $appearance.Theme -ne '云白' -or
        $localChrome.Pill.Appearance.PillMode -ne '丰富模式' -or [JieShou.HudAppearance]::Load($prefsFile).PillMode -ne '丰富模式' -or
        [JieShou.HudAppearance]::Load($prefsFile).Theme -ne '云白') { throw '保存后未恢复主窗或未应用设置' }
    $localChrome.Settings.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    $editor = $localChrome.AppearanceDialog
    $editor.Close()
    if ($localChrome.AppearanceDialog -or !$window.TopMost -or !$window.Enabled) { throw '关闭设置后主窗没有恢复' }
} finally {
    $script:appearancePath = $previousPath
    if ($editor -and !$editor.IsDisposed) { $editor.Close() }
    if ([IO.File]::Exists($prefsFile)) { [IO.File]::Delete($prefsFile) }
}
$localView.Status = 'Unavailable'
if (Get-LocalCodexUri $localView.Rows[0].id) { throw '失联时保留了会话跳转' }
'本地 Codex 浮窗回归通过。'
