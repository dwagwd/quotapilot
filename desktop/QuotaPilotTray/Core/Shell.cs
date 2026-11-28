using System.Diagnostics;

namespace QuotaPilotTray.Core;

/// <summary>Opens links and a terminal running <c>quotapilot stats</c>.</summary>
public static class Shell
{
    public static void OpenUrl(string url)
    {
        if (!url.StartsWith("https://", StringComparison.Ordinal)) return;
        try
        {
            if (OperatingSystem.IsWindows()) Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            else if (OperatingSystem.IsMacOS()) Process.Start("open", url);
            else Process.Start("xdg-open", url);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    public static string ShellQuote(string s) => "'" + s.Replace("'", "'\\''") + "'";

    /// <summary>Arguments for cmd.exe: opens a new console window that stays open after the command.</summary>
    public static string WindowsTerminalArguments(string exe, string subcommand) =>
        $"/c start \"QuotaPilot\" cmd /k \"\"{exe}\" {subcommand}\"";

    public static bool OpenStats(string? cliPath)
    {
        if (cliPath is null) return false;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                Process.Start(new ProcessStartInfo("cmd.exe", WindowsTerminalArguments(cliPath, "stats")) { UseShellExecute = false, CreateNoWindow = true });
                return true;
            }
            if (!OperatingSystem.IsLinux()) return false;
            var script = $"{ShellQuote(cliPath)} stats; printf '\\nPress Enter to close'; read _";
            foreach (var (terminal, flag) in new[] { ("x-terminal-emulator", "-e"), ("gnome-terminal", "--"), ("konsole", "-e"), ("xfce4-terminal", "-x"), ("xterm", "-e") })
            {
                if (!OnPath(terminal)) continue;
                var info = new ProcessStartInfo(terminal) { UseShellExecute = false };
                info.ArgumentList.Add(flag); info.ArgumentList.Add("sh"); info.ArgumentList.Add("-c"); info.ArgumentList.Add(script);
                Process.Start(info);
                return true;
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        return false;
    }

    static bool OnPath(string name) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(d => { try { return File.Exists(Path.Combine(d, name)); } catch (ArgumentException) { return false; } });
}
