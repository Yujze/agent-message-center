$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Reminder.State.ps1"

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) {
        throw "$Message。预期 [$Expected]，实际 [$Actual]"
    }
}

function New-TestEvent($Kind, $Task = 'task-a', $Id = 'request-1', $Connection = 'conn-1', $Epoch = 1, $Sequence = 1, $Source = 'Codex') {
    @{
        Kind = $Kind; Source = $Source; ConnectionId = $Connection
        TaskId = $Task; Id = $Id; Epoch = $Epoch; Sequence = $Sequence
        At = [datetimeoffset]'2026-11-23T09:00:00+08:00'
    }
}

$failures = [Collections.Generic.List[string]]::new()
try {
    $collision = New-ReminderState
    Add-ReminderEvent $collision (New-TestEvent InputRequested)
    Add-ReminderEvent $collision (New-TestEvent ApprovalRequested -Task task-b -Sequence 2)
    Assert-Equal $collision.Waiting.Count 2 '同一来源、同一连接的两个任务可使用相同请求编号'
    Add-ReminderEvent $collision (New-TestEvent RequestResolved -Task task-b -Sequence 3)
    Assert-Equal $collision.Waiting.Count 1 '处理 B 只清除 B'
    Assert-Equal (@($collision.Waiting.Values)[0].Event.TaskId) 'task-a' 'A 的等待仍在'
} catch { $failures.Add($_.Exception.Message) }
try {
    $offline = New-ReminderState
    Add-ReminderEvent $offline (New-TestEvent InputRequested)
    Add-ReminderEvent $offline (New-TestEvent Disconnected -Sequence 2)
    Assert-Equal $offline.Waiting.Count 1 '断连保留记录'
    Assert-Equal (@($offline.Waiting.Values)[0].PendingConfirmation) $true '断连标为待确认'
    Assert-Equal (@($offline.Waiting.Values | Where-Object { !$_.PendingConfirmation }).Count) 0 '断连等待不计为当前提醒'
} catch { $failures.Add($_.Exception.Message) }
if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }

$otherConnection = New-TestEvent ApprovalRequested -Connection conn-2
Add-ReminderEvent $collision $otherConnection
Add-ReminderEvent $collision (New-TestEvent ApprovalRequested -Task task-b -Sequence 2)
Assert-Equal (@(Get-ReminderWaiting $collision).Count) 2 '迟到的 B 请求不复现，其他连接的同名编号独立'
Add-ReminderEvent $collision (New-TestEvent RequestResolved -Sequence 1)
Assert-Equal (@(Get-ReminderWaiting $collision).Count) 2 '旧于请求的清除信号不生效'
Add-ReminderEvent $collision (New-TestEvent RequestResolved -Task task-c -Sequence 5)
Add-ReminderEvent $collision (New-TestEvent InputRequested -Task task-c -Sequence 4)
Assert-Equal $collision.Waiting.Count 2 '清除先到时，迟到的任务请求不复现'

$offline = New-ReminderState
$pendingRequest = New-TestEvent InputRequested
Add-ReminderEvent $offline $pendingRequest
Set-ReminderPinned $offline (Get-ReminderKey $pendingRequest)
Add-ReminderEvent $offline (New-TestEvent ApprovalRequested -Task task-b -Sequence 2)
Add-ReminderEvent $offline $otherConnection
Add-ReminderEvent $offline (New-TestEvent Disconnected -Sequence 3)
Add-ReminderEvent $offline (New-TestEvent RequestResolved -Sequence 4)
Assert-Equal (@(Get-ReminderWaiting $offline).Count) 1 '断连只影响对应连接'
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 2 '断连后的迟到清除也不能改写待确认记录'
Add-ReminderEvent $offline (New-TestEvent ConnectionOpened -Epoch 2)
Add-ReminderEvent $offline (New-TestEvent InputRequested -Epoch 2 -Sequence 2 -Task task-c)
Add-ReminderEvent $offline (New-TestEvent ConnectionReconciled -Epoch 2 -Sequence 2)
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 2 '重连、普通事件或没有快照内容都不能恢复'
$snapshot = New-TestEvent ConnectionReconciled -Epoch 2 -Sequence 3
$snapshot.PendingRequests = @($otherConnection)
Add-ReminderEvent $offline $snapshot
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 2 '错误连接的快照不会部分改写状态'
$snapshot.PendingRequests = @(New-TestEvent InputRequested -Epoch 2 -Sequence 3)
Add-ReminderEvent $offline $snapshot
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 0 '完整快照清除待确认状态'
Assert-Equal (@(Get-ReminderWaiting $offline).Count) 2 '只恢复快照确认的等待，加上另一连接的一条'
Assert-Equal (@(Get-ReminderWaiting $offline)[0].Pinned) $true '恢复后保留置顶'
Add-ReminderEvent $offline (New-TestEvent RequestResolved -Sequence 99)
Add-ReminderEvent $offline (New-TestEvent RequestResolved -Epoch 2 -Sequence 3)
Add-ReminderEvent $offline (New-TestEvent Disconnected -Epoch 2 -Sequence 2)
Add-ReminderEvent $offline (New-TestEvent ApprovalRequested -Task task-b -Epoch 2 -Sequence 4)
Assert-Equal (@(Get-ReminderWaiting $offline).Count) 2 '旧代际和快照前的迟到事件不生效，快照清除项不会复现'
Add-ReminderEvent $offline (New-TestEvent RequestResolved -Epoch 2 -Sequence 5)
Assert-Equal (@(Get-ReminderWaiting $offline).Count) 1 '快照后确认的清除只影响对应请求'
Add-ReminderEvent $offline (New-TestEvent InputRequested -Id request-2 -Epoch 2 -Sequence 6)
Add-ReminderEvent $offline (New-TestEvent Disconnected -Epoch 2 -Sequence 7)
Add-ReminderEvent $offline (New-TestEvent ConnectionOpened -Epoch 3)
Add-ReminderEvent $offline (New-TestEvent Disconnected -Epoch 3 -Sequence 2)
$empty = New-TestEvent ConnectionReconciled -Epoch 3 -Sequence 3
$empty.PendingRequests = @()
Add-ReminderEvent $offline $empty
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 1 '重连后再次断开，上一轮快照失效'
Add-ReminderEvent $offline (New-TestEvent ConnectionOpened -Epoch 4)
$empty = New-TestEvent ConnectionReconciled -Epoch 4 -Sequence 2
$empty.PendingRequests = @()
Add-ReminderEvent $offline $empty
Assert-Equal (@(Get-ReminderWaiting $offline -Pending).Count) 0 '可靠的空快照可清理未恢复的记录'

$missedDisconnect = New-ReminderState
Add-ReminderEvent $missedDisconnect $pendingRequest
Add-ReminderEvent $missedDisconnect (New-TestEvent ConnectionOpened -Epoch 2)
Add-ReminderEvent $missedDisconnect (New-TestEvent Disconnected -Sequence 2)
Assert-Equal (@(Get-ReminderWaiting $missedDisconnect).Count) 0 '发现连接换代也需要重新核对旧等待'
Assert-Equal (@(Get-ReminderWaiting $missedDisconnect -Pending).Count) 1 '漏收断连通知时也保留待确认记录'
Add-ReminderEvent $missedDisconnect $snapshot
Assert-Equal (@(Get-ReminderWaiting $missedDisconnect).Count) 1 '旧代迟到的断连不能阻止新代确认'

$state = New-ReminderState
$taskA = 'codex-blank-01'
$taskB = 'qoder-blank-02'
$taskC = 'dsh-blank-03'
$now = [datetimeoffset]::Now
$inputA = New-MockEvent $taskA 'req-1' 'InputRequested' '等待输入' '' $now.AddMinutes(-5)
$approvalB = New-MockEvent $taskB 'req-1' 'ApprovalRequested' '等待审批' '' $now.AddMinutes(-1)
$keyB = Get-ReminderKey $approvalB

foreach ($kind in 'Running', 'Unknown', 'Completed', 'NextStepProvided') {
    Add-ReminderEvent $state (New-MockEvent $taskA "silent-$kind" $kind '状态')
}
Assert-Equal $state.Waiting.Count 0 '运行、断连、未知和无信号完成时没有等待'
Assert-Equal $state.Review.Count 0 '没有明确下一步或评审时没有待看'

Add-ReminderEvent $state $approvalB
Add-ReminderEvent $state $inputA
Add-ReminderEvent $state $inputA
Assert-Equal $state.Waiting.Count 2 '同来源同请求去重，跨来源保留'
Assert-Equal (@(Get-ReminderRows $state.Waiting)[0].Event.TaskId) $taskA '等待时间长者在前'
Set-ReminderPinned $state $keyB
Assert-Equal (@(Get-ReminderRows $state.Waiting)[0].Event.TaskId) $taskB '组内置顶优先'
Set-ReminderPinned $state $keyB
Assert-Equal (@(Get-ReminderRows $state.Waiting)[0].Event.TaskId) $taskA '取消置顶恢复排序'
Add-ReminderEvent $state (New-MockEvent $taskA 'other-request' 'RequestResolved' -Sequence 2)
Assert-Equal $state.Waiting.Count 2 '其他请求的回复不清除等待'
Add-ReminderEvent $state (New-MockEvent $taskA 'req-1' 'RequestResolved' -Sequence 3)
Add-ReminderEvent $state $inputA
Assert-Equal $state.Waiting.Count 1 '按来源和请求 ID 清除，重放不会复现'
Assert-Equal (@(Get-ReminderRows $state.Waiting)[0].Event.TaskId) $taskB '另一来源的同名请求仍在'
Add-ReminderEvent $state (New-MockEvent $taskA 'req-2' 'InputRequested' -Sequence 4)
Assert-Equal $state.Waiting.Count 2 '同任务的新请求单独显示'

$review = New-MockEvent $taskC 'review-1' 'ReviewRequested' '完成待评审'
$next = New-MockEvent $taskA 'next-1' 'NextStepProvided' '完成' '查看空白输出' -Sequence 5
Add-ReminderEvent $state $review
Add-ReminderEvent $state $review
Add-ReminderEvent $state $next
Assert-Equal (Get-ReminderNextStep $review) '评审任务结果' '明确评审请求给出对应下一步'
Assert-Equal $state.Waiting.Count 2 '待评审和明确下一步不计为等待'
Assert-Equal $state.Review.Count 2 '待看支持去重并保留明确的下一步'
Set-ReminderRead $state (Get-ReminderKey $review)
Add-ReminderEvent $state $review
Assert-Equal $state.Review.Count 1 '已读后重放不再出现'

Assert-Equal (Resolve-MockTarget $inputA).Id $taskA 'Codex 回跳匹配任务 A'
Assert-Equal (Resolve-MockTarget $approvalB).Id $taskB 'Qoder 回跳匹配任务 B'
Assert-Equal (Resolve-MockTarget $review).Id $taskC 'DSH 回跳匹配任务 C'
$inputA.Target = $review.Target
Assert-Equal (Resolve-MockTarget $inputA) $null '任务 A 无法使用别的任务入口'
'状态测试通过'

& "$PSScriptRoot/Start-Reminder.ps1" -UiTest
