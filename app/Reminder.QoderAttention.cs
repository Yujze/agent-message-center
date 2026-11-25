using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace JieShou {
    public sealed class QoderSnapshot {
        public Dictionary<string,string> Badges { get; } = new Dictionary<string,string>(StringComparer.Ordinal);
        public long StartedAt { get; internal set; }
    }

    // Use only status elements belonging to a sidebar row with a chat link.
    public static class QoderAttention {
        private static readonly Regex ChatRoute = new Regex(@"^#/chat/([a-zA-Z0-9_-]{1,128})(?:\?|$)");
        private static readonly Condition Status = new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.StatusBar);
        private static readonly Condition Link = new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Hyperlink);

        private static string SessionId(AutomationElement indicator) {
            var walker = TreeWalker.RawViewWalker;
            for (var node = indicator; node != null; node = walker.GetParent(node)) {
                if (Array.IndexOf(node.Current.ClassName.Split(' '),"group/work-directory-chat") < 0) continue;
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
        internal static void ReadWindow(AutomationElement window, Dictionary<string,string> badges) {
            foreach (AutomationElement badge in window.FindAll(TreeScope.Descendants,Status)) {
                var classes = new HashSet<string>(badge.Current.ClassName.Split(' '),StringComparer.Ordinal);
                string state;
                if (classes.Contains("text-warning")) state = "waiting";
                else if (classes.Contains("text-text-tertiary") && classes.Contains("place-items-center") &&
                         classes.Contains("pointer-events-none") && classes.Contains("size-4")) state = "running";
                else continue;
                var id = SessionId(badge);
                if (id != null && (!badges.ContainsKey(id) || state == "waiting")) badges[id] = state;
            }
        }
        public static Task<QoderSnapshot> ReadAsync() => Task.Run(() => {
            var result = new QoderSnapshot();
            string install = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","Qoder") + Path.DirectorySeparatorChar;
            foreach (var process in Process.GetProcessesByName("Qoder")) {
                using (process) {
                    try {
                        if (process.MainWindowHandle == IntPtr.Zero || !process.MainModule.FileName.StartsWith(install,StringComparison.OrdinalIgnoreCase)) continue;
                        long start = new DateTimeOffset(process.StartTime).ToUnixTimeMilliseconds();
                        if (result.StartedAt == 0 || start < result.StartedAt) result.StartedAt = start;
                        ReadWindow(AutomationElement.FromHandle(process.MainWindowHandle),result.Badges);
                    } catch (Exception ex) when (ex is ElementNotAvailableException || ex is InvalidOperationException ||
                        ex is UnauthorizedAccessException || ex is System.ComponentModel.Win32Exception ||
                        ex is System.Runtime.InteropServices.COMException) { }
                }
            }
            return result;
        });
    }
}
