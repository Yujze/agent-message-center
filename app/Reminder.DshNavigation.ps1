# Runs outside the HUD's UI thread. Only the DSH workspace sidebar is actionable.
param([switch]$ResolveOnly, [string]$CancelEvent)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$elementType = [Windows.Automation.AutomationElement]
$descendants = [Windows.Automation.TreeScope]::Descendants
$type = [Windows.Automation.ControlType]
$walker = [Windows.Automation.TreeWalker]::RawViewWalker

$sidebarRefs = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
$sidebarRefs += [Windows.Automation.AutomationElement].Assembly.Location,[Windows.Automation.ControlType].Assembly.Location
if (!('JieShou.DshSidebar' -as [type])) {
    Add-Type -Path "$PSScriptRoot/Reminder.DshSidebar.cs" -ReferencedAssemblies $sidebarRefs
}

function Get-SidebarControls($Root, $Kind) {
    $condition = [Windows.Automation.PropertyCondition]::new($elementType::ControlTypeProperty, $Kind)
    $Root.FindAll($descendants, $condition)
}

function Find-DshSessionRow($Root, [string]$Title) {
    if (!$catalog) { $catalog = [Collections.Generic.HashSet[string]]::new([string[]]@($Title),[StringComparer]::Ordinal) }
    foreach ($tree in Get-SidebarControls $Root $type::Tree) {
        if ($tree.Current.ClassName -cnotmatch '_(list|searchTree)(\s|$)') { continue }
        foreach ($row in Get-SidebarControls $tree $type::TreeItem) {
            $class = $row.Current.ClassName
            if ($class -cnotmatch '_(sessionRow|searchResultRow)(\s|$)' -or $class -cmatch '_archived(\s|$)') { continue }
            if ([string]::Equals(([JieShou.DshSidebar]::MatchTitle($row,$catalog)),$Title,[StringComparison]::Ordinal)) { $row }
        }
    }
}

function Find-DshSearchControl($Root, $Kind, [string]$ClassSuffix) {
    foreach ($control in Get-SidebarControls $Root $Kind) {
        if ($control.Current.ClassName -cnotmatch $ClassSuffix) { continue }
        $parent = $walker.GetParent($control)
        while ($parent -and $parent.Current.ControlType -ne $type::Document) {
            if ($parent.Current.ClassName -cmatch '_root(\s|$)' -and
                @(Get-SidebarControls $parent $type::Tree | Where-Object { $_.Current.ClassName -cmatch '_(list|searchTree)(\s|$)' }).Count) {
                return $control
            }
            $parent = $walker.GetParent($parent)
        }
    }
}

function Get-DshWindow($Program) {
    $process = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -eq $Program } | Select-Object -First 1
    if ($process) { return $elementType::FromHandle($process.MainWindowHandle) }
}

function Open-DshSidebarSession([string]$Title) {
    if (![string]::IsNullOrWhiteSpace($Title)) {
        $program = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/DeepSeek Harness/DeepSeek Harness.exe'
        $deadline = [datetime]::UtcNow.AddSeconds(8)
        $searched = $false
        $searchButtonInvoked = $false
        $searchField = $null
        try {
            do {
                if ($cancel -and $cancel.WaitOne(0)) { return 'cancelled' }
                $root = Get-DshWindow $program
                if ($root) {
                    $rows = @(Find-DshSessionRow $root $Title)
                    if ($rows.Count -gt 1) { return 'ambiguous' }
                    if ($rows.Count -eq 1) {
                        $selection = $rows[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
                        if ($ResolveOnly) { return 'resolved' }
                        if ($selection.Current.IsSelected) { return 'selected' }
                        if ($cancel -and $cancel.WaitOne(0)) { return 'cancelled' }
                        $selection.Select()
                        # Search results can be replaced by the ordinary tree on open.
                        for ($attempt = 0; $attempt -lt 8; $attempt++) {
                            Start-Sleep -Milliseconds 120
                            $active = @(Find-DshSessionRow $root $Title)
                            if ($active.Count -eq 1 -and $active[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { return 'selected' }
                        }
                        return 'missing'
                    }
                    if (!$ResolveOnly -and !$searched) {
                        $edit = Find-DshSearchControl $root $type::Edit '_searchInput(\s|$)'
                        if ($edit -and !$edit.Current.IsOffscreen -and $searchButtonInvoked) {
                            $field = $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                            if ($field.Current.Value) { return 'missing' }
                            $field.SetValue($Title)
                            $searchField = $field
                            $searched = $true
                        } elseif (!$searchButtonInvoked) {
                            $button = Find-DshSearchControl $root $type::Button '_searchButton(\s|$)'
                            if ($button) {
                                if ($edit -and !$edit.Current.IsOffscreen -and $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value) { return 'missing' }
                                $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                                $searchButtonInvoked = $true
                            }
                        }
                    }
                }
                Start-Sleep -Milliseconds 200
            } until ([datetime]::UtcNow -ge $deadline)
        } finally {
            if ($searchField) {
                try { if ($searchField.Current.Value -ceq $Title) { $searchField.SetValue('') } } catch { }
            }
        }
    }
    return 'missing'
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $request = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()) -ErrorAction Stop
    $title = if ($request -is [string]) { $request } else { $request.title }
    $catalog = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $request.titles) { if ($name -is [string]) { [void]$catalog.Add($name) } }
    if ($title -is [string]) { [void]$catalog.Add($title) }
    if ($title -isnot [string]) { exit 1 }
    $cancel = if ($CancelEvent) { [Threading.EventWaitHandle]::OpenExisting($CancelEvent) }
    Open-DshSidebarSession $title
} catch { 'missing' } finally { if ($cancel) { $cancel.Dispose() } }
