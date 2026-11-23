$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Reminder.State.ps1"
. "$PSScriptRoot/Reminder.CodexDesktop.ps1"

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$($Message): expected [$Expected], got [$Actual]" }
}

$state = New-ReminderState
$feed = New-CodexDesktopFeed
$clock = [DateTimeOffset]::UtcNow
$file = Join-Path ([IO.Path]::GetTempPath()) ("reminder-codex-snapshot-$([guid]::NewGuid()).json")
$aId = '11111111-1111-4111-8111-111111111111'
$bId = '11111111-2222-4222-8222-222222222222'
$a = @{ threadId=$aId; requestId='same:1'; kind='input' }
$b = @{ threadId=$bId; requestId='same:1'; kind='approval' }

function Store-Snapshot([long]$Epoch, [long]$Sequence, [array]$Pending, [DateTimeOffset]$At = $clock, [string]$Source = 'windows-chatgpt-desktop') {
    @{
        schema=1; source=$Source; epoch=$Epoch; sequence=$Sequence
        observedAt=$At.UtcDateTime.ToString('o', [CultureInfo]::InvariantCulture); pending=$Pending
    } | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $file -Encoding utf8
}
function Wait-Count { @(Get-ReminderWaiting $state).Count }
function Pending-Count { @(Get-ReminderWaiting $state -Pending).Count }

try {
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock) $false 'Missing publisher does not constitute a live source'
    Assert-Equal $feed.Status Unavailable 'Unavailable before a verified snapshot'
    Store-Snapshot 1 1 @($a,$b)
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock) $true 'Apply first fresh snapshot'
    Assert-Equal (Wait-Count) 2 'Same request ID in separate desktop threads'
    $taskA = @(Get-ReminderWaiting $state | Where-Object { $_.Event.TaskId -ceq $aId })[0].Event
    $taskB = @(Get-ReminderWaiting $state | Where-Object { $_.Event.TaskId -ceq $bId })[0].Event
    Assert-Equal (Resolve-CodexDesktopTarget $taskA $state $feed $clock) "codex://threads/$aId" 'Target A derives from verified ID'
    Assert-Equal (Resolve-CodexDesktopTarget $taskB $state $feed $clock) "codex://threads/$bId" 'Target B derives from verified ID'
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock) $false 'Identical current snapshot is ignored'
    Store-Snapshot 1 1 @($a)
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock) $true 'Modified same-sequence snapshot invalidates source'
    Assert-Equal (Wait-Count) 0 'A changed snapshot cannot count'
    Store-Snapshot 1 2 @($a,$b)
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock) $true 'New revision restores pending requests after an invalid source state'
    Set-ReminderPinned $state (Get-ReminderKey $taskB)
    Store-Snapshot 1 3 @($a,$b) $clock.AddSeconds(1)
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(1)) $false 'Heartbeat refresh does not redraw cards'
    Assert-Equal (@(Get-ReminderWaiting $state)[0].Event.TaskId) $bId 'Existing pin retained'
    Store-Snapshot 1 4 @($a) $clock.AddSeconds(2)
    Assert-Equal (Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(2)) $true 'Clear updates UI'
    Assert-Equal (Wait-Count) 1 'Clearing B retains A'
    Assert-Equal (Resolve-CodexDesktopTarget $taskB $state $feed $clock.AddSeconds(2)) $null 'Cleared target disabled'
    Store-Snapshot 1 3 @($a,$b) $clock.AddSeconds(1)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(2))
    Assert-Equal (Wait-Count) 0 'Replay cannot count stale requests'
    Assert-Equal (Pending-Count) 1 'Last confirmed request is unconfirmed on invalid input'
    Assert-Equal (Resolve-CodexDesktopTarget $taskA $state $feed $clock.AddSeconds(2)) $null 'Unconfirmed target cannot launch'
    Store-Snapshot 1 4 @($a) $clock.AddSeconds(2)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(2))
    Assert-Equal (Wait-Count) 0 'Last successful revision cannot recover disconnected state'
    Store-Snapshot 1 5 @($a) $clock.AddSeconds(3)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(3))
    Assert-Equal (Wait-Count) 1 'New authoritative snapshot restores matching wait'
    Assert-Equal (Resolve-CodexDesktopTarget $taskA $state $feed $clock.AddSeconds(14)) $null 'Stale click blocked before timer tick'
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(14))
    Assert-Equal (Wait-Count) 0 'No heartbeat expires active wait'
    Assert-Equal (Pending-Count) 1 'Expired wait retained separately'
    Store-Snapshot 2 1 @($b) $clock.AddSeconds(15)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(15))
    Assert-Equal (Wait-Count) 1 'New generation can reuse a request ID'
    Assert-Equal (Resolve-CodexDesktopTarget $taskB $state $feed $clock.AddSeconds(15)) $null 'Prior-generation button disabled'
    Assert-Equal (Pending-Count) 0 'Full generation snapshot removes stale wait'
    Store-Snapshot 2 2 @($b + @{ url = 'https://example.com' }) $clock.AddSeconds(16)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(16))
    Assert-Equal (Wait-Count) 0 'Unrecognized navigation payload fails closed'
    Store-Snapshot 2 3 @($b,$b) $clock.AddSeconds(17)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(17))
    Assert-Equal (Wait-Count) 0 'Duplicate request IDs in one thread fail closed'
    Store-Snapshot 2 4 @() $clock.AddSeconds(18)
    [void](Update-CodexDesktopSnapshot $state $feed $file $clock.AddSeconds(18))
    Assert-Equal $feed.Status Current 'Authoritative empty snapshot reconnects'
    Assert-Equal $state.Waiting.Count 0 'Authoritative empty snapshot clears requests'
    'Codex desktop snapshot contract passed (fixture only; no real desktop navigation)'
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

$unknown=New-CodexDesktopFeed
if ((Get-CodexDesktopCountCaption $unknown 0) -cne '等我 —｜待看 —') { throw 'Unavailable feed must not show zero' }
$unknown.Status='Current'
if ((Get-CodexDesktopCountCaption $unknown 0) -cne '等我 0｜待看 —') { throw 'Valid empty wait snapshot does not cover review' }
if ((Get-CodexDesktopCountCaption $unknown 2) -cne '等我 2｜待看 —') { throw 'Valid waiting count is missing' }
$unknown.Status='Unavailable'
if ((Get-CodexDesktopCountCaption $unknown 2) -cne '等我 —｜待看 —') { throw 'Stale counts must be suppressed' }
