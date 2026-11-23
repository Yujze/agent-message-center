# Expanded HUD selectors share the same source-neutral snapshot and page sequence.
function Get-VisibleSessions([datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $span = [int64]$localView.Days * 86400000
    $cutoff = $Now.ToUnixTimeMilliseconds() - $span
    $localView.NextExpiry = [datetime]::MaxValue
    foreach ($row in $localView.Rows) {
        if ($localView.Agent -ne '所有 Agent' -and $row.agent -ne $localView.Agent) { continue }
        if ($span) {
            if (!$row.activity -or $row.activity -lt $cutoff) { continue }
            $expires = [datetimeoffset]::FromUnixTimeMilliseconds([long]$row.activity + $span + 1).UtcDateTime
            if ($expires -lt $localView.NextExpiry) { $localView.NextExpiry = $expires }
        }
        $row
    }
}

function Get-SessionGroups($Rows,$AttentionLabels) {
    $sort=[string]$localView.Sort
    $ordered=$Rows | Sort-Object -Property @{Expression={ $AttentionLabels["$($_.agent)/$($_.id)"] -ceq '完成未读' };Descending=$true},
        @{Expression={[int64]$_[$sort]};Descending=$true}, @{Expression={[int64]$_.created};Descending=$true},
        @{Expression={$_.agent}}, @{Expression={$_.id}}
    $roots=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($session in $localView.Rows) {
        if ($session.agent -ceq 'Codex' -and !$session.parentId) { $roots[$session.id]=$session }
    }
    $byKey=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $groups=[Collections.Generic.List[object]]::new()
    foreach ($session in $ordered) {
        $side=$session.agent -ceq 'Codex' -and $session.parentId -and $session.rootId -and $roots.ContainsKey($session.rootId)
        $head=if ($side) { $roots[$session.rootId] } else { $session }
        $key="$($head.agent)/$($head.id)"
        $g=$null
        if (!$byKey.TryGetValue($key,[ref]$g)) {
            $g=@{ Head=$head; Matched=$false; Children=[Collections.Generic.List[object]]::new()
                Waiting=0; Unread=0; Running=0; Priority=$false }
            $byKey.Add($key,$g); $groups.Add($g)
        }
        $label=$AttentionLabels["$($session.agent)/$($session.id)"]
        if ($label -ceq '完成未读') { $g.Priority=$true }
        if ($side) {
            $g.Children.Add($session)
            if ($label -ceq '待输入') { $g.Waiting++ }
            elseif ($label -ceq '完成未读') { $g.Unread++ }
            elseif ($session.turn -ceq 'inProgress') { $g.Running++ }
        } else { $g.Matched=$true }
    }
    $groups
}

function Get-SessionPage($Groups) {
    foreach ($g in $Groups | Select-Object -Skip ($localView.Page*12) -First 12) {
        @{ Session=$g.Head; Group=$g; ContextOnly=!$g.Matched; Priority=$g.Priority }
        if ($g.Children.Count -and $localChrome.ExpandedGroups.Contains($g.Head.id)) {
            foreach ($child in $g.Children) { @{ Session=$child; Priority=$g.Priority } }
        }
    }
}

function Set-SessionSelection($Kind,$Value) {
    if ($localView[$Kind] -ceq $Value) { return }
    $localView[$Kind] = $Value
    $localView.Page = 0
    $list.AutoScrollPosition = [Drawing.Point]::Empty
    Update-ReminderWindow
}

function Initialize-SessionFilters {
    $localChrome.Rail = [JieShou.SegmentRail]::new()
    $localChrome.Band.Controls.Add($localChrome.Rail)
    $localChrome.Agents = @()
    foreach ($agent in '所有 Agent','Codex','DSH','Qoder') {
        $button = [JieShou.HudButton]::new()
        $button.Tag = $agent
        $button.Name = "agent-$agent"
        $button.Text = $agent
        if ($agent -eq '所有 Agent') { $button.Glyph = 'All' }
        $button.AccessibleName = "来源 $agent"
        if ($agent -eq 'DSH') {
            $hudTips.SetToolTip($button,'DSH 桌面消息时间包含工具结果。')
        }
        $button.Add_Click({ Set-SessionSelection 'Agent' $this.Tag })
        $button.Add_PreviewKeyDown({
            if ($_.KeyCode -in 'Left','Right','Home','End') { $_.IsInputKey = $true }
        })
        $button.Add_KeyDown({
            $tabs = $localChrome.Agents
            $i = [array]::IndexOf($tabs,$this)
            $next = switch ($_.KeyCode) {
                Left  { ($i + $tabs.Count - 1) % $tabs.Count }
                Right { ($i + 1) % $tabs.Count }
                Home  { 0 }
                End   { $tabs.Count-1 }
                default { return }
            }
            $_.SuppressKeyPress = $true
            [void]$tabs[$next].Focus()
            $tabs[$next].PerformClick()
        })
        $localChrome.Agents += $button
    }
    $localChrome.Range = [JieShou.HudButton]::new()
    $localChrome.Range.Name = 'session-range'
    $localChrome.Sort = [JieShou.HudButton]::new()
    $localChrome.Sort.Name = 'session-sort'
    $localChrome.Range.Glyph = 'Clock'
    $localChrome.Sort.Glyph = 'Sort'
    foreach ($button in $localChrome.Range,$localChrome.Sort) {
        $button.MenuArrow = $true
        $popup = [JieShou.HudChoiceMenu]::new($windowComponents,$button)
        $choices = if ($button -eq $localChrome.Range) {
            [ordered]@{'近 24 小时'=1;'近 7 天'=7;'全部时间'=0}
        } else { [ordered]@{'最近消息'='message';'最新创建'='created'} }
        foreach ($label in $choices.Keys) {
            $item = $popup.AddChoice($label)
            $key = if ($button -eq $localChrome.Range) { 'Days' } else { 'Sort' }
            $item.Tag = @($key,$choices[$label])
            $item.Add_Click({ Set-SessionSelection $this.Tag[0] $this.Tag[1] })
        }
        $button.ContextMenuStrip = $popup
        $button.Add_Click({ $this.ContextMenuStrip.ShowForTrigger() })
    }
    foreach ($b in ($localChrome.Agents + @($localChrome.Range,$localChrome.Sort))) {
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.UseVisualStyleBackColor = $false
        $b.Cursor = [Windows.Forms.Cursors]::Hand
        if ($b -in $localChrome.Agents) { $localChrome.Rail.Controls.Add($b) } else { $window.Controls.Add($b) }
    }
}

function Set-SessionFilterLayout($Left,$Top,$Width) {
    $inset = Get-HudPixels 3
    $rail = $localChrome.Rail
    $rail.SetBounds($Left,$Top,$Width,(Get-HudPixels ($appearance.Size+24)))
    $rail.BackColor = $hudColors.Chrome
    $rail.Track = $hudColors.Track
    $rail.Radius = Get-HudPixels 10
    $rail.Invalidate()
    $room = $Width-2*$inset
    $x = $inset
    for ($i=0; $i -lt $localChrome.Agents.Count; $i++) {
        $b = $localChrome.Agents[$i]
        $w = if ($i -eq 0) { [int]($room*0.31) } elseif ($i -eq 3) { $Width-$inset-$x } else { [int]($room*0.23) }
        $b.SetBounds($x,$inset,$w,($rail.Height-2*$inset))
        $b.LayoutDpi = $localDpi
        $b.Palette = $hudColors
        $b.Font = $hudFonts.Body
        $b.Selected = $b.Tag -eq $localView.Agent
        $b.BackColor = $hudColors.Track
        $b.ForeColor = if ($b.Selected) { $hudColors.Ink } else { $hudColors.Muted }
        $b.Image = if ($b.Tag -eq 'Qoder') {
            if ($appearance.Theme -eq '云白') { $agentIcons['qoder-light'] } else { $agentIcons['qoder-dark'] }
        } else { $agentIcons[$b.Tag] }
        $b.AccessibleDescription = if ($b.Selected) { '已选中' } else { '切换来源' }
        $b.Invalidate()
        $x += $w
    }
    foreach ($b in $localChrome.Range,$localChrome.Sort) {
        $b.Font = $hudFonts.Small
        $b.BackColor = $hudColors.Surface
        $b.ForeColor = $hudColors.Muted
        foreach ($item in $b.ContextMenuStrip.Items) {
            $item.Checked = $localView[$item.Tag[0]] -eq $item.Tag[1]
            if ($item.Checked) {
                $prefix = if ($b -eq $localChrome.Range) { '活动' } else { '排序' }
                $b.Text = $item.Text
                $b.AccessibleName = "$prefix $($item.Text)"
            }
        }
    }
    return $rail.Bottom + (Get-HudPixels 11)
}
