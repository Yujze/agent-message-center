param([switch]$UiTest, [string]$CodexDesktopSnapshot, [switch]$CodexDemo,
    [switch]$CodexLocal, [string]$CodexProject)

$ErrorActionPreference = 'Stop'
if (![OperatingSystem]::IsWindows() -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw '请用 Windows PowerShell 7 启动：pwsh -STA -NoProfile -File .\Start-Reminder.ps1'
}
. "$PSScriptRoot/Reminder.State.ps1"
. "$PSScriptRoot/Reminder.CodexDesktop.ps1"
. "$PSScriptRoot/Reminder.Layout.ps1"
if ($CodexProject) { $CodexLocal = $true }
if ($CodexLocal -and $CodexDemo) { throw '本地模式与模拟演示不能同时启用。' }
if ($CodexLocal) {
    . "$PSScriptRoot/Reminder.CodexLocal.ps1"
    . "$PSScriptRoot/Reminder.LocalView.ps1"
    . "$PSScriptRoot/Reminder.SessionList.ps1"
}
if (($UiTest -or $CodexDemo) -and $CodexDesktopSnapshot) { throw '自动界面测试不接入外部状态文件。' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if ($CodexLocal) {
    [void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
}
[Windows.Forms.Application]::EnableVisualStyles()
if ($CodexLocal) {
    # pwsh may already have selected system DPI for the process. Set the STA that
    # owns the HUD as well, before WinForms creates any window handles.
    Add-Type -Namespace JieShou -Name LocalWindowDpi -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(System.IntPtr window);
'@
    [void][JieShou.LocalWindowDpi]::SetThreadDpiAwarenessContext([IntPtr](-4))
}

$state = New-ReminderState
$expanded = $false
$demoLoaded = $false
$codexFeed = New-CodexDesktopFeed
$codexTimer = $null
$localTimer = $null
$localView = @{ Page=0; Agent='所有 Agent'; Days=7; Sort='message'; NextExpiry=[datetime]::MaxValue; Sources=@{}; Status='Loading'; Rows=@(); LastJson=''; Reader=$null; NextRead=[datetime]::MinValue }
$tray = $null
$trayIcon = $null
$trayMenu = $null
$placement = New-ReminderHudPlacement
$drag = @{ Active=$false; X=0; Y=0 }
$ink = [Drawing.Color]::FromArgb(30, 42, 52)
$accent = [Drawing.Color]::FromArgb(19, 100, 98)
$surface = [Drawing.Color]::FromArgb(243, 247, 248)

$window = New-ReminderHudForm
$window.Text = '智能体消息中心（模拟）'
$window.FormBorderStyle = 'None'
$window.StartPosition = 'Manual'
$window.ShowInTaskbar = $false
$window.TopMost = $true
$window.BackColor = $surface
$window.ForeColor = $ink
$window.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
$window.AccessibleName = '智能体消息中心 模拟浮窗'

$header = [Windows.Forms.Button]::new()
$header.FlatStyle = 'Flat'
$header.FlatAppearance.BorderSize = 0
$header.BackColor = $accent
$header.ForeColor = [Drawing.Color]::White
$header.SetBounds(0, 0, 210, 46)
$header.Add_Click({
    $script:expanded = !$expanded
    if ($CodexLocal -and !$expanded -and (Start-LocalRollUp)) { return }
    Update-ReminderWindow
})
$window.Controls.Add($header)

function Move-ReminderHud([int]$X, [int]$Y, [Drawing.Rectangle]$WorkArea) {
    if ($CodexLocal -and $localChrome.Surface) { $localChrome.Surface.FinishReveal(); $localChrome.ExpansionTop=$null }
    $moved = [Drawing.Rectangle]::new($X, $Y, $window.Width, $window.Height)
    Set-ReminderHudPlacement $placement $moved $WorkArea
    $bounds = Get-ReminderHudBounds $placement $WorkArea $window.Width $window.Height
    $window.Bounds = $bounds
    Set-ReminderHudPlacement $placement $bounds $WorkArea
}

$dragGrip = [Windows.Forms.Label]::new()
$dragGrip.Name = 'hud-drag-grip'
$dragGrip.AccessibleName = '拖动浮窗'
$dragGrip.Text = '拖动'
$dragGrip.TextAlign = 'MiddleCenter'
$dragGrip.BackColor = [Drawing.Color]::FromArgb(16, 84, 82)
$dragGrip.ForeColor = [Drawing.Color]::White
$dragGrip.Cursor = [Windows.Forms.Cursors]::SizeAll
$dragGrip.SetBounds(210, 0, 46, 46)
$dragGrip.Add_MouseDown({
    param($sender, $mouse)
    if ($mouse.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $point = $sender.PointToScreen($mouse.Location)
    $drag.X = $point.X - $window.Left
    $drag.Y = $point.Y - $window.Top
    $drag.Active = $true
    $dragGrip.Capture = $true
})
$dragGrip.Add_MouseMove({
    param($sender, $mouse)
    if (!$drag.Active) { return }
    $point = $sender.PointToScreen($mouse.Location)
    $workArea = [Windows.Forms.Screen]::FromPoint($point).WorkingArea
    Move-ReminderHud ($point.X - $drag.X) ($point.Y - $drag.Y) $workArea
})
$dragGrip.Add_MouseUp({
    param($sender, $mouse)
    if ($mouse.Button -eq [Windows.Forms.MouseButtons]::Left) {
        $drag.Active = $false
        $dragGrip.Capture = $false
    }
})
$dragGrip.Add_MouseCaptureChanged({ if (!$dragGrip.Capture) { $drag.Active = $false } })
$window.Controls.Add($dragGrip)

$menu = [Windows.Forms.ContextMenuStrip]::new()
$header.ContextMenuStrip = $menu
$dragGrip.ContextMenuStrip = $menu
$window.ContextMenuStrip = $menu

function Start-MockRun {
    if ($demoLoaded) { return }
    $script:demoLoaded = $true
    $now = [datetimeoffset]::Now
    $sample = New-MockEvent 'codex-blank-01' 'request-1' 'InputRequested' '等待输入' '回到任务查看空白输入请求' $now.AddMinutes(-8)
    # Synthetic summary sample only; no provider or conversational data is read by the UI.
    $sample.DemoSummary = @{
        Progress = '已列出三个示例文件，未修改源文件。'
        NextAction = '确认清单按文件名还是修改时间排序。'
    }
    Add-ReminderEvent $state $sample
    if ($CodexDemo) { return }
    Add-ReminderEvent $state (New-MockEvent 'qoder-blank-02' 'request-1' 'ApprovalRequested' '等待审批' '回到任务查看空白审批请求' $now.AddMinutes(-3))
    Add-ReminderEvent $state (New-MockEvent 'dsh-blank-03' 'turn-1' 'Running')
    Add-ReminderEvent $state (New-MockEvent 'dsh-blank-03' 'turn-1' 'Completed' -Sequence 2)
    Add-ReminderEvent $state (New-MockEvent 'dsh-blank-03' 'review-1' 'ReviewRequested' '完成待评审' '查看空白任务结果' -Sequence 3)
}

function Complete-MockInput {
    if (!$demoLoaded) { return }
    Add-ReminderEvent $state (New-MockEvent 'codex-blank-01' 'request-1' 'RequestResolved' -Sequence 2)
}

$loadDemo = $menu.Items.Add('加载 Codex、Qoder、DSH 模拟任务')
$loadDemo.Add_Click({ Start-MockRun; Update-ReminderWindow })
$resolveDemo = $menu.Items.Add('模拟 Codex 已回复')
$resolveDemo.Add_Click({ Complete-MockInput; Update-ReminderWindow })
$disconnectDemo = $menu.Items.Add('模拟 Qoder 断连')
$disconnectDemo.Add_Click({
    if (!$demoLoaded) { return }
    Add-ReminderEvent $state (New-MockEvent 'qoder-blank-02' '' 'Disconnected' -Sequence 2)
    Update-ReminderWindow
})
$reconnectDemo = $menu.Items.Add('模拟 Qoder 重连')
$reconnectDemo.Add_Click({
    if (!$demoLoaded) { return }
    Add-ReminderEvent $state (New-MockEvent 'qoder-blank-02' '' 'ConnectionOpened' -Epoch 2)
    Update-ReminderWindow
})
$confirmDemo = $menu.Items.Add('模拟 Qoder 核对仍在等待审批')
$confirmDemo.Add_Click({
    if (!$demoLoaded) { return }
    $snapshot = New-MockEvent 'qoder-blank-02' '' 'ConnectionReconciled' -Epoch 2 -Sequence 2
    $snapshot.PendingRequests = @(New-MockEvent 'qoder-blank-02' 'request-1' 'ApprovalRequested' '等待审批' -Epoch 2 -Sequence 2)
    Add-ReminderEvent $state $snapshot
    Update-ReminderWindow
})
if ($CodexDemo) {
    foreach ($item in @($loadDemo, $disconnectDemo, $reconnectDemo, $confirmDemo)) {
        $item.Visible = $false
    }
}
if ($CodexDesktopSnapshot -or $CodexLocal) {
    foreach ($item in @($loadDemo, $resolveDemo, $disconnectDemo, $reconnectDemo, $confirmDemo)) {
        $item.Visible = $false
    }
}
[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$quit = $menu.Items.Add('退出')
$quit.Add_Click({ $window.Close() })

function Toggle-ReminderHudVisibility {
    if ($window.Visible) { $window.Hide() }
    else { $window.Show() }
}

$menuButton = [Windows.Forms.Button]::new()
$menuButton.Text = if ($CodexDesktopSnapshot -or $CodexLocal) { '菜单 ▾' } else { '模拟事件 ▾' }
$menuButton.SetBounds(308, 7, 112, 32)
$menuButton.Add_Click({ $menu.Show($menuButton, [Drawing.Point]::new(0, $menuButton.Height)) })
$window.Controls.Add($menuButton)

$list = if ($CodexLocal) {
    Initialize-LocalHudTypes
    [JieShou.SessionListPanel]::new()
} else { [Windows.Forms.FlowLayoutPanel]::new() }
$list.SetBounds(8, 52, 412, 388)
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$window.Controls.Add($list)

function New-TargetWindow($Target) {
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = "模拟任务 · $($Target.Name)"
    $dialog.Tag = $Target
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [Drawing.Size]::new(376, 119)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = $window.Font
    $details = [Windows.Forms.Label]::new()
    $details.SetBounds(14, 12, 348, 62)
    $details.Text = "$($Target.Name)`r`n任务 ID  $($Target.Id)`r`n$($Target.Target)"
    $dialog.Controls.Add($details)
    $close = [Windows.Forms.Button]::new()
    $close.Text = '关闭'
    $close.SetBounds(280, 78, 80, 30)
    $close.DialogResult = 'OK'
    $dialog.AcceptButton = $close
    $dialog.CancelButton = $close
    $dialog.Controls.Add($close)
    $dialog
}

function Start-ReminderUri([string]$Uri) {
    $info=[Diagnostics.ProcessStartInfo]::new($Uri)
    $info.UseShellExecute=$true
    $process=[Diagnostics.Process]::Start($info)
    if ($process) { $process.Dispose() }
}

function Get-ReminderDesktopUri($Event) {
    $uri=Resolve-CodexDesktopTarget $Event $state $codexFeed
    if ($uri -and $CodexLocal) { return Get-LocalCodexUri $Event.TaskId }
    $uri
}

function Open-ReminderTarget($Event) {
    if ($Event.ConnectionId -ceq 'windows-chatgpt-desktop') {
        if ($UiTest -or !$CodexDesktopSnapshot) { return }
        # Recheck the source at click time, so stale/redacted rows cannot launch a target.
        $changed = Update-CodexDesktopSnapshot $state $codexFeed $CodexDesktopSnapshot
        $uri = Get-ReminderDesktopUri $Event
        if ($changed) { Update-ReminderWindow }
        if (!$uri) { return }
        if ($CodexLocal) { Open-LocalHudSession Codex $Event.TaskId; return }
        try {
            Start-ReminderUri $uri
        } catch {
            [void][Windows.Forms.MessageBox]::Show($window, 'Windows 未能打开此 ChatGPT 桌面会话。', '智能体消息中心')
        }
        return
    }
    $target = Resolve-MockTarget $Event
    if (!$target) { return }
    $dialog = New-TargetWindow $target
    try {
        if ($UiTest) {
            $dialog.Add_Shown({
                $script:verifiedTarget = $this.Tag
                $this.Close()
            })
        }
        [void]$dialog.ShowDialog($window)
    } finally {
        $dialog.Dispose()
    }
}

function Add-ReminderGroup([string]$Title, [array]$Rows, [ValidateSet('Waiting','Review','Pending')][string]$Mode, [Collections.Generic.List[Windows.Forms.Control]]$Created) {
    $caption = [Windows.Forms.Label]::new()
    $caption.Text = "$Title  $($Rows.Count)"
    $caption.Size = [Drawing.Size]::new(390, 25)
    $caption.TextAlign = 'MiddleLeft'
    $caption.ForeColor = $accent
    $list.Controls.Add($caption)
    if ($null -ne $Created) { $Created.Add($caption) }
    foreach ($row in $Rows) {
        $event = $row.Event
        $key = Get-ReminderKey $event
        $card = [Windows.Forms.Panel]::new()
        if ($null -ne $Created) { $Created.Add($card) }
        $demoSummary = $null
        if ($Mode -eq 'Waiting' -and (Resolve-MockTarget $event)) { $demoSummary = $event.DemoSummary }
        $card.Size = [Drawing.Size]::new(386, $(if ($demoSummary) { 137 } else { 106 }))
        $card.BackColor = [Drawing.Color]::White
        $details = [Windows.Forms.Label]::new()
        $details.SetBounds(10, 7, 365, $(if ($demoSummary) { 90 } else { 59 }))
        $status = if ($Mode -eq 'Pending') {
            '暂未确认当前状态'
        } elseif ($demoSummary) {
            "$($event.Stage) · 示例摘要`r`n做到哪了  $($demoSummary.Progress)`r`n现在要你  $($demoSummary.NextAction)"
        } else {
            "$($event.Stage)`r`n下一步  $(Get-ReminderNextStep $event)"
        }
        $details.Text = "$($event.Source) · $($event.Name)`r`n$status"
        $card.Controls.Add($details)
        $targetButton = [Windows.Forms.Button]::new()
        $targetButton.Name = "jump-$($event.TaskId)"
        $isDesktop = $event.ConnectionId -ceq 'windows-chatgpt-desktop'
        $targetButton.Text = if ($isDesktop) { '回到桌面会话' } else { '打开模拟任务' }
        $buttonY = if ($demoSummary) { 101 } else { 70 }
        $targetButton.SetBounds(10, $buttonY, 118, 27)
        $targetButton.Tag = $event
        $targetButton.Enabled = if ($isDesktop) {
            [bool](Get-ReminderDesktopUri $event)
        } else {
            [bool](Resolve-MockTarget $event)
        }
        $targetButton.Add_Click({ Open-ReminderTarget $this.Tag })
        $card.Controls.Add($targetButton)
        if ($Mode -eq 'Pending') {
            $list.Controls.Add($card)
            continue
        }
        $action = [Windows.Forms.Button]::new()
        $action.Tag = $key
        $action.SetBounds(282, $buttonY, 92, 27)
        if ($Mode -eq 'Waiting') {
            $action.Text = if ($row.Pinned) { '取消置顶' } else { '置顶' }
            $action.Add_Click({ Set-ReminderPinned $state $this.Tag; Update-ReminderWindow })
        } else {
            $action.Text = '标已读'
            $action.Add_Click({ Set-ReminderRead $state $this.Tag; Update-ReminderWindow })
        }
        $card.Controls.Add($action)
        $list.Controls.Add($card)
    }
}

function Update-ReminderWindow {
    if ($CodexLocal) { Update-LocalHudWindow; return }
    $waiting = @(Get-ReminderWaiting $state)
    $header.Text = if ($UiTest -or $demoLoaded) { "等我 $($waiting.Count)｜待看 $($state.Review.Count)" }
        else { Get-CodexDesktopCountCaption $codexFeed $waiting.Count }
    if (!$UiTest) {
        $status = if ($demoLoaded) { '模拟演示，非真实会话' }
            elseif (!$CodexDesktopSnapshot) { 'ChatGPT 桌面未接入' }
            elseif ($codexFeed.Status -ceq 'Current') { '桌面状态入口可用' }
            else { '桌面源不可用' }
        $header.Text += [Environment]::NewLine + $status
    }
    $window.Text = if ($demoLoaded) { '智能体消息中心（含模拟）' } else { '智能体消息中心' }
    $window.AccessibleName = $window.Text
    $header.AccessibleDescription = if ($expanded) { '单击收起' } else { '单击展开' }
    $header.Width = if ($expanded) { 252 } else { 210 }
    $dragGrip.Left = $header.Right
    $menuButton.Visible = $expanded
    $list.Visible = $expanded
    $width = if ($expanded) { 428 } else { 256 }
    $height = 46
    if ($expanded) {
        $list.SuspendLayout()
        while ($list.Controls.Count -gt 0) { $list.Controls[0].Dispose() }
        if (!$UiTest -and !$demoLoaded -and $codexFeed.Status -cne 'Current') {
            $notice = [Windows.Forms.Label]::new()
            $notice.Size = [Drawing.Size]::new(390, 52)
            $notice.Text = "目前无法核对真实 ChatGPT 桌面会话。`r`n缺少状态不等于没有任务在等你。"
            $list.Controls.Add($notice)
        }
        if ($UiTest -or $demoLoaded -or $codexFeed.Status -ceq 'Current') {
            Add-ReminderGroup '等我' $waiting 'Waiting'
        }
        if ($UiTest -or $demoLoaded) {
            Add-ReminderGroup '待看' @(Get-ReminderRows $state.Review) 'Review'
        }
        $pending = @(Get-ReminderWaiting $state -Pending)
        if ($pending.Count) { Add-ReminderGroup '待确认' $pending 'Pending' }
        $contentHeight = 0
        foreach ($control in $list.Controls) { $contentHeight += $control.Height + $control.Margin.Vertical }
        $height = [Math]::Min(448, $list.Top + $contentHeight + 8)
        $list.ResumeLayout()
    }
    $workArea = if ($placement.Positioned) { [Windows.Forms.Screen]::FromRectangle($window.Bounds).WorkingArea }
        else { [Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    $window.Bounds = Get-ReminderHudBounds $placement $workArea $width $height
    if (!$placement.Positioned) { Set-ReminderHudPlacement $placement $window.Bounds $workArea }
    $list.Height = [Math]::Max(0, $window.ClientSize.Height - $list.Top - 8)
}

try {
    if (!$UiTest) {
        $trayMenu = [Windows.Forms.ContextMenuStrip]::new()
        $trayVisibility = $trayMenu.Items.Add('显示或隐藏浮窗')
        $trayVisibility.Add_Click({ Toggle-ReminderHudVisibility })
        $trayQuit = $trayMenu.Items.Add('退出')
        $trayQuit.Add_Click({ $window.Close() })
        $tray = [Windows.Forms.NotifyIcon]::new()
        $trayIcon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'assets/amc-message-grip.ico'),[Windows.Forms.SystemInformation]::SmallIconSize)
        $tray.Icon = $trayIcon
        $tray.Text = '智能体消息中心'
        $tray.ContextMenuStrip = $trayMenu
        $tray.Add_DoubleClick({ Toggle-ReminderHudVisibility })
        $tray.Visible = $true
    }
    if ($CodexDesktopSnapshot) {
        [void](Update-CodexDesktopSnapshot $state $codexFeed $CodexDesktopSnapshot)
        $codexTimer = [Windows.Forms.Timer]::new()
        $codexTimer.Interval = 1000
        $codexTimer.Add_Tick({
            if ($CodexLocal -and $localChrome.Surface.IsRevealing) { return }
            if (Update-CodexDesktopSnapshot $state $codexFeed $CodexDesktopSnapshot) { Update-ReminderWindow }
        })
        $codexTimer.Start()
    }
    if ($CodexDemo) {
        Start-MockRun
    }
    if ($CodexLocal) {
        Initialize-LocalHudView
        $localTimer = [Windows.Forms.Timer]::new()
        $localTimer.Interval = 350
        $localTimer.Add_Tick({
            Update-LocalNavigation
            if ($localChrome.Surface.IsRevealing) { return }
            Update-DshAttention; Update-QoderAttention; Update-LocalSessionList
            $localChrome.ActivityAnimation.Refresh()
        })
        $localTimer.Start()
    }
    Update-ReminderWindow
    if ($UiTest -and $CodexLocal) {
        . "$PSScriptRoot/Test-CodexLocalUi.ps1"
    } elseif ($UiTest) {
        . "$PSScriptRoot/Reminder.UiTest.ps1"
    } else {
        [Windows.Forms.Application]::Run($window)
    }
} finally {
    if ($localTimer) { $localTimer.Dispose(); Stop-LocalNavigation; Stop-LocalSessionRead }
    if ($codexTimer) { $codexTimer.Dispose() }
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($trayIcon) { $trayIcon.Dispose() }
    if ($trayMenu) { $trayMenu.Dispose() }
    $menu.Dispose()
    if ($CodexLocal -and $localChrome.Surface) { $localChrome.Surface.Dispose() }
    $window.Dispose()
    if ($CodexLocal -and $hudTips) {
        $hudTips.Dispose()
        foreach ($icon in $agentIcons.Values) { $icon.Dispose() }
        $windowComponents.Dispose()
        foreach ($font in $hudFonts.Values) { $font.Dispose() }
    }
}
