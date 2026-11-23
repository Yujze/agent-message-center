# Reads an opt-in, metadata-only snapshot; it does not discover or attach to the app.
function New-CodexDesktopFeed {
    @{ Epoch = [long]0; Sequence = [long]0; ObservedAt = [datetimeoffset]::MinValue; Status = 'Unavailable' }
}

function Test-CodexDesktopFields($Object, [string[]]$Keys) {
    if ($Object -isnot [System.Collections.IDictionary] -or $Object.Count -ne $Keys.Count) { return $false }
    foreach ($key in $Keys) {
        if (!($Object.Keys -ccontains $key)) { return $false }
    }
    return $true
}

function Set-CodexDesktopUnavailable($State, $Feed) {
    if ($Feed.Status -eq 'Unavailable') { return $false }
    $Feed.Status = 'Unavailable'
    Set-ConnectionWaitingUnconfirmed $State (Get-ConnectionKey @{ Source = 'Codex'; ConnectionId = 'windows-chatgpt-desktop' })
    return $true
}

function Update-CodexDesktopSnapshot($State, $Feed, [string]$Path, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    try {
        if (![IO.Path]::IsPathFullyQualified($Path) -or $Path -cnotmatch '\A[A-Za-z]:\\[^:\r\n]+\.json\z' -or
            [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).DriveType -ne [IO.DriveType]::Fixed) {
            throw 'The snapshot path must be a JSON file on a local fixed drive.'
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        for ($node = $item; $node; $node = if ($node -is [IO.FileInfo]) { $node.Directory } else { $node.Parent }) {
            if ($node.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported.' }
        }
        if ($item -isnot [IO.FileInfo] -or $item.Length -gt 65536) { throw 'Invalid snapshot file.' }
        $inputFile = [IO.File]::Open($item.FullName, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($inputFile.Length -gt 65536) { throw 'The snapshot is too large.' }
            $buffer = [byte[]]::new(65537)
            $count = 0
            while ($count -lt $buffer.Length) {
                $received = $inputFile.Read($buffer, $count, $buffer.Length - $count)
                if (!$received) { break }
                $count += $received
            }
            if ($count -gt 65536) { throw 'The snapshot is too large.' }
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $count).TrimStart([char]0xFEFF)
        } finally { $inputFile.Dispose() }
        $snapshot = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 6 -DateKind String -ErrorAction Stop
        if (!(Test-CodexDesktopFields $snapshot @('schema','source','epoch','sequence','observedAt','pending')) -or
            $snapshot.schema -isnot [long] -or $snapshot.schema -ne 1 -or
            $snapshot.source -cne 'windows-chatgpt-desktop' -or $snapshot.source -isnot [string] -or
            $snapshot.epoch -isnot [long] -or $snapshot.epoch -lt 1 -or
            $snapshot.sequence -isnot [long] -or $snapshot.sequence -lt 1 -or
            $snapshot.observedAt -isnot [string] -or
            $snapshot.observedAt -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?Z\z' -or
            $snapshot.pending -isnot [array] -or $snapshot.pending.Count -gt 128) { throw 'Invalid snapshot format.' }
        $observed = [datetimeoffset]::Parse($snapshot.observedAt, [CultureInfo]::InvariantCulture)
        if ($observed -lt $Now.AddSeconds(-10) -or $observed -gt $Now.AddSeconds(2)) { throw 'Snapshot is not current.' }
        if ($snapshot.epoch -lt $Feed.Epoch -or
            ($snapshot.epoch -eq $Feed.Epoch -and $snapshot.sequence -lt $Feed.Sequence) -or
            $observed -lt $Feed.ObservedAt) { throw 'Snapshot moves backward.' }
        $scopeEvent = @{ Source='Codex'; ConnectionId='windows-chatgpt-desktop'; Epoch=$snapshot.epoch; Sequence=$snapshot.sequence }
        $scope = Get-ConnectionKey $scopeEvent
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $requests = foreach ($row in $snapshot.pending) {
            if (!(Test-CodexDesktopFields $row @('threadId','requestId','kind')) -or
                $row.threadId -isnot [string] -or
                $row.threadId -cnotmatch '\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z' -or
                $row.threadId -ceq '00000000-0000-0000-0000-000000000000' -or
                $row.requestId -isnot [string] -or $row.requestId -cnotmatch '\A[A-Za-z0-9._:-]{1,128}\z' -or
                $row.kind -isnot [string] -or $row.kind -cnotin 'input','approval') { throw 'Invalid request metadata.' }
            $stage = if ($row.kind -ceq 'input') { '等待输入' } else { '等待审批' }
            $kind = if ($row.kind -ceq 'input') { 'InputRequested' } else { 'ApprovalRequested' }
            $event = $scopeEvent + @{
                TaskId=$row.threadId; Id="$($snapshot.epoch):$($row.requestId)"; At=$observed
                Kind=$kind; Stage=$stage; Name="桌面会话 $($row.threadId.Substring(0,8))…$($row.threadId.Substring(32,4))"
            }
            $key = Get-ReminderKey $event
            if (!$keys.Add($key) -or $State.Resolved.ContainsKey($key)) { throw 'Duplicate or already-resolved request.' }
            if ($State.Waiting.ContainsKey($key) -and $State.Waiting[$key].Event.Kind -cne $kind) {
                throw 'A request cannot change kind.'
            }
            $event
        }
        $previous = @($State.Waiting.GetEnumerator() | Where-Object { $_.Value.Scope -ceq $scope })
        $sameSet = $previous.Count -eq $keys.Count
        if ($sameSet) {
            foreach ($entry in $previous) {
                if (!$keys.Contains($entry.Key)) { $sameSet = $false; break }
            }
        }
        if ($snapshot.epoch -eq $Feed.Epoch -and $snapshot.sequence -eq $Feed.Sequence) {
            if ($observed -ne $Feed.ObservedAt -or !$sameSet) { throw 'A snapshot sequence must not be changed.' }
            return $false
        }
        $changed = $Feed.Status -cne 'Current' -or !$sameSet
        $connection = @{ Epoch=$snapshot.epoch; Status='Pending'; Floor=[long]0 }
        $scopeEvent.PendingRequests = @($requests | Where-Object { $null -ne $_ })
        Restore-ReminderConnection $State $connection $scopeEvent $scope
        $State.Connections[$scope] = $connection
        $Feed.Epoch = $snapshot.epoch
        $Feed.Sequence = $snapshot.sequence
        $Feed.ObservedAt = $observed
        $Feed.Status = 'Current'
        return $changed
    } catch {
        return (Set-CodexDesktopUnavailable $State $Feed)
    }
}

function Resolve-CodexDesktopTarget($Event, $State, $Feed, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (!$Event -or !$Feed -or $Feed.Status -cne 'Current' -or $Feed.ObservedAt -lt $Now.AddSeconds(-10) -or
        $Event.Source -cne 'Codex' -or $Event.ConnectionId -cne 'windows-chatgpt-desktop' -or
        $Event.Epoch -ne $Feed.Epoch -or
        $Event.TaskId -cnotmatch '\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z') { return }
    $row = $State.Waiting[(Get-ReminderKey $Event)]
    if (!$row -or $row.PendingConfirmation) { return }
    "codex://threads/$($Event.TaskId)"
}

function Get-CodexDesktopCountCaption($Feed, [int]$Waiting) {
    # Schema 1 covers waiting input/approval only, never completed work to review.
    if ($Feed -and $Feed.Status -ceq 'Current') { return "等我 $Waiting｜待看 —" }
    '等我 —｜待看 —'
}
