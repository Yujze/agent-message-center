using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Agent Message Center")]
[assembly: AssemblyProduct("Agent Message Center")]

internal static class Launcher
{
    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string app = Path.Combine(root, "app");
        string shell = Path.Combine(root, "runtime", "powershell", "pwsh.exe");
        string python = Path.Combine(root, "runtime", "python");
        string script = Path.Combine(app, "Start-Reminder.ps1");
        try
        {
            if (!File.Exists(shell) || !File.Exists(Path.Combine(python, "python.exe")) || !File.Exists(script))
                throw new FileNotFoundException("请将整个 ZIP 解压到同一个文件夹，再打开 AMC.exe。");

            var start = new ProcessStartInfo(shell) {
                Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File \"" + script + "\" -CodexLocal",
                WorkingDirectory = app,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            start.EnvironmentVariables["PATH"] = python + ";" + start.EnvironmentVariables["PATH"];
            using (var process = Process.Start(start)) { }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "智能体消息中心", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
