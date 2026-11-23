# Read desktop session metadata outside the UI thread.
function Stop-LocalSessionRead {
    if ($localView.Reader) {
        try { if (!$localView.Reader.HasExited) { $localView.Reader.Kill() } }
        finally { $localView.Reader.Dispose(); $localView.Reader = $null }
    }
}

function Update-QoderAttention {
    if ($UiTest) { return }
    $now = [datetime]::UtcNow
    $scan = $localView.QoderScan
    $ids = $localView.QoderWaiting
    if ($scan -and $scan.IsCompleted) {
        try {
            $ids = $scan.GetAwaiter().GetResult()
            if ($now -gt $localView.QoderScanStarted.AddSeconds(8)) { $ids = @() }
        } catch { $ids = @() }
        $localView.QoderScan = $null
    } elseif ($scan -and $now -gt $localView.QoderScanStarted.AddSeconds(8)) {
        $ids = @()
    }
    if (($ids -join ',') -cne ($localView.QoderWaiting -join ',')) {
        $localView.QoderWaiting = $ids
        Update-ReminderWindow
    }
    if (!$localView.QoderScan -and (!$localView.QoderScanStarted -or $now -ge $localView.QoderScanStarted.AddSeconds(4))) {
        $localView.QoderScanStarted = $now
        $localView.QoderScan = [JieShou.QoderAttention]::ReadAsync()
    }
}

function Update-DshAttention {
    if ($UiTest) { return }
    $now = [datetime]::UtcNow
    $scan = $localView.DshScan
    $badges = $localView.DshBadges
    if ($scan -and $scan.IsCompleted) {
        try { $badges = $scan.GetAwaiter().GetResult() } catch { $badges = $null }
        if ($now -gt $localView.DshScanStarted.AddSeconds(8)) { $badges = $null }
        $localView.DshScan = $null
    } elseif ($scan -and $now -gt $localView.DshScanStarted.AddSeconds(8)) {
        $badges = $null
    }
    $changed = $badges.Count -ne $localView.DshBadges.Count
    if (!$changed -and $badges) {
        foreach ($title in $badges.Keys) {
            if ($badges[$title] -cne $localView.DshBadges[$title]) { $changed = $true; break }
        }
    }
    $localView.DshBadges = $badges
    if ($changed) { Update-ReminderWindow }
    if (!$localView.DshScan -and (!$localView.DshScanStarted -or $now -ge $localView.DshScanStarted.AddSeconds(4))) {
        $titles = [string[]]@($localView.Rows | Where-Object { $_.agent -ceq 'DSH' -and $_.desktopTitle } | ForEach-Object { $_.desktopTitle })
        $localView.DshScanStarted = $now
        if ($titles.Length) { $localView.DshScan = [JieShou.DshSidebar]::ReadAsync($titles) }
        elseif ($localView.DshBadges.Count) { $localView.DshBadges = $null; Update-ReminderWindow }
    }
}

function Start-LocalSessionRetry {
    # Hold the previous verified snapshot for one quick retry while a desktop app rewrites its index.
    if ($localView.Status -ne 'Ready' -or $localView.RetryingRead) { return $false }
    $localView.RetryingRead=$true
    Stop-LocalSessionRead
    $localView.NextRead=[datetime]::UtcNow.AddMilliseconds(650)
    return $true
}

function Update-LocalSessionList {
    $now = [datetime]::UtcNow
    if ($localView.Status -eq 'Ready' -and $now -ge $localView.NextExpiry) { Update-ReminderWindow }
    if (!$localView.Reader -and $now -lt $localView.NextRead) { return }
    try {
        if (!$localView.Reader) {
            $python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            $info = [Diagnostics.ProcessStartInfo]::new($python)
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($arg in @('-I', '-S', '-B', "$PSScriptRoot/codex_local_sessions.py")) {
                $info.ArgumentList.Add($arg)
            }
            if ($UiTest) { $info.ArgumentList.Add('--fixture') }
            $localView.Reader = [Diagnostics.Process]::Start($info)
            $localView.Output = $localView.Reader.StandardOutput.ReadToEndAsync()
            $localView.ErrorOutput = $localView.Reader.StandardError.ReadToEndAsync()
            $localView.Started = $now
            return
        }
        if (!$localView.Reader.HasExited -or !$localView.Output.IsCompleted -or !$localView.ErrorOutput.IsCompleted) {
            if (($now - $localView.Started).TotalSeconds -gt 5) { throw 'Read timeout' }
            return
        }
        if ($localView.Reader.ExitCode -ne 0) { throw 'Index unavailable' }
        $json = $localView.Output.GetAwaiter().GetResult()
        if ($json -ceq $localView.LastJson -and $localView.Status -ne 'Loading') {
            Stop-LocalSessionRead
            $localView.NextRead = $now.AddSeconds(4)
            $localView.RetryingRead=$false
            return
        }
        $data = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
        if ($data.sessions -isnot [array] -or $null -eq $data.summary.total) { throw 'Invalid session snapshot' }
        $nextStatus = if ($data.sources.Values -contains 'ready' -or $data.sources.Values -contains 'partial') { 'Ready' } else { 'Unavailable' }
        foreach ($agent in $data.sources.Keys) {
            $previous=$localView.Sources[$agent]
            $current=$data.sources[$agent]
            if (($previous -eq 'ready' -and $current -ne 'ready') -or
                ($previous -eq 'partial' -and $current -in 'missing','unavailable')) {
                if (Start-LocalSessionRetry) { return }
                break
            }
        }
        $changed = $localView.Status -ne $nextStatus -or $localView.LastJson -cne $json
        $localView.Sources = $data.sources
        $localView.Rows = $data.sessions
        $localView.LastJson = $json
        $localView.Status = $nextStatus
    } catch {
        if (Start-LocalSessionRetry) { return }
        $changed = $localView.Status -ne 'Unavailable'
        $localView.Status = 'Unavailable'
        $localView.Rows = @()
        $localView.LastJson = ''
    }
    Stop-LocalSessionRead
    $localView.RetryingRead=$false
    $localView.NextRead = $now.AddSeconds(4)
    if ($changed) { Update-ReminderWindow }
}

function Get-LocalCodexUri([string]$Id) {
    if ($localView.Status -ne 'Ready' -or $Id -cnotmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z') { return }
    $row=$localView.Rows | Where-Object { $_.agent -ceq 'Codex' -and $_.id -ceq $Id } | Select-Object -First 1
    if (!$row -or !(Test-LocalSessionCanOpen $row)) { return }
    $target=$row.id
    if ($row.parentId) {
        $target=$row.rootId
        if (!($localView.Rows | Where-Object { $_.agent -ceq 'Codex' -and $_.id -ceq $target -and !$_.parentId })) { return }
    }
    "codex://threads/$target"
}

function Test-LocalSessionCanOpen($Row) {
    switch -CaseSensitive ($Row.agent) {
        Codex {
            if (!$Row.parentId) { return $Row.id -cmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z' }
            return $Row.rootId -cmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z' -and $Row.rootId -cne $Row.id
        }
        DSH { return $true }
        Qoder { return $Row.desktop -and $Row.id -cmatch '\A[a-zA-Z0-9_-]{1,128}\z' }
        default { return $false }
    }
}

function Get-CodexSelectionTarget($Side) {
    $rows = @($localView.Rows | Where-Object { $_.agent -ceq 'Codex' })
    $byId = @{}
    foreach ($row in $rows) { $byId[$row.id] = $row }
    $chain = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new()
    $cursor = $Side
    while ($cursor -and $cursor.parentId -and $seen.Add($cursor.id)) {
        $title = [string]($cursor.desktopTitle ?? $cursor.name)
        $siblings = @($rows | Where-Object {
            $_.parentId -ceq $cursor.parentId -and [string]::Equals(($_.desktopTitle ?? $_.name),$title,[StringComparison]::Ordinal)
        })
        if ([string]::IsNullOrWhiteSpace($title)) { return @{Notice='已打开主会话，侧聊还没有标题。'} }
        if ($siblings.Count -ne 1) { return @{Notice='已打开主会话，同一主会话内有同名侧聊，请手动选择。'} }
        $sameTitle = @($rows | Where-Object {
            $_.rootId -ceq $Side.rootId -and [string]::Equals(($_.desktopTitle ?? $_.name),$title,[StringComparison]::Ordinal)
        })
        $main = $byId[$Side.rootId]
        $sameAsMain = $main -and [string]::Equals(($main.desktopTitle ?? $main.name),$title,[StringComparison]::Ordinal)
        $chain.Insert(0,@{id=$cursor.id; title=$title; reuse=($sameTitle.Count -eq 1 -and !$sameAsMain)})
        $cursor = $byId[$cursor.parentId]
    }
    if (!$cursor -or $cursor.parentId -or $cursor.id -cne $Side.rootId) { return @{Notice='侧聊的归属已变化，请刷新后重试。'} }
    $rootTitle = [string]($cursor.desktopTitle ?? $cursor.name)
    $roots = @($rows | Where-Object { !$_.parentId -and [string]::Equals(($_.desktopTitle ?? $_.name),$rootTitle,[StringComparison]::Ordinal) })
    if ([string]::IsNullOrWhiteSpace($rootTitle) -or $roots.Count -ne 1) { return @{Notice='已打开主会话，无法通过窗口标题确认侧聊归属。'} }
    return @{Worker='Codex'; Payload=@{rootId=$cursor.id; rootTitle=$rootTitle; steps=$chain.ToArray()}}
}

function Get-LocalNavigationTarget([string]$Agent, [string]$Id) {
    if ($localView.Status -ne 'Ready' -or !$Id) { return }
    $row = $localView.Rows | Where-Object { $_.agent -ceq $Agent -and $_.id -ceq $Id } | Select-Object -First 1
    if (!$row -or !(Test-LocalSessionCanOpen $row)) { return }
    switch -CaseSensitive ($Agent) {
        Codex {
            $uri = Get-LocalCodexUri $Id
            if (!$uri) { return }
            $target = @{Uri=$uri}
            if ($row.parentId) { $target += Get-CodexSelectionTarget $row }
            return $target
        }
        Qoder { return @{ Uri="qoder://chat/open?sessionId=$Id" } }
        DSH {
            $title = $row.desktopTitle
            $matches = @($localView.Rows | Where-Object { $_.agent -ceq 'DSH' -and [string]::Equals($_.desktopTitle,$title,[StringComparison]::Ordinal) })
            return @{ Uri='dsh://open'; Title=$title; Unique=(![string]::IsNullOrWhiteSpace($title) -and $matches.Count -eq 1) }
        }
    }
}

function Show-LocalNavigationNotice([string]$Text) {
    $hudTips.Show($Text,$window,[Drawing.Point]::new(8,[Math]::Max(0,$window.ClientSize.Height-16)),5000)
}

function Stop-LocalNavigation {
    $worker = $localView.Navigation
    try {
        if ($localView.NavigationCancel) { [void]$localView.NavigationCancel.Set() }
        if ($worker -and !$worker.HasExited -and !$worker.WaitForExit(400)) { $worker.Kill() }
    } finally {
        if ($worker) { $worker.Dispose(); $localView.Navigation = $null }
        if ($localView.NavigationCancel) { $localView.NavigationCancel.Dispose(); $localView.NavigationCancel = $null }
    }
}

function Update-LocalNavigation {
    $worker = $localView.Navigation
    if (!$worker) { return }
    if (!$worker.HasExited -and [datetime]::UtcNow -lt $localView.NavigationDeadline) { return }
    try {
        $result = if ($worker.HasExited -and $worker.ExitCode -eq 0) { $worker.StandardOutput.ReadToEnd().Trim() }
        if ($result -ne 'selected' -and $result -ne 'cancelled') { Show-LocalNavigationNotice $localView.NavigationFallback }
    } finally { Stop-LocalNavigation }
}

function Open-LocalHudSession([string]$Agent, [string]$Id) {
    $target = Get-LocalNavigationTarget $Agent $Id
    if (!$target) { Show-LocalNavigationNotice '此会话已不可用，请刷新后重试。'; return }
    Stop-LocalNavigation
    try {
        Start-ReminderUri $target.Uri
    } catch { Show-LocalNavigationNotice "Windows 无法打开 $Agent。"; return }
    if ($target.Notice) { Show-LocalNavigationNotice $target.Notice; return }
    if ($target.Worker -eq 'Codex') {
        Start-LocalNavigationWorker 'Codex' $target.Payload '主会话已打开，未能确认目标侧聊，请在「侧边聊天」中选择。'
    } elseif ($Agent -ceq 'DSH') {
        if (!$target.Unique) { Show-LocalNavigationNotice '这条 DSH 会话缺少唯一标题，请在应用中选择。'; return }
        $catalog = @($localView.Rows | Where-Object { $_.agent -ceq 'DSH' -and $_.desktopTitle } | ForEach-Object { $_.desktopTitle })
        Start-LocalNavigationWorker 'Dsh' @{title=$target.Title;titles=$catalog} 'DSH 未能定位这条会话，请在侧栏选择。'
    }
}

function Start-LocalNavigationWorker([ValidateSet('Codex','Dsh')][string]$Kind, $Payload, [string]$Fallback) {
    $localView.NavigationFallback = $Fallback
    try {
        $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $info.RedirectStandardOutput = $true
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $cancelName = 'Local\DaiWoJieShou.Nav.' + [guid]::NewGuid().ToString('N')
        $localView.NavigationCancel = [Threading.EventWaitHandle]::new($false, 'ManualReset', $cancelName)
        foreach ($arg in '-NoProfile','-NonInteractive','-MTA','-File',"$PSScriptRoot/Reminder.${Kind}Navigation.ps1",'-CancelEvent',$cancelName) { $info.ArgumentList.Add($arg) }
        $localView.Navigation = [Diagnostics.Process]::Start($info)
        $localView.NavigationDeadline = [datetime]::UtcNow.AddSeconds(14)
        $localView.Navigation.StandardInput.Write((ConvertTo-Json -InputObject $Payload -Depth 6 -Compress))
        $localView.Navigation.StandardInput.Close()
    } catch {
        Stop-LocalNavigation
        Show-LocalNavigationNotice $Fallback
    }
}
