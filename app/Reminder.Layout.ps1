function New-ReminderHudPlacement {
    @{ Positioned=$false; Right=$true; Bottom=$true; X=0; Y=0 }
}

function New-ReminderHudForm {
    if (!('JieShou.HudForm' -as [type])) {
        $source = @'
using System.Windows.Forms;
namespace JieShou {
    public sealed class HudForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override void WndProc(ref Message message) {
            // WM_MOUSEACTIVATE -> MA_NOACTIVATE, which still delivers the mouse click.
            if (message.Msg == 0x0021) {
                message.Result = new System.IntPtr(3);
                return;
            }
            base.WndProc(ref message);
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

function Set-ReminderHudPlacement($Placement, [Drawing.Rectangle]$Bounds, [Drawing.Rectangle]$WorkArea) {
    $Placement.Positioned = $true
    $Placement.Right = ($Bounds.Left + $Bounds.Width / 2) -ge ($WorkArea.Left + $WorkArea.Width / 2)
    $Placement.Bottom = ($Bounds.Top + $Bounds.Height / 2) -ge ($WorkArea.Top + $WorkArea.Height / 2)
    $Placement.X = if ($Placement.Right) { $Bounds.Right } else { $Bounds.Left }
    $Placement.Y = if ($Placement.Bottom) { $Bounds.Bottom } else { $Bounds.Top }
}

function Get-ReminderHudBounds($Placement, [Drawing.Rectangle]$WorkArea, [int]$Width, [int]$Height) {
    $Width = [Math]::Max(1, [Math]::Min($Width, $WorkArea.Width))
    $Height = [Math]::Max(1, [Math]::Min($Height, $WorkArea.Height))
    if (!$Placement.Positioned) {
        $x = $WorkArea.Right - $Width - 12
        $y = $WorkArea.Bottom - $Height - 12
    } else {
        $x = if ($Placement.Right) { $Placement.X - $Width } else { $Placement.X }
        $y = if ($Placement.Bottom) { $Placement.Y - $Height } else { $Placement.Y }
    }
    $x = [Math]::Clamp([int]$x, $WorkArea.Left, $WorkArea.Right - $Width)
    $y = [Math]::Clamp([int]$y, $WorkArea.Top, $WorkArea.Bottom - $Height)
    [Drawing.Rectangle]::new($x, $y, $Width, $Height)
}
