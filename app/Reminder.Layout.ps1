function New-ReminderHudPlacement {
    @{ Positioned=$false; Docked=$false; Vertical=$false; Anchor=8; Display=''; Right=$true; Bottom=$true; X=0; Y=0 }
}

function Get-ReminderStartupPlacement($Appearance) {
    $p = New-ReminderHudPlacement
    $p.Display = $Appearance.StartupDisplay
    $p.Docked = $true
    $p.Vertical = $Appearance.StartupDock.Vertical
    $p.Anchor = $Appearance.StartupDock.Anchor
    if ($Appearance.RememberPosition -and $Appearance.LastDrag) {
        if ($null -ne $Appearance.LastDrag.Vertical) { $p.Vertical=$Appearance.LastDrag.Vertical }
        if ($null -ne $Appearance.LastDrag.DockSlot) {
            $p.Anchor=[JieShou.HudGeometry]::DockSlot($Appearance.LastDrag.DockSlot,$p.Vertical)
        }
        else { $p.Positioned=$true }
        foreach ($key in 'Display','Right','Bottom','X','Y') { $p[$key] = $Appearance.LastDrag.$key }
    }
    $p
}

function Get-ReminderHudScreen($Placement, $Screens = [Windows.Forms.Screen]::AllScreens) {
    foreach ($screen in $Screens) {
        if ($Placement.Display -and ($screen.DeviceName -eq $Placement.Display -or
            [JieShou.HudDisplayIds]::For($screen.DeviceName) -eq $Placement.Display)) { return $screen }
        if ($screen.Primary) { $primaryScreen = $screen }
    }
    $primaryScreen
}

function New-ReminderHudForm {
    if (!('JieShou.HudForm' -as [type])) {
        $source = @'
using System.Windows.Forms;
namespace JieShou {
    public sealed class HudForm : Form {
        public event System.EventHandler WorkAreaChanged;
        public bool OwnsDpiLayout { get; set; }
        protected override void OnDpiChanged(DpiChangedEventArgs e) {
            // The local HUD measures and places its window and controls in target-screen pixels.
            // Applying WinForms' suggested scale as well changes the hit area during the move.
            if(OwnsDpiLayout) e.Cancel=true;
            base.OnDpiChanged(e);
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override void WndProc(ref Message message) {
            // WM_MOUSEACTIVATE -> MA_NOACTIVATE, which still delivers the mouse click.
            if (message.Msg == 0x0021) {
                message.Result = new System.IntPtr(3);
                return;
            }
            base.WndProc(ref message);
            if (message.Msg==0x007E || (message.Msg==0x001A && message.WParam.ToInt64()==47))
                WorkAreaChanged?.Invoke(this,System.EventArgs.Empty);
        }
    }
}
'@
        $references = @([Windows.Forms.Form].Assembly.Location, [Windows.Forms.Message].Assembly.Location)
        $references += Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -File -Filter '*.dll' | ForEach-Object FullName
        Add-Type -TypeDefinition $source -ReferencedAssemblies ($references | Sort-Object -Unique)
    }
    [JieShou.HudForm]::new()
}

function Set-ReminderHudPlacement($Placement, [Drawing.Rectangle]$Bounds, [Drawing.Rectangle]$WorkArea, [int]$Dpi=96) {
    $Placement.Docked = $false
    $Placement.Positioned = $true
    $Placement.Right = ($Bounds.Left + $Bounds.Width / 2) -ge ($WorkArea.Left + $WorkArea.Width / 2)
    $Placement.Bottom = ($Bounds.Top + $Bounds.Height / 2) -ge ($WorkArea.Top + $WorkArea.Height / 2)
    $dx = if ($Placement.Right) { $WorkArea.Right - $Bounds.Right } else { $Bounds.Left - $WorkArea.Left }
    $dy = if ($Placement.Bottom) { $WorkArea.Bottom - $Bounds.Bottom } else { $Bounds.Top - $WorkArea.Top }
    $Placement.X = $dx * 96.0 / $Dpi
    $Placement.Y = $dy * 96.0 / $Dpi
}

function Get-ReminderHudBounds($Placement, [Drawing.Rectangle]$WorkArea, [int]$Width, [int]$Height, [int]$Dpi=96) {
    if ($Placement.Docked) {
        $size=[Drawing.Size]::new($Width,$Height)
        $slot=$Placement.Anchor
        if ($Placement.Positioned) {
            $old=[JieShou.HudGeometry]::Place($WorkArea,$size,$Dpi,$slot,$true,$Placement.Right,$Placement.Bottom,$Placement.X,$Placement.Y)
            $slot=[JieShou.HudGeometry]::NearestDock($old,$WorkArea,$Placement.Vertical)
        }
        return [JieShou.HudGeometry]::Dock($WorkArea,$size,$slot,$Placement.Vertical)
    }
    [JieShou.HudGeometry]::Place($WorkArea,[Drawing.Size]::new($Width,$Height),$Dpi,$Placement.Anchor,
        $Placement.Positioned,$Placement.Right,$Placement.Bottom,$Placement.X,$Placement.Y)
}
