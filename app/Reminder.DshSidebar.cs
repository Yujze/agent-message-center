using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace JieShou {
    public static class DshSidebar {
        // The full screen-reader labels shipped by DSH (the trailing compact labels differ).
        private static readonly Dictionary<string,string> Marks = new Dictionary<string,string>(StringComparer.Ordinal) {
            { "进行中", "running" },
            { "等待审批", "waiting" },
            { "计划待审", "waiting" },
            { "等待回答", "waiting" },
            { "已完成", "unread" },
            { "Running", "running" },
            { "Waiting for approval", "waiting" },
            { "Plan awaiting review", "waiting" },
            { "Waiting for answer", "waiting" },
            { "Completed", "unread" },
            { "実行中", "running" },
            { "承認待ち", "waiting" },
            { "計画のレビュー待ち", "waiting" },
            { "回答待ち", "waiting" },
            { "完了", "unread" },
            { "corriendo", "running" },
            { "Esperando aprobación", "waiting" },
            { "Plan pendiente de revisión", "waiting" },
            { "esperando respuesta", "waiting" },
            { "Completado", "unread" },
            { "Courir", "running" },
            { "En attente d'approbation", "waiting" },
            { "Plan en attente d'examen", "waiting" },
            { "En attente de réponse", "waiting" },
            { "Terminé", "unread" },
            { "Laufen", "running" },
            { "Warten auf Genehmigung", "waiting" },
            { "Plan wartet auf Überprüfung", "waiting" },
            { "Warte auf Antwort", "waiting" },
            { "Abgeschlossen", "unread" },
            { "Бег", "running" },
            { "Ожидание одобрения", "waiting" },
            { "План ожидает рассмотрения", "waiting" },
            { "Ожидание ответа", "waiting" },
            { "Завершено", "unread" },
            { "Correndo", "running" },
            { "Aguardando aprovação", "waiting" },
            { "Plano aguardando revisão", "waiting" },
            { "Esperando por resposta", "waiting" },
            { "Concluído", "unread" }
        };
        private static readonly Regex Subagents = new Regex(@"^(?:\d+ 个子智能体运行中|\d+ subagent running|\d+ subagents running|サブエージェント \d+ 件が実行中|Subagente \d+ ejecutándose|Subagentes \d+ ejecutándose|Sous\-agent \d+ en cours d'exécution|Sous\-agents \d+ en cours d'exécution|\d+\-Subagent läuft|\d+ Subagenten laufen|Субагент \d+ работает|Субагенты \d+ работают|\d+ subagente em execução|\d+ subagentes em execução)$");
        private static readonly Regex SessionList = new Regex(@"_(?:list|searchTree)(?:\s|$)");
        private static readonly Regex SessionRow = new Regex(@"_(?:sessionRow|searchResultRow)(?:\s|$)");
        private static readonly Regex Archived = new Regex(@"_archived(?:\s|$)");
        private static readonly Regex Heading = new Regex(@"_(slot|visuallyHidden|title|searchResultTitle|searchResultHeading)(?:\s|$)");
        private static readonly Condition Tree = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Tree);
        private static readonly Condition Item = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TreeItem);

        // Chromium may flatten the leading badge and the title into sibling text nodes.
        // Inspect only the heading, stopping as soon as the title can be resolved.
        private static IEnumerable<(string Text, string Kind)> HeadingText(AutomationElement parent, string kind) {
            var walker = TreeWalker.RawViewWalker;
            for (var child = walker.GetFirstChild(parent); child != null; child = walker.GetNextSibling(child)) {
                var info = child.Current;
                var match = Heading.Match(info.ClassName ?? "");
                string part = match.Success ? match.Groups[1].Value : kind;
                if (info.ControlType == ControlType.Text) yield return (info.Name, part);
                else if (match.Success) {
                    foreach (var token in HeadingText(child, part)) yield return token;
                }
            }
        }

        private static (string Title, string Mark) ReadRow(AutomationElement row, HashSet<string> catalog) {
            using (var tokens = HeadingText(row, "").GetEnumerator()) {
                if (!tokens.MoveNext()) return default;
                var first = tokens.Current;
                bool namedTitle = first.Kind == "title" || first.Kind == "searchResultTitle";
                string mark = null;
                bool badge = !namedTitle && (Marks.TryGetValue(first.Text, out mark) || Subagents.IsMatch(first.Text));
                if (!badge) return catalog.Contains(first.Text) ? (first.Text, null) : default;
                // A flattened session named exactly like a badge is ambiguous.
                if (first.Kind == "" && catalog.Contains(first.Text)) return default;
                if (!tokens.MoveNext()) return default;
                var next = tokens.Current;
                if (mark != null && next.Kind != "title" && next.Kind != "searchResultTitle" && Subagents.IsMatch(next.Text)) {
                    if (catalog.Contains(next.Text) || !tokens.MoveNext()) return default;
                    next = tokens.Current;
                }
                return catalog.Contains(next.Text) ? (next.Text, mark) : default;
            }
        }

        public static string MatchTitle(AutomationElement row, HashSet<string> catalog) => ReadRow(row, catalog).Title;

        public static Task<Dictionary<string,string>> ReadAsync(string[] titles) => Task.Run(() => {
            var catalog = new HashSet<string>(titles, StringComparer.Ordinal);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var result = new Dictionary<string,string>(StringComparer.Ordinal);
            string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "DeepSeek Harness", "DeepSeek Harness.exe");
            foreach (var process in Process.GetProcessesByName("DeepSeek Harness")) {
                using (process) {
                    try {
                        if (process.MainWindowHandle == IntPtr.Zero || !string.Equals(process.MainModule.FileName,
                            executable, StringComparison.OrdinalIgnoreCase)) continue;
                        var window = AutomationElement.FromHandle(process.MainWindowHandle);
                        foreach (AutomationElement tree in window.FindAll(TreeScope.Descendants, Tree)) {
                            if (!SessionList.IsMatch(tree.Current.ClassName)) continue;
                            foreach (AutomationElement row in tree.FindAll(TreeScope.Descendants, Item)) {
                                string cls = row.Current.ClassName;
                                if (!SessionRow.IsMatch(cls) || Archived.IsMatch(cls)) continue;
                                var info = ReadRow(row, catalog);
                                if (info.Title == null) continue;
                                if (!seen.Add(info.Title)) result.Remove(info.Title);
                                else if (info.Mark != null && (info.Mark != "unread" || !row.TryGetCurrentPattern(
                                    SelectionItemPattern.Pattern, out var selection) || !((SelectionItemPattern)selection).Current.IsSelected))
                                    result.Add(info.Title, info.Mark);
                            }
                        }
                    } catch (Exception ex) when (ex is ElementNotAvailableException || ex is InvalidOperationException ||
                        ex is UnauthorizedAccessException || ex is System.ComponentModel.Win32Exception ||
                        ex is System.Runtime.InteropServices.COMException) { result.Clear(); break; }
                }
            }
            return result;
        });
    }
}
