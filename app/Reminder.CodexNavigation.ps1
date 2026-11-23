# Select an existing side chat through the desktop app's own summary and tab controls.
param([string]$CancelEvent)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexNavigationWindow {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$ae = [Windows.Automation.AutomationElement]
$type = [Windows.Automation.ControlType]
$scope = [Windows.Automation.TreeScope]::Descendants
$condition = [Windows.Automation.PropertyCondition]
$walker = [Windows.Automation.TreeWalker]::ControlViewWalker
$selection = [Windows.Automation.SelectionItemPattern]::Pattern
$expand = [Windows.Automation.ExpandCollapsePattern]::Pattern
$invoke = [Windows.Automation.InvokePattern]::Pattern

function Find-Control($Root,$Kind,[string]$Name) {
    $query = [Windows.Automation.AndCondition]::new($condition::new($ae::ControlTypeProperty,$Kind),$condition::new($ae::NameProperty,$Name))
    $Root.FindAll($scope,$query)
}

function Get-CodexDocument([string]$Title) {
    # Shell URI activation can leave the HUD in the foreground. Bind to the matching
    # Codex window, and keep the same HWND through any subsequent panel transitions.
    if ($script:boundWindow) {
        $docs = @(Find-Control $script:boundWindow $type::Document $Title | Where-Object { $_.Current.AutomationId -ceq 'RootWebArea' })
        if ($docs.Count -eq 1) { return $docs[0] }
        return
    }
    $foreground = [CodexNavigationWindow]::GetForegroundWindow()
    $matches = @(
        foreach ($process in Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue) {
            if (!$process.MainWindowHandle.ToInt64() -or $process.Path -notmatch '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$') { continue }
            $windows = $ae::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition::new($ae::ProcessIdProperty,$process.Id))
            foreach ($window in $windows) {
                $docs = @(Find-Control $window $type::Document $Title | Where-Object { $_.Current.AutomationId -ceq 'RootWebArea' })
                if ($docs.Count -eq 1) { @{Window=$window; Doc=$docs[0]; Foreground=$window.Current.NativeWindowHandle -eq $foreground.ToInt64()} }
            }
        }
    )
    $front = @($matches | Where-Object Foreground)
    $target = if ($front.Count -eq 1) { $front[0] } elseif ($matches.Count -eq 1) { $matches[0] }
    if ($target) { $script:boundWindow=$target.Window; return $target.Doc }
}

function Get-TabPaneId($Node) {
    while ($Node -and $Node.Current.ControlType -ne $type::Document) {
        if ($Node.Current.AutomationId -clike 'app-shell-tab-panel-*') { return $Node.Current.AutomationId }
        $Node = $walker.GetParent($Node)
    }
    return ''
}

function Get-SelectedSidePane($Doc,[string]$Title) {
    foreach ($tab in Find-Control $Doc $type::TabItem $Title) {
        $id = $tab.Current.AutomationId
        if ($id -cnotlike 'app-shell-tab-*' -or !$tab.GetCurrentPattern($selection).Current.IsSelected) { continue }
        $paneId = 'app-shell-tab-panel-' + $id.Substring('app-shell-tab-'.Length)
        foreach ($pane in Find-Control $Doc $type::Pane $Title) {
            if ($pane.Current.AutomationId -ceq $paneId -and !$pane.Current.IsOffscreen) { $pane }
        }
    }
}

function Find-ScopedButton($Doc,$Names,[string]$PaneId,[string]$ClassToken) {
    foreach ($name in $Names) {
        foreach ($button in Find-Control $Doc $type::Button $name) {
            if (!$button.Current.IsEnabled -or ($ClassToken -and $button.Current.ClassName.Split(' ') -cnotcontains $ClassToken)) { continue }
            if ((Get-TabPaneId $button) -ceq $PaneId) { $button }
        }
    }
}

function Find-SideRow($Header,[string]$Title) {
    # The header and its rows share a panel with other sections. Stop at the next section.
    $panel = $walker.GetParent($walker.GetParent($Header))
    $buttons = $panel.FindAll($scope,$condition::new($ae::ControlTypeProperty,$type::Button))
    $inSection = $false
    foreach ($button in $buttons) {
        if ($button.Current.ClassName.Split(' ') -ccontains 'group/section-toggle') {
            if ($inSection) { break }
            $inSection = [Windows.Automation.Automation]::Compare($button,$Header)
        } elseif ($inSection -and $button.Current.ClassName.Split(' ') -ccontains 'self-stretch' -and
            [string]::Equals($button.Current.Name,$Title,[StringComparison]::Ordinal)) { $button }
    }
}

function Expand-ClosedControl($Control) {
    $pattern = $null
    if ($Control.TryGetCurrentPattern($expand,[ref]$pattern) -and $pattern.Current.ExpandCollapseState -eq 'Collapsed') {
        $pattern.Expand()
        return $true
    }
    return $false
}

function Select-CodexSideChat($Request) {
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    $paneId = ''
    $wasReady = $false
    foreach ($step in $Request.steps) {
        $clicked = $openedSummary = $openedSection = $false
        $selected = $null
        do {
            if ($cancel -and $cancel.WaitOne(0)) { return 'cancelled' }
            try {
                $doc = Get-CodexDocument $Request.rootTitle
                if ($doc) {
                    $wasReady = $true
                    $active = @(Get-SelectedSidePane $doc $step.title)
                    if ($active.Count -eq 1 -and ($clicked -or $step.reuse -ne $false)) { $selected = $active[0]; break }
                    if ($active.Count -gt 1) { return 'ambiguous' }
                    if (!$clicked) {
                        $heads = @(Find-ScopedButton $doc @('侧边聊天','Side chats','側邊聊天') $paneId 'group/section-toggle')
                        if ($heads.Count -gt 1) { return 'ambiguous' }
                        if ($heads.Count -eq 1) {
                            $rows = @(Find-SideRow $heads[0] $step.title)
                            if ($rows.Count -gt 1) { return 'ambiguous' }
                            if ($cancel -and $cancel.WaitOne(0)) { return 'cancelled' }
                            if ($rows.Count -eq 1 -and $rows[0].Current.IsEnabled) {
                                if (!(Get-CodexDocument $Request.rootTitle)) { return 'cancelled' }
                                $rows[0].GetCurrentPattern($invoke).Invoke()
                                $clicked = $true
                            } elseif (!$openedSection) { $openedSection = Expand-ClosedControl $heads[0] }
                        } elseif (!$openedSummary) {
                            $buttons = @(Find-ScopedButton $doc @('切换摘要面板固定状态','Toggle pinned summary','切換摘要面板固定狀態') $paneId '' | Where-Object { !$_.Current.IsOffscreen })
                            if ($buttons.Count -eq 1 -and !($cancel -and $cancel.WaitOne(0))) { $openedSummary = Expand-ClosedControl $buttons[0] }
                        }
                    }
                } elseif ($wasReady) { return 'cancelled' }
            } catch [Windows.Automation.ElementNotAvailableException] {
                # React may replace the summary or its anchor while the main chat loads.
            }
            Start-Sleep -Milliseconds 160
        } while ([datetime]::UtcNow -lt $deadline)
        if (!$selected) { return 'missing' }
        $paneId = $selected.Current.AutomationId
    }
    return 'selected'
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if (!$request.rootTitle -or !@($request.steps).Count -or ($request.steps | Where-Object { !$_.id -or !$_.title })) { exit 1 }
    $cancel = if ($CancelEvent) { [Threading.EventWaitHandle]::OpenExisting($CancelEvent) }
    Select-CodexSideChat $request
} catch { 'missing' } finally { if ($cancel) { $cancel.Dispose() } }
