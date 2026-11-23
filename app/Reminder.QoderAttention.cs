using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace JieShou {
    // Qoder exposes pending interactions on its native sidebar. Database receipts
    // describe read state; the live waiting indicator is a separate signal.
    public static class QoderAttention {
        private static readonly Regex ChatRoute = new Regex(@"^#/chat/([a-zA-Z0-9_-]{1,128})(?:\?|$)");
        private static readonly Condition Status = new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.StatusBar);
        private static readonly Condition Link = new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Hyperlink);

        private static string SessionId(AutomationElement indicator) {
            var walker = TreeWalker.RawViewWalker;
            for (var node = indicator; node != null; node = walker.GetParent(node)) {
                if (!node.Current.ClassName.Contains("group/work-directory-chat",StringComparison.Ordinal)) continue;
                foreach (AutomationElement link in node.FindAll(TreeScope.Descendants,Link)) {
                    if (!link.TryGetCurrentPattern(ValuePattern.Pattern,out var value)) continue;
                    string url = ((ValuePattern)value).Current.Value;
                    int start = url.IndexOf('#');
                    if (start < 0) continue;
                    var match = ChatRoute.Match(url.Substring(start));
                    if (match.Success) return match.Groups[1].Value;
                }
                break;
            }
            return null;
        }
        internal static void ReadWindow(AutomationElement window, HashSet<string> waiting) {
            foreach (AutomationElement badge in window.FindAll(TreeScope.Descendants,Status)) {
                // The waiting badge has role=status and text-warning in all locales.
                if (Array.IndexOf(badge.Current.ClassName.Split(' '),"text-warning") < 0) continue;
                var id = SessionId(badge);
                if (id != null) waiting.Add(id);
            }
        }
        public static Task<string[]> ReadAsync() => Task.Run(() => {
            var waiting = new HashSet<string>(StringComparer.Ordinal);
            string install = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","Qoder") + Path.DirectorySeparatorChar;
            foreach (var process in Process.GetProcessesByName("Qoder")) {
                using (process) {
                    try {
                        if (process.MainWindowHandle == IntPtr.Zero || !process.MainModule.FileName.StartsWith(install,StringComparison.OrdinalIgnoreCase)) continue;
                        ReadWindow(AutomationElement.FromHandle(process.MainWindowHandle),waiting);
                    } catch (Exception ex) when (ex is ElementNotAvailableException || ex is InvalidOperationException ||
                        ex is UnauthorizedAccessException || ex is System.ComponentModel.Win32Exception ||
                        ex is System.Runtime.InteropServices.COMException) { }
                }
            }
            var result = new string[waiting.Count]; waiting.CopyTo(result); Array.Sort(result,StringComparer.Ordinal);
            return result;
        });
    }
}
