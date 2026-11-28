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

    /// <summary>cmd.exe expands %VAR% and treats ^ & | and friends specially even inside quotes, so such paths are refused.</summary>
    public static bool IsSafeForCmd(string path) => path.IndexOfAny(['%', '^', '&', '|', '<', '>', '(', ')', '!', '"']) < 0;

    /// <summary>Arguments for cmd.exe: opens a new console window that stays open after the command.</summary>
    public static string WindowsTerminalArguments(string exe, string subcommand) =>
        $"/c start \"QuotaPilot\" cmd /k \"\"{exe}\" {subcommand}\"";

    /// <summary>Opens a terminal running <c>quotapilot stats</c>. Returns null on success, else the string key of the reason.</summary>
    public static string? OpenStats(string? cliPath)
    {
        if (cliPath is null) return "err.cliMissing";
        try
        {
            if (OperatingSystem.IsWindows())
            {
                if (!IsSafeForCmd(cliPath)) return "err.statsPath";
                Process.Start(new ProcessStartInfo("cmd.exe", WindowsTerminalArguments(cliPath, "stats")) { UseShellExecute = false, CreateNoWindow = true });
                return null;
            }
            if (!OperatingSystem.IsLinux()) return "err.statsNoTerminal";
            var script = $"{ShellQuote(cliPath)} stats; printf '\\nPress Enter to close'; read _";
            foreach (var (terminal, flag) in new[] { ("x-terminal-emulator", "-e"), ("gnome-terminal", "--"), ("konsole", "-e"), ("xfce4-terminal", "-x"), ("xterm", "-e") })
            {
                if (!OnPath(terminal)) continue;
                var info = new ProcessStartInfo(terminal) { UseShellExecute = false };
                info.ArgumentList.Add(flag); info.ArgumentList.Add("sh"); info.ArgumentList.Add("-c"); info.ArgumentList.Add(script);
                Process.Start(info);
                return null;
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        return "err.statsNoTerminal";
    }

    static bool OnPath(string name) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(d => { try { return File.Exists(Path.Combine(d, name)); } catch (ArgumentException) { return false; } });
}
