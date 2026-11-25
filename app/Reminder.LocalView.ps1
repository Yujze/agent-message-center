function Get-HudPixels([double]$Value) {
    [int][Math]::Round($Value * $localDpi / 96.0)
}

function Set-LocalHudTypeScale([int]$Dpi) {
    $fontKey = "$Dpi|$($appearance.Size)|$($appearance.Family)"
    if ($fontKey -ceq $hudFontKey) { return }
    $script:hudFontKey = $fontKey
    $script:localDpi = $Dpi
    $previous = $hudFonts
    $family = $appearance.Family
    $size = $appearance.Size
    $pixels = [Drawing.GraphicsUnit]::Pixel
    $script:hudFonts = @{
        Title = [Drawing.Font]::new($family,[single](($size+3)*$Dpi/96),[Drawing.FontStyle]::Bold,$pixels)
        Name = [Drawing.Font]::new($family,[single]($size*$Dpi/96),[Drawing.FontStyle]::Bold,$pixels)
        Body = [Drawing.Font]::new($family,[single](($size-1)*$Dpi/96),[Drawing.FontStyle]::Regular,$pixels)
        Small = [Drawing.Font]::new($family,[single]([Math]::Max(11,$size-2.5)*$Dpi/96),[Drawing.FontStyle]::Regular,$pixels)
    }
    $header.Font = $hudFonts.Title
    foreach ($c in $localChrome.Toggle,$localChrome.Settings,$localChrome.Prev,$localChrome.Next,$localChrome.Section,$localChrome.AllSessions) { $c.Font = $hudFonts.Body }
    foreach ($b in $localChrome.Toggle,$localChrome.Settings,$localChrome.Range,$localChrome.Sort,$localChrome.Prev,$localChrome.Next,$localChrome.AllSessions) { $b.LayoutDpi = $Dpi }
    $localChrome.Section.Font = $hudFonts.Name
    foreach ($tab in $localChrome.ReminderFilters) { $tab.Font=$hudFonts.Body; $tab.LayoutDpi=$Dpi }
    $localChrome.Notice.Font = $localChrome.PageLabel.Font = $hudFonts.Small
    if ($previous) { foreach ($font in $previous.Values) { $font.Dispose() } }
}

function Set-HudAppearance {
    $script:hudColors = [JieShou.HudColors]::new($appearance)
    $localChrome.FilterLayout=$null
    $window.BackColor = $hudColors.Surface
    $list.BackColor = $hudColors.Surface
    $localScrollBar.Palette = $hudColors
    foreach ($c in $localChrome.Band,$header,$localChrome.Settings,$localChrome.Toggle) {
        $c.BackColor = $hudColors.Chrome; $c.ForeColor = $hudColors.Ink
    }
    $localChrome.Section.ForeColor = $hudColors.Muted
    foreach ($c in $localChrome.Prev,$localChrome.Next) {
        $c.BackColor = $hudColors.Surface; $c.ForeColor = $hudColors.Muted
    }
    $localChrome.PageLabel.ForeColor = $hudColors.Muted
    $localChrome.Notice.ForeColor = $hudColors.Muted
    foreach ($b in $localChrome.Toggle,$localChrome.Settings,$localChrome.Range,$localChrome.Sort,$localChrome.Prev,$localChrome.Next,$localChrome.AllSessions) {
        $b.Palette = $hudColors
        $b.Invalidate()
    }
    $localChrome.Pill.Appearance = $appearance
    $localChrome.Pill.Colors = $hudColors
    $localChrome.Pill.BackColor = $hudColors.End
}

function Complete-LocalHudDrag([Drawing.Point]$Release) {
    if (!$placement.Positioned -or $placement.Docked) { return }
    $target=[Windows.Forms.Screen]::FromPoint($Release)
    $previous=[JieShou.HudDock]::FromAnchor($placement.Anchor,$placement.Vertical)
    $dock=[JieShou.HudDock]::At($Release,$target.WorkingArea,$previous.Edge)
    $placement.Display=[JieShou.HudDisplayIds]::For($target.DeviceName)
    $placement.Anchor=$dock.Anchor
    $placement.Vertical=$dock.Vertical
    $placement.Docked=$true
    $placement.Positioned=$false
    $localChrome.ExpansionSource=$null
    Update-ReminderWindow
    if (!$appearance.RememberPosition) {
        if ($localChrome.AppearanceDialog) { $localChrome.AppearanceDialog.SetPositionSource($localChrome.Pill,$appearance.LastDrag,$dock) }
        return
    }
    $saved = [JieShou.HudDragPosition]::new()
    foreach ($key in 'Display','Right','Bottom','X','Y') { $saved.$key = $placement[$key] }
    $saved.DockSlot=$placement.Anchor
    $saved.Vertical=$placement.Vertical
    $appearance.LastDrag = $saved
    if ($localChrome.AppearanceDialog) { $localChrome.AppearanceDialog.SetPositionSource($localChrome.Pill,$saved,$dock) }
    try { $appearance.Save($appearancePath) }
    catch { Write-Warning "未能记住浮窗位置：$($_.Exception.Message)" }
}

function Show-HudAppearance {
    $localChrome.Surface.FinishReveal()
    $editor = $localChrome.AppearanceDialog
    if ($editor -and !$editor.IsDisposed) {
        $editor.FocusEditor()
        return
    }
    $version=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Raw -ErrorAction SilentlyContinue
    $editor = [JieShou.AppearanceDialog]::new($appearance,$localDpi,$agentIcons,$version)
    $editor.SetPositionSource($localChrome.Pill,$appearance.LastDrag,[JieShou.HudDock]::FromAnchor($placement.Anchor,$placement.Vertical))
    $localChrome.AppearanceDialog = $editor
    $localChrome.RestoreTopMost = $window.TopMost
    $editor.Add_FormClosing({
        param($sender,$e)
        if ($e.CloseReason -ne 'UserClosing' -or $sender.DialogResult -ne 'OK') { return }
        $sender.Selection.LastDrag = $appearance.LastDrag
        try { $sender.Selection.Save($appearancePath) }
        catch {
            $e.Cancel = $true
            $sender.DialogResult = 'None'
            $sender.ShowSaveError()
            return
        }
        if ($appearance.StartupDisplay -ne $sender.Selection.StartupDisplay -or
            !$appearance.StartupDock.Equals($sender.Selection.StartupDock) -or
            $appearance.RememberPosition -ne $sender.Selection.RememberPosition) {
            $script:placement = Get-ReminderStartupPlacement $sender.Selection
            $localChrome.ExpansionSource = $null
        }
        $script:appearance = $sender.Selection
        Set-HudAppearance
        Update-ReminderWindow
    })
    $editor.Add_FormClosed({
        $localChrome.AppearanceDialog = $null
        if (!$window.Disposing -and !$window.IsDisposed) {
            $window.TopMost = $localChrome.RestoreTopMost
            if ($appearance.AutoHide) { Update-ReminderWindow }
        }
    })
    try {
        # Keep the editor above the HUD even when background refreshes move the HUD.
        $window.TopMost = $false
        $editor.OpenBeside($window)
    } catch {
        $localChrome.AppearanceDialog = $null
        $window.TopMost = $localChrome.RestoreTopMost
        $editor.Dispose()
        throw
    }
}

function Initialize-LocalHudTypes {
    $refs = @([Windows.Forms.Form].Assembly.Location, [Windows.Forms.Message].Assembly.Location,
        [Drawing.Graphics].Assembly.Location)
    $refs += (Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName
    $refs += (Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) -Filter 'System.Private.Windows*.dll').FullName
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $refs += [Windows.Automation.AutomationElement].Assembly.Location, [Windows.Automation.ControlType].Assembly.Location
    Add-Type -Path "$PSScriptRoot/Reminder.HudGeometry.cs","$PSScriptRoot/Reminder.DisplayScale.cs","$PSScriptRoot/Reminder.HudControls.cs","$PSScriptRoot/Reminder.ChoiceMenu.cs","$PSScriptRoot/Reminder.LocalRow.cs","$PSScriptRoot/Reminder.SessionListPanel.cs","$PSScriptRoot/Reminder.Appearance.cs","$PSScriptRoot/Reminder.EdgeTabs.cs","$PSScriptRoot/Reminder.PillWindowSurface.cs","$PSScriptRoot/Reminder.PanelCorners.cs","$PSScriptRoot/Reminder.PanelReveal.cs","$PSScriptRoot/Reminder.OutsideClick.cs","$PSScriptRoot/Reminder.AppearanceDialog.cs","$PSScriptRoot/Reminder.AppearanceControls.cs","$PSScriptRoot/Reminder.QoderAttention.cs","$PSScriptRoot/Reminder.DshSidebar.cs","$PSScriptRoot/Reminder.ScrollBar.cs" -ReferencedAssemblies ($refs | Sort-Object -Unique)
}

function Initialize-LocalHudView {
    $script:appearancePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DaiWoJieShou/appearance.json'
    $script:appearance = if ($UiTest) { [JieShou.HudAppearance]::new() } else { [JieShou.HudAppearance]::Load($appearancePath) }
    $script:placement = Get-ReminderStartupPlacement $appearance
    # Assets are rasterized from the identically named SVGs in Token Monitor 0.96.1.
    # Qoder's currentColor layer follows the surface theme, preserving its fixed green.
    $script:agentIcons = @{}
    $brandIcon = [Drawing.Icon]::new("$PSScriptRoot/assets/amc-message-grip.ico",128,128)
    try { $agentIcons['amc']=$brandIcon.ToBitmap() } finally { $brandIcon.Dispose() }
    foreach ($name in 'codex','dsh','qoder-light','qoder-dark') {
        $stream = [IO.File]::OpenRead("$PSScriptRoot/assets/agent-icons/$name.png")
        try {
            $image = [Drawing.Image]::FromStream($stream)
            try { $agentIcons[$name] = [Drawing.Bitmap]::new($image) }
            finally { $image.Dispose() }
        } finally { $stream.Dispose() }
    }
    $window.AutoScaleMode = 'None'
    $window.BackColor = [Drawing.Color]::White
    $window.KeyPreview = $true
    $window.Add_KeyDown({
        if ($expanded -and $list.ContainsFocus -and $_.Modifiers -eq 'None' -and $localScrollBar.ScrollKey($_.KeyCode)) {
            $_.SuppressKeyPress = $true
            return
        }
        if ($_.KeyCode -eq 'Escape' -and $expanded) {
            $_.Handled = $true
            Switch-ReminderExpansion
        }
    })
    $script:hudTips = [Windows.Forms.ToolTip]::new()
    $script:localChrome = @{
        Band = [Windows.Forms.Panel]::new()
        Toggle = [JieShou.HudButton]::new()
        Settings = [JieShou.HudButton]::new()
        Pill = [JieShou.MetricPill]::new()
        Prev = [JieShou.HudButton]::new()
        Next = [JieShou.HudButton]::new()
        Section = [Windows.Forms.Label]::new()
        AllSessions = [JieShou.HudButton]::new()
        PageLabel = [Windows.Forms.Label]::new()
        Notice = [Windows.Forms.Label]::new()
    }
    $script:windowComponents = [ComponentModel.Container]::new()
    $localChrome.ExpandedGroups=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $localChrome.Rows = [Collections.Generic.Dictionary[string,Windows.Forms.Control]]::new([StringComparer]::Ordinal)
    $localChrome.Cards = [Collections.Generic.List[Windows.Forms.Control]]::new()
    $localChrome.ActivityAnimation = [JieShou.SessionActivityAnimation]::new($list,$windowComponents)
    Initialize-SessionFilters
    $band = $localChrome.Band
    $band.ContextMenuStrip = $menu
    $band.Add_Paint({
        param($sender,$e)
        if ($dragGrip.Parent -eq $sender) { $localChrome.Pill.DrawMessageGrip($e.Graphics,$dragGrip.Bounds) }
        $pen = [Drawing.Pen]::new($hudColors.Divider)
        try { $e.Graphics.DrawLine($pen,0,$sender.Height-1,$sender.Width,$sender.Height-1) }
        finally { $pen.Dispose() }
    })
    $window.Controls.Add($band)
    $localChrome.OutsideClicks = [JieShou.OutsideClickDismissal]::new($band)
    $localChrome.OutsideClicks.Add_OutsidePressed({
        if ($expanded -and !$drag.Active -and !$localChrome.AppearanceDialog) { Switch-ReminderExpansion }
    })
    $band.Controls.Add($header)
    $band.Controls.Add($localChrome.Toggle)
    $band.Controls.Add($localChrome.Settings)
    $window.Controls.Add($localChrome.Pill)
    $localChrome.Pill.AgentIcons = $agentIcons
    $localChrome.Pill.Name = 'hud-compact'
    $localChrome.Pill.AllowDrag = $true
    $localChrome.Pill.DragGrip = $dragGrip
    $localChrome.Surface = [JieShou.PillWindowSurface]::new($window,$localChrome.Pill,$dragGrip,$band)
    $localChrome.Surface.Add_RolledUp({ if (!$expanded) { Update-ReminderWindow } })
    $localChrome.Pill.ContextMenuStrip = $menu
    $localChrome.Pill.Add_Click({
        if ($this.EdgeTab -and !$this.EdgePeek -and $this.ReminderCount -eq 0) {
            Update-LocalDockHover $window.Location
            return
        }
        Open-LocalSessionList $this.ClickedStatus
    })
    $edgeEnter={
        if ($window.Visible -and $localChrome.Pill.EdgeTab -and !$localChrome.DockHover) {
            [void]$window.BeginInvoke([Action]{ Update-LocalDockHover })
        }
    }
    $localChrome.Pill.Add_MouseEnter($edgeEnter)
    foreach ($index in 0..4) {
        $tag=$localChrome.Pill.AddEdgeButton($index)
        $tag.ContextMenuStrip=$menu
        $tag.Add_MouseEnter($edgeEnter)
        $tag.Add_Click({ Open-LocalSessionList $this.Tag })
    }
    $localChrome.AllSessions.Text='全部会话'
    $localChrome.AllSessions.Name='edge-all-sessions'
    $localChrome.AllSessions.Add_Click({ Set-SessionSelection 'Attention' $null })
    $band.Controls.Add($localChrome.AllSessions)
    $localChrome.ReminderFilters=@(foreach ($kind in '待输入','完成未读','进行中','已完成') {
        $tab=[JieShou.HudButton]::new()
        $tab.Name="edge-filter-$kind"; $tab.Tag=$kind; $tab.Visible=$false
        $tab.Add_Click({ Set-SessionSelection 'Attention' $this.Tag })
        $band.Controls.Add($tab)
        $tab.BringToFront()
        $tab
    })
    $localChrome.Pill.Add_MoveRequested({
        $pos = $this.RequestedLocation
        Move-ReminderHud $pos.X $pos.Y ([Windows.Forms.Screen]::FromPoint($this.DragPointer).WorkingArea)
    })
    $localChrome.Pill.Add_DragFinished({ Complete-LocalHudDrag $this.DragPointer })
    $localChrome.Pill.AccessibleDescription = '点击展开，拖动移动，右键设置外观'
    $localChrome.Settings.Text = '外观'
    $localChrome.Settings.AccessibleName = '外观'
    $localChrome.Settings.Glyph = 'Settings'
    $localChrome.Toggle.Glyph = 'Collapse'
    $localChrome.Toggle.AccessibleName = '收起'
    $localChrome.Prev.Glyph = 'Previous'
    $localChrome.Next.Glyph = 'Next'
    foreach ($b in $localChrome.Settings,$localChrome.Toggle,$localChrome.Prev,$localChrome.Next) { $b.IconOnly = $true }
    $hudTips.SetToolTip($localChrome.Settings,'外观设置')
    $hudTips.SetToolTip($localChrome.Toggle,'收起')
    $hudTips.SetToolTip($localChrome.Prev,'上一页')
    $hudTips.SetToolTip($localChrome.Next,'下一页')
    $localChrome.Settings.Name = 'hud-appearance'
    $localChrome.Settings.Add_Click({ [void]$window.BeginInvoke([Action]{ Show-HudAppearance }) })
    foreach ($popup in $menu,$trayMenu) {
        if ($popup) {
            $item = [Windows.Forms.ToolStripMenuItem]::new('外观设置…')
            $item.Add_Click({ [void]$window.BeginInvoke([Action]{ Show-HudAppearance }) })
            $popup.Items.Insert(0,$item)
            $toggleHide = [Windows.Forms.ToolStripMenuItem]::new('自动隐藏')
            $toggleHide.Name = 'toggle-autohide'
            $toggleHide.Add_Click({
                $next = $appearance.Copy()
                $next.AutoHide = !$appearance.AutoHide
                try { $next.Save($appearancePath) }
                catch { Write-Warning "未能保存自动隐藏设置：$($_.Exception.Message)"; return }
                $script:appearance = $next
                $this.Checked = $next.AutoHide
                if ($localChrome.AppearanceDialog) { $localChrome.AppearanceDialog.SetAutoHide($next.AutoHide) }
                $localChrome.DockHover = $false
                $localChrome.HoverUntil = 0
                Update-ReminderWindow
            })
            $popup.Items.Insert(1,$toggleHide)
            $popup.Add_Opening({
                $this.Items['toggle-autohide'].Checked = $appearance.AutoHide
                [JieShou.HudCommandMenuRenderer]::Apply($this,$hudColors,$hudFonts.Body,$localDpi)
            })
        }
    }
    $dragGrip.Text = ''
    $dragGrip.BackColor = [Drawing.Color]::Transparent
    $dragGrip.AccessibleRole = 'Grip'
    $dragGrip.AccessibleDescription = '按住拖动浮窗'
    $dragGrip.Add_MouseEnter({ $dragGrip.Invalidate() })
    $dragGrip.Add_MouseLeave({ $dragGrip.Invalidate() })
    $dragGrip.Add_MouseCaptureChanged({ $dragGrip.Invalidate() })
    $hudTips.SetToolTip($dragGrip,'按住拖动浮窗')
    $header.Name = 'hud-title'
    $header.TextAlign = 'MiddleLeft'
    $header.Cursor = [Windows.Forms.Cursors]::SizeAll
    $header.AccessibleDescription='按住标题拖动浮窗'
    Register-ReminderDrag $header
    Register-ReminderDrag $band
    $localChrome.Toggle.Name = 'hud-toggle-action'
    $localChrome.Toggle.Add_Click({ Switch-ReminderExpansion })
    $localChrome.Prev.Name = 'local-prev'
    $localChrome.Prev.Text = '上一页'
    $localChrome.Prev.Add_Click({ $localView.Page--; $list.AutoScrollPosition=[Drawing.Point]::Empty; Update-ReminderWindow })
    $localChrome.Next.Name = 'local-next'
    $localChrome.Next.Text = '下一页'
    $localChrome.Next.Add_Click({ $localView.Page++; $list.AutoScrollPosition=[Drawing.Point]::Empty; Update-ReminderWindow })
    foreach ($button in $localChrome.Toggle,$localChrome.Settings,$localChrome.Prev,$localChrome.Next) {
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.UseVisualStyleBackColor = $false
        $button.Cursor = [Windows.Forms.Cursors]::Hand
    }
    $localChrome.PageLabel.TextAlign = 'MiddleCenter'
    $localChrome.Notice.TextAlign = 'MiddleLeft'
    $localChrome.Notice.AutoEllipsis = $true
    $localChrome.Section.UseMnemonic = $false
    $localChrome.Section.TextAlign = 'MiddleLeft'
    foreach ($control in $localChrome.Prev,$localChrome.Next,$localChrome.PageLabel,$localChrome.Section,$localChrome.Notice) {
        $window.Controls.Add($control)
    }
    $list.BackColor = [Drawing.Color]::White
    $list.TabIndex = 3
    $menuButton.Visible = $false
    $refreshDisplay = {
        if (!$window.IsHandleCreated -or $window.IsDisposed -or $localChrome.DisplayRefreshPending) { return }
        $localChrome.DisplayRefreshPending = $true
        [void]$window.BeginInvoke([Action]{
            $localChrome.DisplayRefreshPending = $false
            if (!$window.IsDisposed) {
                [JieShou.HudDisplayIds]::Refresh()
                if ($localChrome.AppearanceDialog) { $localChrome.AppearanceDialog.RefreshScreens() }
                $localChrome.ExpansionSource = $null
                Update-ReminderWindow
            }
        })
    }
    $window.Add_DpiChanged($refreshDisplay)
    $window.Add_WorkAreaChanged($refreshDisplay)
    [void]$window.Handle
    Set-HudAppearance
}

function Sync-LocalSessionRows($PageRows,$AttentionLabels) {
    $wanted=[Collections.Generic.List[Windows.Forms.Control]]::new()
    $unread=0
    $turnLabels=@{ inProgress='进行中'; completed='已完成'; interrupted='已中断'; failed='失败'; unknown='状态未知'; idle='空闲' }
    foreach ($entry in $PageRows) {
        $session=$entry.Session
        $hasChildren=$entry.Group.Children.Count -gt 0
        $side=$session.agent -ceq 'Codex' -and [bool]$session.parentId
        $key="$($session.agent)/$($session.id)"
        $row=$null
        if (!$localChrome.Rows.TryGetValue($key,[ref]$row)) {
            $row=[JieShou.LocalRow]::new()
            $row.Name="local-$($session.agent)-$($session.id)"
            $row.Tag=$session.id
            $row.Add_Click({ if ($this.CanOpen) { Open-LocalHudSession $this.Agent $this.Tag } })
            $localChrome.Rows.Add($key,$row)
            $list.Controls.Add($row)
        }
        $iconKey=if ($session.agent -eq 'Qoder') {
            if ($appearance.Theme -eq '云白') { 'qoder-light' } else { 'qoder-dark' }
        } else { $session.agent }
        $title=if ($session.name) { $session.name } else { "$($session.agent) 会话 $($session.id.Substring(0,[Math]::Min(8,$session.id.Length)))" }
        $stamp = $session[$localView.Sort]
        $label = if ($localView.Sort -eq 'created') { '创建' } else { '消息' }
        $time = if ($stamp) {
            $date = [datetimeoffset]::FromUnixTimeMilliseconds($stamp).ToLocalTime()
            if ($date.Date -eq [datetime]::Today) { '今天 ' + $date.ToString('HH:mm') } else { $date.ToString('MM-dd HH:mm') }
        } else { '时间未知' }
        $stateLabel = $turnLabels[$session.turn]
        if ($AttentionLabels.ContainsKey("$($session.agent)/$($session.id)")) { $stateLabel = $AttentionLabels["$($session.agent)/$($session.id)"] }
        if ($entry.ContextOnly) { $stateLabel=if ($localView.Attention) { '侧聊所属主会话' } else { '筛选时段外' } }
        $indicator=switch ($stateLabel) { '进行中' { 'Running' } '完成未读' { 'CompletedUnread' } '待输入' { 'Attention' } default { 'None' } }
        $role=if ($side) { 'Codex 侧聊' } elseif ($hasChildren) { 'Codex 主会话' } else { $session.agent }
        $detail="$role   ·   $stateLabel"
        $description="$detail，$label $time"
        $canOpen=Test-LocalSessionCanOpen $session
        if ($session.agent -eq 'DSH') { $description+='。DSH 原生消息时间包含工具结果。' }
        if ($side -and $canOpen) { $description+='。在主会话中打开此侧聊。' }
        elseif ($side) { $detail+=' · 主会话不可用'; $description+='。主会话不可用。' }
        elseif ($canOpen) { $description+='。打开此会话。' }
        $titleFont=if ($side) { $hudFonts.Body } else { $hudFonts.Name }
        $row.Bind($title,$session.agent,$detail,$time,$description,$indicator,$canOpen,$agentIcons[$iconKey],$hudColors,$titleFont,$hudFonts.Small,$localDpi,$side,$hasChildren,$entry.Branch)
        $wanted.Add($row)
        if ($entry.Priority) { $unread++ }
        if ($hasChildren -and !$localView.Attention) {
            $toolKey="sidechats/$($session.id)"
            $toggle=$null
            if (!$localChrome.Rows.TryGetValue($toolKey,[ref]$toggle)) {
                $toggle=[JieShou.SideChatToggle]::new()
                $toggle.Name="sidechats-$($session.id)"; $toggle.Tag=$session.id
                $toggle.Add_Click({
                    if (!$localChrome.ExpandedGroups.Remove($this.Tag)) { [void]$localChrome.ExpandedGroups.Add($this.Tag) }
                    Update-ReminderWindow
                })
                $localChrome.Rows.Add($toolKey,$toggle)
                $list.Controls.Add($toggle)
            }
            $family=$entry.Group
            $toggle.Bind($family.Children.Count,$family.Waiting,$family.Unread,$family.Running,$localChrome.ExpandedGroups.Contains($session.id),$hudColors,$hudFonts.Small,$localDpi)
            $wanted.Add($toggle)
            if ($entry.Priority) { $unread++ }
        }
    }
    foreach ($key in @($localChrome.Rows.Keys)) {
        $row=$localChrome.Rows[$key]
        if (!$wanted.Contains($row)) {
            [void]$localChrome.Rows.Remove($key)
            $row.Dispose()
        }
    }
    $wanted.InsertRange($unread,$localChrome.Cards)
    if (!$PageRows.Count) {
        if (!$localChrome.EmptyHint) {
            $localChrome.EmptyHint=[Windows.Forms.Label]::new()
            $localChrome.EmptyHint.Margin=[Windows.Forms.Padding]::Empty
            $localChrome.EmptyHint.TextAlign='MiddleLeft'
            $list.Controls.Add($localChrome.EmptyHint)
        }
        $hint=$localChrome.EmptyHint
        $hint.Font=$hudFonts.Body; $hint.ForeColor=$hudColors.Muted
        $hint.Text = if ($localView.Status -eq 'Loading') { '正在读取会话…' }
            elseif ($localView.Status -eq 'Unavailable') { '无法读取本地会话索引。' }
            elseif ($localView.Sources[$localView.Agent] -eq 'missing') { "未找到 $($localView.Agent) 的本地索引。" }
            elseif ($localView.Sources[$localView.Agent] -eq 'unavailable') { "$($localView.Agent) 的索引暂不可读。" }
            elseif ($localView.Sources[$localView.Agent] -eq 'partial') { '部分会话记录暂不可读，当前没有匹配会话。' }
            elseif ($localView.Attention -and $localChrome.PopulatedFilter) { '已处理完' }
            elseif ($localView.Attention) { "当前筛选范围内没有$($localView.Attention)的会话。" }
            elseif ($localView.Days) { '此时间范围内没有会话，可切换到「全部时间」。' }
            else { '当前来源暂无会话。' }
        $wanted.Add($hint)
    } elseif ($localChrome.EmptyHint) {
        $localChrome.EmptyHint.Dispose()
        $localChrome.EmptyHint=$null
    }
    for ($i=0;$i -lt $wanted.Count;$i++) {
        $c=$wanted[$i]
        if ($list.Controls[$i] -ne $c) { $list.Controls.SetChildIndex($c,$i) }
        $divider=$i -lt $wanted.Count-1 -and $wanted[$i+1] -isnot [JieShou.SideChatToggle]
        if ($c -is [JieShou.LocalRow] -and $c.ShowDivider -ne $divider) {
            $c.ShowDivider=$divider
            $c.Invalidate()
        }
    }
}

function Get-LocalAttention($Rows,$Waiting,[datetimeoffset]$Now) {
    $inputCount = [JieShou.PillTally]::new()
    $unreadCount = [JieShou.PillTally]::new()
    $running = [JieShou.PillTally]::new()
    $reminders=@{}
    foreach ($kind in '待输入','完成未读','进行中','已完成') { $reminders[$kind]=[Collections.Generic.List[object]]::new() }
    $requests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($request in $Waiting) { [void]$requests.Add($request.Event.TaskId) }
    $labels = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $dshTitles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $duplicates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($localView.DshBadges.Count -and $localView.Sources.DSH -eq 'ready') {
        foreach ($session in $localView.Rows) {
            if ($session.agent -ceq 'DSH' -and $session.desktopTitle -and !$dshTitles.Add($session.desktopTitle)) {
                [void]$duplicates.Add($session.desktopTitle)
            }
        }
    }
    $nowMs = $Now.ToUnixTimeMilliseconds()
    foreach ($row in $Rows) {
        $waitingForUser = $row.needsInput -eq 1 -or ($row.agent -ceq 'Codex' -and $requests.Contains($row.id))
        $key = "$($row.agent)/$($row.id)"
        $turn = $row.turn
        $unread = $row.unread -eq 1
        if ($row.agent -ceq 'Qoder' -and $row.desktop -and $localView.QoderSnapshot) {
            $live = $localView.QoderSnapshot
            $badge = $live.Badges[$row.id]
            if ($badge -ceq 'waiting') { $waitingForUser = $true }
            elseif ($badge -ceq 'running' -or ($turn -ceq 'unknown' -and $live.StartedAt -gt 0 -and $row.bufferedSince -ge $live.StartedAt)) {
                $turn = 'inProgress'; $labels[$key] = '进行中'
            }
        }
        if ($row.agent -ceq 'DSH' -and $dshTitles.Contains($row.desktopTitle) -and !$duplicates.Contains($row.desktopTitle)) {
            switch ($localView.DshBadges[$row.desktopTitle]) {
                'waiting' { $waitingForUser = $true }
                'running' { $waitingForUser = $false; $turn = 'inProgress'; $labels[$key] = '进行中' }
                'unread'  { $waitingForUser = $false; $turn = 'completed'; $unread = $true; $labels[$key] = '已完成' }
            }
        }
        if ($waitingForUser) {
            $inputCount.Add($row.agent)
            $reminders['待输入'].Add($row)
            $labels[$key] = '待输入'
            continue
        }
        switch ($turn) {
            'inProgress' {
                $running.Add($row.agent)
                $reminders['进行中'].Add($row)
                $labels[$key]='进行中'
            }
            'completed' {
                $reminders['已完成'].Add($row)
                if (!$unread) { break }
                $labels[$key] = '完成未读'
                if ($row.finished -gt 0 -and
                    $row.finished -le $nowMs -and $row.finished -gt $nowMs-86400000L) {
                    $unreadCount.Add($row.agent)
                    $reminders['完成未读'].Add($row)
                    $expires = [datetimeoffset]::FromUnixTimeMilliseconds($row.finished+86400000L).UtcDateTime
                    if ($expires -lt $localView.NextExpiry) { $localView.NextExpiry = $expires }
                }
            }
        }
    }
    # Empty attention slots stay out of the pill. These two are confirmed notifications.
    $values = [string[]]@(
        $(if ($inputCount.Total) { [string]$inputCount.Total } else { '' })
        $(if ($unreadCount.Total) { [string]$unreadCount.Total } else { '' })
        [string]$running.Total
        [string]$Rows.Count
        [string]$reminders['已完成'].Count
    )
    return @{ Values=$values; Labels=$labels; Reminders=$reminders; Breakdown=[JieShou.PillTally[]]@($inputCount,$unreadCount,$running) }
}

function Test-LocalEdgeTab {
    $appearance.AutoHide -and $localChrome.DockReady -and !$expanded -and !$localChrome.AppearanceDialog -and
        (!$drag.Active -or ($localChrome.Pill.EdgeTab -and $localChrome.Pill.EdgePeek))
}

function Update-LocalDockHover([Drawing.Point]$Pointer=[Windows.Forms.Cursor]::Position,[long]$Now=[Environment]::TickCount64) {
    if (!$appearance.AutoHide -or !$window.Visible -or $expanded -or $localChrome.Surface.IsRevealing -or $localChrome.AppearanceDialog) { return }
    # Keep the full capsule available while the pointer crosses between its
    # child controls. Use the existing UI timer, including when the feed is idle.
    $inside=$window.Bounds.Contains($Pointer)
    if ($inside -or $drag.Active -or $localChrome.Pill.Capture -or $menu.Visible -or $localChrome.Pill.EdgeKeyboardFocus) { $localChrome.HoverUntil=$now+650 }
    $peek=$now -lt [long]$localChrome.HoverUntil
    if ($localChrome.DockHover -eq $peek -and $localChrome.Pill.EdgeTab -eq (Test-LocalEdgeTab)) { return }
    $localChrome.DockHover=$peek
    if ($placement.Docked -and $localChrome.Surface.IsActive -and $localChrome.Pill.EdgeTab -and (Test-LocalEdgeTab)) {
        $work=(Get-ReminderHudScreen $placement).WorkingArea
        $localChrome.Surface.PeekEdge($peek,$work,$placement.Anchor)
        return
    }
    Update-ReminderWindow
}

function Start-LocalRollUp {
    $localView.Attention=$null
    $work = (Get-ReminderHudScreen $placement).WorkingArea
    if ($appearance.AutoHide) {
        $localChrome.DockHover=$false
        $localChrome.HoverUntil=0
        $localChrome.Pill.EdgePeek=$false
        $localChrome.Pill.EdgeTab=Test-LocalEdgeTab
    }
    $size = $localChrome.Pill.MeasureForArea($work.Size)
    $bounds = Get-ReminderHudBounds $placement $work $size.Width $size.Height $localSystemDpi
    return $localChrome.Surface.RollUp($bounds)
}

function Update-LocalHudWindow {
    if (!$expanded -and $localChrome.Surface.IsRollingUp) { return }
    $window.SuspendLayout()
    $list.SuspendLayout()
    try {
        $screen = Get-ReminderHudScreen $placement
        $work = $screen.WorkingArea
        $script:localSystemDpi=[JieShou.HudDisplayScale]::SystemDpi($screen)
        $oldDpi=$localDpi
        $oldScroll=-$list.AutoScrollPosition.Y
        Set-LocalHudTypeScale ([JieShou.HudDisplayScale]::For($screen,$appearance))
        if ($expanded -and $oldScroll -gt 0 -and $oldDpi -gt 0 -and $oldDpi -ne $localDpi) {
            $oldScroll=[int][Math]::Round($oldScroll*$localDpi/$oldDpi)
        }
        $pad = Get-HudPixels 18
        $bandHeight = Get-HudPixels ($appearance.Size+32)
        $toggleWidth = Get-HudPixels 36
        $window.Text = '智能体消息中心 · AMC'
        $window.AccessibleName = $window.Text
        $now = [datetimeoffset]::UtcNow
        $visibleRows = @(Get-VisibleSessions $now)
        if ($expanded -and $visibleRows.Count) {
            $midnight = [datetime]::Today.AddDays(1).ToUniversalTime()
            if ($midnight -lt $localView.NextExpiry) { $localView.NextExpiry=$midnight }
        }
        $showCodex = $localView.Agent -in '所有 Agent','Codex'
        $waiting = $pending = @()
        $title = '智能体消息中心'
        if ($showCodex -and $state.Waiting.Count) {
            $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($r in $visibleRows) { if ($r.agent -eq 'Codex') { [void]$ids.Add($r.id) } }
            $waiting = @(Get-ReminderWaiting $state | Where-Object { $ids.Contains($_.Event.TaskId) })
            $pending = @(Get-ReminderWaiting $state -Pending | Where-Object { $ids.Contains($_.Event.TaskId) })
        }
        $pill = $localChrome.Pill
        $pill.Vertical=$placement.Vertical
        $opening = $expanded -and $pill.Visible
        if ($expanded) { $localChrome.Surface.UseControls($appearance.Opacity / 100.0) }
        else { $localChrome.Surface.CancelReveal() }
        $attention = Get-LocalAttention $visibleRows $(if ($codexFeed.Status -ceq 'Current') { $waiting }) $now
        $pill.Breakdown = $attention.Breakdown
        $sourceStatus=$localView.Sources[$localView.Agent]
        $countsReady=$localView.Status -eq 'Ready' -and $sourceStatus -notin 'missing','unavailable'
        $pill.Values = if ($countsReady) { ,$attention.Values } else { ,[string[]]@() }
        $localChrome.DockReady=$countsReady
        $pill.EdgeTab=Test-LocalEdgeTab
        $pill.EdgePeek=$pill.EdgeTab -and $localChrome.DockHover
        $compactText = if ($countsReady) { $pill.Caption() }
            elseif ($sourceStatus -eq 'unavailable') { "$($localView.Agent) 暂不可读" }
            elseif ($sourceStatus -eq 'missing') { "未找到 $($localView.Agent) 索引" }
            elseif ($localView.Status -eq 'Loading') { '正在读取会话…' } else { '会话索引暂不可用' }
        $period = switch ($localView.Days) { 1 { '近 24 小时' } 7 { '近 7 天' } default { '全部时间' } }
        $gripHost = if ($expanded) { $localChrome.Band } else { $pill }
        if ($dragGrip.Parent -ne $gripHost) {
            $gripHost.Controls.Add($dragGrip)
            $dragGrip.BringToFront()
        }
        $pill.Visible = !$expanded
        $localChrome.Band.Visible = $expanded
        $pill.Text = $compactText
        $pill.AccessibleName = if ($countsReady) { $pill.Caption($true) } else { $compactText }
        if ($pill.EdgeTab -and !$pill.EdgePeek) { $pill.AccessibleName=$pill.NoticeCaption }
        $pill.AccessibleDescription = "智能体消息中心 · $($localView.Agent) · $period。待输入含审批，完成未读限最近 24 小时。拖动握把移动浮窗，点击数字查看对应会话。"
        $pill.LayoutDpi = $localDpi
        if ($placement.Docked -and $placement.Positioned) {
            # Migrate a saved free-form position once, using the normal capsule
            # dimensions so changing to the thin idle rail cannot move its slot.
            $edge=$pill.EdgeTab; $pill.EdgeTab=$false
            $normal=$pill.MeasureForArea($work.Size); $pill.EdgeTab=$edge
            $old=[JieShou.HudGeometry]::Place($work,$normal,$localSystemDpi,$placement.Anchor,$true,$placement.Right,$placement.Bottom,$placement.X,$placement.Y)
            $placement.Anchor=[JieShou.HudGeometry]::NearestDock($old,$work,$placement.Vertical)
            $placement.Positioned=$false
        }
        if ($expanded) {
            $header.Font = $hudFonts.Title
            $header.Text = $title
            $width = Get-HudPixels ([Math]::Max(448,448*$appearance.Size/15.0))
        } else {
            $desired = $pill.MeasureForArea($work.Size)
            $bandHeight = $desired.Height
            $width = $desired.Width
        }
        $width = [Math]::Min($work.Width, $width)
        $localChrome.Toggle.Text = if ($expanded) { '收起  ▴' } else { '展开  ▾' }
        if ($localChrome.Band.Width -ne $width) { $localChrome.Band.Width=$width }
        $gripWidth = $pill.GripWidth
        $dragGrip.Visible=$expanded -or !$pill.EdgeTab -or $pill.EdgePeek
        if ($expanded) { $dragGrip.SetBounds(0,0,$gripWidth,$bandHeight) }
        else { $dragGrip.Bounds = $pill.GripBounds($desired) }
        $dragGrip.Invalidate()
        $settingsW = $toggleWidth
        $rightMargin = Get-HudPixels 10
        if ($expanded) {
            $header.SetBounds($gripWidth,0,($width-$gripWidth-$settingsW-$toggleWidth-$rightMargin),$bandHeight)
            $localChrome.Settings.SetBounds(($width-$rightMargin-$settingsW-$toggleWidth),0,$settingsW,$bandHeight)
        }
        $localChrome.Toggle.SetBounds(($width-$rightMargin-$toggleWidth),0,$toggleWidth,$bandHeight)
        foreach ($c in $localChrome.Range,$localChrome.Sort,$localChrome.Section,$localScrollBar) { $c.Visible = $expanded }
        $sessionRows=$visibleRows
        if ($expanded -and $localView.Attention) {
            $sessionRows=$attention.Reminders[$localView.Attention]
            $waiting=$pending=@()
            $filter="$($localView.Agent)|$($localView.Days)|$($localView.Attention)"
            if ($countsReady -and $sessionRows.Count) { $localChrome.PopulatedFilter=$filter }
            elseif (!$countsReady -or $localChrome.PopulatedFilter -cne $filter) { $localChrome.PopulatedFilter=$null }
        } else {
            $localChrome.PopulatedFilter=$null
        }
        $groups=@(if ($expanded) { Get-SessionGroups $sessionRows $attention.Labels })
        $pages = if ($localView.Attention -ceq '进行中') { 1 } else { [Math]::Max(1,[int][Math]::Ceiling($groups.Count/12.0)) }
        $localView.Page = [Math]::Clamp([int]$localView.Page,0,$pages-1)
        $pager = $expanded -and $pages -gt 1
        $localChrome.Prev.Visible = $localChrome.Next.Visible = $localChrome.PageLabel.Visible = $pager
        $localChrome.Notice.Visible = $false
        $height = $bandHeight
        if ($expanded) {
            $inside = $width - 2*$pad
            $filterKey="$localDpi|$inside|$bandHeight|$($localView.Agent)|$($localView.Days)|$($localView.Sort)"
            if ($localChrome.FilterLayout -cne $filterKey) {
                $localChrome.HeaderBottom=Set-SessionFilterLayout $pad $bandHeight $inside
                $localChrome.FilterLayout=$filterKey
            }
            $headerBottom=Set-SessionStatusLayout $pad $localChrome.HeaderBottom $inside $attention $countsReady
            $localChrome.Band.Height = $headerBottom
            $toolbarTop = $headerBottom + (Get-HudPixels 5)
            $toolbarHeight = Get-HudPixels ($appearance.Size+19)
            $sortW = [Math]::Min([int]($inside*0.32),(Get-HudPixels (58+3.4*$appearance.Size)))
            $rangeW = [Math]::Min([int]($inside*0.34),(Get-HudPixels (60+3.6*$appearance.Size)))
            $localChrome.Section.Text = if ($countsReady) { "$($sessionRows.Count) 个会话" }
                elseif ($localView.Status -eq 'Loading') { '读取中' } else { '会话数未知' }
            $localChrome.Section.SetBounds($pad,$toolbarTop,($inside-$sortW-$rangeW),$toolbarHeight)
            $localChrome.Range.SetBounds(($width-$pad-$sortW-$rangeW),$toolbarTop,$rangeW,$toolbarHeight)
            $localChrome.Sort.SetBounds(($width-$pad-$sortW),$toolbarTop,$sortW,$toolbarHeight)
            $notes = @(foreach ($agent in $localView.Sources.Keys) {
                if ($localView.Agent -ne '所有 Agent' -and $localView.Agent -ne $agent) { continue }
                switch ($localView.Sources[$agent]) {
                    unavailable { "$agent 暂不可读" }
                    partial { "$agent 部分索引暂不可读" }
                }
            })
            $listTop = $toolbarTop + $toolbarHeight
            if ($pager) {
                $btnH = Get-HudPixels ($appearance.Size+14)
                $arrowW = Get-HudPixels 30
                $localChrome.PageLabel.Text = "$($localView.Page+1) / $pages"
                $pageW = $localChrome.PageLabel.PreferredWidth + (Get-HudPixels 8)
                $localChrome.Next.SetBounds(($width-$pad-$arrowW),$listTop,$arrowW,$btnH)
                $localChrome.PageLabel.SetBounds(($localChrome.Next.Left-$pageW),$listTop,$pageW,$btnH)
                $localChrome.Prev.SetBounds(($localChrome.PageLabel.Left-$arrowW),$listTop,$arrowW,$btnH)
                $listTop += $btnH
            }
            if ($notes.Count) {
                $localChrome.Notice.Text = $notes -join '、'
                $localChrome.Notice.SetBounds($pad,$listTop,$inside,(Get-HudPixels ($appearance.Size+9)))
                $localChrome.Notice.Visible = $true
                $listTop = $localChrome.Notice.Bottom
            }
            $localChrome.Prev.Enabled = $localView.Page -gt 0
            $localChrome.Next.Enabled = $localView.Page -lt $pages-1
            $pageRows=@(Get-SessionPage $groups)
            $order=($pageRows | ForEach-Object { "$($_.Session.agent)/$($_.Session.id)/$($_.Group.Children.Count -gt 0)" }) -join [char]0
            $scope="$($localView.Agent)|$($localView.Days)|$($localView.Attention)|$($localView.Page)|$localDpi"
            $cardsKey=if ($waiting.Count -or $pending.Count) {
                "$localDpi|" + (ConvertTo-Json -Compress -Depth 12 -InputObject @($waiting,$pending,$codexFeed.Status))
            } else { '' }
            $move=$order -cne $localChrome.PageOrder -or $cardsKey -cne $localChrome.CardsKey
            if ($move) { $list.CaptureOrder($localChrome.ListScope -ceq $scope) }
            $localChrome.ListScope=$scope; $localChrome.PageOrder=$order
            if ($cardsKey -cne $localChrome.CardsKey) {
                foreach ($card in $localChrome.Cards) { $card.Dispose() }
                $localChrome.Cards.Clear()
                if ($waiting.Count) { Add-ReminderGroup '等我' $waiting 'Waiting' $localChrome.Cards }
                if ($pending.Count) { Add-ReminderGroup '待确认' $pending 'Pending' $localChrome.Cards }
                foreach ($card in $localChrome.Cards) { $card.Scale([Drawing.SizeF]::new($localDpi/96.0,$localDpi/96.0)) }
                $localChrome.CardsKey=$cardsKey
            }
            Sync-LocalSessionRows $pageRows $attention.Labels
            $maxHeight=[Math]::Min((Get-HudPixels 520),$work.Height-(Get-HudPixels 12))
            $bottomPadding=Get-HudPixels 6
            $listMax=[Math]::Max(1,$maxHeight-$listTop-$bottomPadding)
            $rowWidth=$inside
            $contentHeight=0
            foreach ($c in $list.Controls) {
                if ($c -is [JieShou.LocalRow] -or $c -is [JieShou.SideChatToggle]) { $contentHeight+=$c.ContentHeight($inside) }
                elseif ($c -eq $localChrome.EmptyHint) {
                    $c.Height=[Math]::Max((Get-HudPixels 48),$c.GetPreferredSize([Drawing.Size]::new($inside,0)).Height)
                    $contentHeight+=$c.Height
                } else { $contentHeight+=$c.Height }
                $contentHeight+=$c.Margin.Vertical
            }
            if ($contentHeight -gt $listMax) { $rowWidth=[Math]::Max(1,$inside-$localScrollBar.GutterWidth-(Get-HudPixels 2)) }
            $contentHeight=0
            foreach ($c in $list.Controls) {
                if ($c -is [JieShou.LocalRow] -or $c -is [JieShou.SideChatToggle]) { $c.Size=[Drawing.Size]::new($rowWidth,$c.ContentHeight($rowWidth)) }
                else {
                    $c.Width=$rowWidth-$c.Margin.Horizontal
                    if ($c -eq $localChrome.EmptyHint) {
                        $c.Height=[Math]::Max((Get-HudPixels 48),$c.GetPreferredSize([Drawing.Size]::new($c.Width,0)).Height)
                    }
                }
                $contentHeight+=$c.Height+$c.Margin.Vertical
            }
            $localScrollBar.SetBounds($pad,$listTop,$inside,[Math]::Min($listMax,$contentHeight))
            $height = $localScrollBar.Bottom + $bottomPadding
        }
        $bounds = Get-ReminderHudBounds $placement $work $width $height $localSystemDpi
        if ($expanded) {
            if ($opening) { $localChrome.ExpansionSource=$window.Bounds }
            if ($null -eq $localChrome.ExpansionSource -and $placement.Docked) {
                $compactSize=$pill.MeasureForArea($work.Size)
                $localChrome.ExpansionSource=Get-ReminderHudBounds $placement $work $compactSize.Width $compactSize.Height $localSystemDpi
            }
            if ($null -ne $localChrome.ExpansionSource) {
                $bounds=[JieShou.HudGeometry]::Expand($localChrome.ExpansionSource,$bounds.Size,$work,$pill.Vertical,$localDpi)
            }
            $origin=if ($null -ne $localChrome.ExpansionSource) { $localChrome.ExpansionSource } else { $bounds }
            $forward=[JieShou.HudGeometry]::OpensForward($origin,$work,$pill.Vertical)
            $localChrome.Toggle.Glyph = if ($pill.Vertical) { if ($forward) { 'Previous' } else { 'Next' } }
                elseif ($forward) { 'Collapse' } else { 'Down' }
            $radius = if ($appearance.Shape -eq '直角') { 0 } else { Get-HudPixels 16 }
            $localChrome.Surface.SetPanelBounds($bounds,$radius)
        } else {
            $localChrome.ExpansionSource=$null
            $pill.OpensForward=[JieShou.HudGeometry]::OpensForward($bounds,$work,$pill.Vertical)
            $window.Bounds = $bounds
            $localChrome.ListScope=$null
            $pill.Bounds = $window.ClientRectangle
            $pill.ArrangeEdgeButtons()
        }
    } finally {
        $list.ResumeLayout($true)
        $window.ResumeLayout($true)
    }
    if (!$expanded) { $localChrome.Surface.Present() }
    if ($expanded) {
        if ($oldScroll -gt 0 -and $oldScroll -ne -$list.AutoScrollPosition.Y) { $list.AutoScrollPosition=[Drawing.Point]::new(0,$oldScroll) }
        if ($move) { $list.CommitOrder() }
        $localScrollBar.UpdateRails()
        $localChrome.Surface.PlayReveal()
    }
    $localChrome.ActivityAnimation.Refresh()
}
