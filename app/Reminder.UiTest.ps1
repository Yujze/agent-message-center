# Run against the real controls and dialog click handlers without manual input.
$window.Show()
[Windows.Forms.Application]::DoEvents()

function Assert-Header([string]$Expected) {
    if ($header.Text -cne $Expected) { throw "浮窗计数应为 $Expected，实际为 $($header.Text)" }
}

if ($CodexDemo) {
    Assert-Header '等我 1｜待看 0'
    if ($list.Visible) { throw 'Codex 试用应在紧凑状态启动' }
    if ($window.Controls.Find('hud-drag-grip', $false).Length -ne 1) { throw '缺少独立拖动手柄' }
    $negWork = [Drawing.Rectangle]::new(-1600, -100, 1600, 850)
    $layout = New-ReminderHudPlacement
    $nearEdge = [Drawing.Rectangle]::new(-272, 682, 256, 46)
    Set-ReminderHudPlacement $layout $nearEdge $negWork
    $grown = Get-ReminderHudBounds $layout $negWork 428 448
    if ($grown.Right -ne $nearEdge.Right -or $grown.Bottom -ne $nearEdge.Bottom -or !$negWork.Contains($grown)) {
        throw '副屏右下角应保留锚点且向内展开'
    }
    $work = [Windows.Forms.Screen]::FromRectangle($window.Bounds).WorkingArea
    Move-ReminderHud ($work.Left + 40) ($work.Top + 45) $work
    if ($window.Left -ne ($work.Left + 40) -or $window.Top -ne ($work.Top + 45)) { throw '模拟拖动后窗口位置不符' }
    Toggle-ReminderHudVisibility
    if ($window.Visible) { throw '托盘隐藏回调未隐藏窗口' }
    Toggle-ReminderHudVisibility
    if (!$window.Visible) { throw '托盘恢复回调未恢复窗口' }
    $compact = $window.Bounds
    $header.PerformClick()
    if (!$list.Visible) { throw '点击计数胶囊后应展开' }
    $work = [Windows.Forms.Screen]::FromRectangle($window.Bounds).WorkingArea
    if (!$work.Contains($window.Bounds)) { throw '展开不应超出显示器工作区' }
    if ($window.Height -le $compact.Height) { throw '展开后应有更多内容空间' }
    $header.PerformClick()
    if ($list.Visible -or $window.Bounds -ne $compact) { throw '收起应回到紧凑位置' }
    $header.PerformClick()
    foreach ($id in @('qoder-blank-02','dsh-blank-03')) {
        if ($list.Controls.Find("jump-$id", $true).Length) { throw "Codex 演示不应显示 $id" }
    }
    $button = @($list.Controls.Find('jump-codex-blank-01', $true))[0]
    if (!$button -or !($button.Parent.Controls | Where-Object Text -like '*示例摘要*')) { throw '未显示 Codex 示例摘要' }
    $button.PerformClick()
    if ($verifiedTarget.Id -cne 'codex-blank-01') { throw 'Codex 演示打开了错误任务' }
    $resolveDemo.PerformClick()
    Assert-Header '等我 0｜待看 0'
    'Codex 单项演示通过：紧凑启动、展开及收起、示例摘要、对应任务及回复后清除'
    return
}

Assert-Header '等我 0｜待看 0'
if ($list.Visible) { throw '启动时应收起' }
$header.PerformClick()
if (!$list.Visible) { throw '点击计数后应展开' }
$loadDemo.PerformClick()
Assert-Header '等我 2｜待看 1'
$codexCard = @($list.Controls.Find('jump-codex-blank-01', $true))[0].Parent
$summaryLabel = @($codexCard.Controls | Where-Object { $_ -is [Windows.Forms.Label] })[0]
if ($summaryLabel.Text -notmatch '示例摘要' -or $summaryLabel.Text -notmatch '做到哪了' -or
    $summaryLabel.Text -notmatch '现在要你') { throw 'Codex 演示卡未显示两段示例摘要' }
$approval = @($list.Controls.Find('jump-qoder-blank-02', $true))[0]
$pin = @($approval.Parent.Controls | Where-Object Text -eq '置顶')[0]
$pin.PerformClick()
$firstCard = @($list.Controls | Where-Object { $_ -is [Windows.Forms.Panel] })[0]
if (!$firstCard.Controls.Find('jump-qoder-blank-02', $false).Length) { throw '置顶后任务 B 应排在首位' }
foreach ($expectation in @(
    @{ Id = 'codex-blank-01'; Target = 'mock://codex/task/codex-blank-01' }
    @{ Id = 'qoder-blank-02'; Target = 'mock://qoder/task/qoder-blank-02' }
    @{ Id = 'dsh-blank-03'; Target = 'mock://dsh/task/dsh-blank-03' }
)) {
    $button = @($list.Controls.Find("jump-$($expectation.Id)", $true))[0]
    if (!$button) { throw "找不到任务 $($expectation.Id) 的跳转按钮" }
    $script:verifiedTarget = $null
    $button.PerformClick()
    if ($verifiedTarget.Id -cne $expectation.Id -or $verifiedTarget.Target -cne $expectation.Target) {
        throw "未打开正确的目标窗口：$($expectation.Id)"
    }
}
$resolveDemo.PerformClick()
Assert-Header '等我 1｜待看 1'
$disconnectDemo.PerformClick()
Assert-Header '等我 0｜待看 1'
if (!($list.Controls | Where-Object Text -eq '待确认  1')) { throw '断连后应显示待确认' }
$reconnectDemo.PerformClick()
Assert-Header '等我 0｜待看 1'
$confirmDemo.PerformClick()
Assert-Header '等我 1｜待看 1'
if ($list.Controls | Where-Object Text -eq '待确认  1') { throw '核对后应清除待确认' }
$restored = @($list.Controls.Find('jump-qoder-blank-02', $true))[0]
if (!($restored.Parent.Controls | Where-Object Text -eq '取消置顶')) { throw '核对后应保留置顶' }
$review = @($list.Controls.Find('jump-dsh-blank-03', $true))[0]
$read = @($review.Parent.Controls | Where-Object Text -eq '标已读')[0]
$read.PerformClick()
Add-ReminderEvent $state (New-MockEvent 'dsh-blank-03' 'review-1' 'ReviewRequested' -Sequence 3)
Update-ReminderWindow
Assert-Header '等我 1｜待看 0'
$header.PerformClick()
if ($list.Visible) { throw '再次点击计数后应收起' }
'浮窗测试通过，已点击并验证三个模拟目标窗口'
