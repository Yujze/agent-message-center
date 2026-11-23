function New-ReminderState {
    @{
        Waiting = [hashtable]::new([StringComparer]::Ordinal)
        Resolved = [hashtable]::new([StringComparer]::Ordinal)
        Review = [hashtable]::new([StringComparer]::Ordinal)
        Read = [hashtable]::new([StringComparer]::Ordinal)
        Connections = [hashtable]::new([StringComparer]::Ordinal)
    }
}

function Get-ConnectionKey($Event) {
    '{0}:{1}{2}' -f $Event.Source.Length, $Event.Source, $Event.ConnectionId
}

function Get-ReminderKey($Event) {
    # Length-prefix variable fields so punctuation in an identifier cannot change its scope.
    '{0}:{1}{2}:{3}{4}:{5}{6}' -f $Event.Source.Length, $Event.Source,
        $Event.ConnectionId.Length, $Event.ConnectionId, $Event.TaskId.Length, $Event.TaskId, $Event.Id
}

function Test-RequestIdentity($Event) {
    ![string]::IsNullOrWhiteSpace($Event.TaskId) -and ![string]::IsNullOrWhiteSpace($Event.Id)
}

function Set-ConnectionWaitingUnconfirmed($State, [string]$Scope) {
    foreach ($row in $State.Waiting.Values) {
        if ($row.Scope -ceq $Scope) { $row.PendingConfirmation = $true }
    }
}

function Restore-ReminderConnection($State, $Connection, $Event, [string]$Scope) {
    # A snapshot must contain the complete, verified pending set for this connection and epoch.
    if ($null -eq $Event.PendingRequests) { return }
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($request in $Event.PendingRequests) {
        if (!(Test-RequestIdentity $request) -or (Get-ConnectionKey $request) -cne $Scope -or
            $request.Epoch -ne $Event.Epoch -or $request.Sequence -ne $Event.Sequence -or
            $request.Kind -notin 'InputRequested', 'ApprovalRequested') { return }
        $key = Get-ReminderKey $request
        if (!$keys.Add($key) -or $State.Resolved.ContainsKey($key)) { return }
    }
    foreach ($key in @($State.Waiting.Keys)) {
        if ($State.Waiting[$key].Scope -ceq $Scope -and !$keys.Contains($key)) {
            $State.Resolved[$key] = $true
            $State.Waiting.Remove($key)
        }
    }
    foreach ($request in $Event.PendingRequests) {
        $key = Get-ReminderKey $request
        $old = $State.Waiting[$key]
        $State.Waiting[$key] = @{
            Event = $request; Scope = $Scope; Pinned = [bool]$old.Pinned
            PendingConfirmation = $false
            At = if ($old) { $old.At } else { $request.At }
        }
    }
    $Connection.Status = 'Current'
    $Connection.Floor = $Event.Sequence
}

function Add-ReminderEvent($State, $Event) {
    if ([string]::IsNullOrWhiteSpace($Event.Source) -or [string]::IsNullOrWhiteSpace($Event.ConnectionId) -or
        $Event.Epoch -lt 1 -or $Event.Sequence -lt 1) { return }

    $scope = Get-ConnectionKey $Event
    $connection = $State.Connections[$scope]
    if (!$connection) {
        if ($Event.Kind -eq 'ConnectionReconciled') { return }
        $connection = @{ Status = 'Current'; Epoch = $Event.Epoch; Floor = 0 }
        $State.Connections[$scope] = $connection
    }
    if ($Event.Kind -eq 'ConnectionOpened') {
        if ($Event.Epoch -gt $connection.Epoch) {
            $connection.Epoch = $Event.Epoch
            $connection.Status = 'Pending'
            $connection.Floor = $Event.Sequence
            Set-ConnectionWaitingUnconfirmed $State $scope
        }
        return
    }
    if ($Event.Epoch -ne $connection.Epoch -or $Event.Sequence -le $connection.Floor) { return }
    switch ($Event.Kind) {
        'Disconnected' {
            $connection.Status = 'Disconnected'
            $connection.Floor = $Event.Sequence
            Set-ConnectionWaitingUnconfirmed $State $scope
            return
        }
        'ConnectionReconciled' {
            if ($connection.Status -eq 'Pending') {
                Restore-ReminderConnection $State $connection $Event $scope
            }
            return
        }
    }
    if ($connection.Status -ne 'Current' -or !(Test-RequestIdentity $Event)) { return }
    $key = Get-ReminderKey $Event
    switch ($Event.Kind) {
        { $_ -in 'InputRequested', 'ApprovalRequested' } {
            if (!$State.Resolved.ContainsKey($key) -and !$State.Waiting.ContainsKey($key)) {
                $State.Waiting[$key] = @{
                    Event = $Event; Pinned = $false; Scope = $scope
                    PendingConfirmation = $false; At = $Event.At
                }
            }
        }
        'RequestResolved' {
            $row = $State.Waiting[$key]
            if ($row -and $Event.Sequence -le $row.Event.Sequence) { return }
            $State.Resolved[$key] = $true
            $State.Waiting.Remove($key)
        }
        { $_ -in 'ReviewRequested', 'NextStepProvided' } {
            if (($Event.Kind -eq 'ReviewRequested' -or ![string]::IsNullOrWhiteSpace($Event.NextStep)) -and
                !$State.Read.ContainsKey($key) -and !$State.Review.ContainsKey($key)) {
                $State.Review[$key] = @{ Event = $Event; Pinned = $false; At = $Event.At }
            }
        }
    }
}

function Get-ReminderNextStep($Event) {
    if (![string]::IsNullOrWhiteSpace($Event.NextStep)) { return $Event.NextStep }
    switch ($Event.Kind) {
        'InputRequested' { '查看输入请求' }
        'ApprovalRequested' { '查看审批请求' }
        'ReviewRequested' { '评审任务结果' }
    }
}

function Set-ReminderPinned($State, [string]$Key) {
    if ($State.Waiting.ContainsKey($Key) -and !$State.Waiting[$Key].PendingConfirmation) {
        $State.Waiting[$Key].Pinned = !$State.Waiting[$Key].Pinned
    }
}

function Set-ReminderRead($State, [string]$Key) {
    if ($State.Review.ContainsKey($Key)) {
        $State.Read[$Key] = $true
        $State.Review.Remove($Key)
    }
}

function Get-ReminderRows($Group) {
    $Group.Values | Sort-Object -Property @(
        @{ Expression = { $_.Pinned }; Descending = $true }
        @{ Expression = { $_.At } }
        @{ Expression = { $_.Event.Source } }
        @{ Expression = { $_.Event.ConnectionId } }
        @{ Expression = { $_.Event.TaskId } }
        @{ Expression = { $_.Event.Id } }
    )
}

function Get-ReminderWaiting($State, [switch]$Pending) {
    Get-ReminderRows $State.Waiting | Where-Object { $_.PendingConfirmation -eq [bool]$Pending }
}

function Get-MockTasks {
    @{
        'codex-blank-01' = @{ Source = 'Codex'; Name = '空白任务 A'; Target = 'mock://codex/task/codex-blank-01' }
        'qoder-blank-02' = @{ Source = 'Qoder'; Name = '空白任务 B'; Target = 'mock://qoder/task/qoder-blank-02' }
        'dsh-blank-03' = @{ Source = 'DSH'; Name = '空白任务 C'; Target = 'mock://dsh/task/dsh-blank-03' }
    }
}

function New-MockEvent([string]$TaskId, [string]$Id, [string]$Kind, [string]$Stage, [string]$NextStep,
    [datetimeoffset]$At = [datetimeoffset]::Now, [int]$Epoch = 1, [int]$Sequence = 1) {
    $task = (Get-MockTasks)[$TaskId]
    @{
        TaskId = $TaskId; Source = $task.Source; Name = $task.Name
        Id = $Id; Kind = $Kind; Stage = $Stage; NextStep = $NextStep
        At = $At; Target = $task.Target
        ConnectionId = 'mock-desktop'; Epoch = $Epoch; Sequence = $Sequence
    }
}

function Resolve-MockTarget($Event) {
    if (!$Event.TaskId) { return }
    $task = (Get-MockTasks)[$Event.TaskId]
    if ($task -and $task.Source -ceq $Event.Source -and $task.Target -ceq $Event.Target -and
        $Event.ConnectionId -ceq 'mock-desktop') {
        [pscustomobject]@{ Id = $Event.TaskId; Name = $task.Name; Target = $task.Target }
    }
}
