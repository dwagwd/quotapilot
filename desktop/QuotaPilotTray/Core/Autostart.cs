using System.Diagnostics.CodeAnalysis;
using System.Text;

namespace QuotaPilotTray.Core;

public interface IAutostart
{
    bool IsSupported { get; }
    bool IsEnabled { get; }
    void Set(bool enabled);
}

public static class AutostartFactory
{
    public static IAutostart Create(string exePath)
    {
        if (OperatingSystem.IsWindows()) return new WindowsAutostart(exePath);
        if (OperatingSystem.IsLinux()) return new LinuxAutostart(exePath);
        return new NoAutostart();
    }
}

sealed class NoAutostart : IAutostart
{
    public bool IsSupported => false;
    public bool IsEnabled => false;
    public void Set(bool enabled) { }
}

/// <summary>HKCU\Software\Microsoft\Windows\CurrentVersion\Run, value "QuotaPilot".</summary>
public sealed class WindowsAutostart(string exePath) : IAutostart
{
    public const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "QuotaPilot";
    public bool IsSupported => OperatingSystem.IsWindows();

    public static string Command(string exePath) => "\"" + exePath + "\"";

    /// <summary>True only when the stored command starts this exact program; a value left by a moved or older copy does not count.</summary>
    public static bool Matches(string? stored, string exePath) =>
        stored is not null && string.Equals(stored.Trim(), Command(exePath), StringComparison.OrdinalIgnoreCase);

    public bool IsEnabled
    {
        get
        {
            if (!OperatingSystem.IsWindows()) return false;
            return Matches(Read(), exePath);
        }
    }

    [SuppressMessage("Interoperability", "CA1416")]
    string? Read()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(KeyPath);
        return key?.GetValue(ValueName) as string;
    }

    [SuppressMessage("Interoperability", "CA1416")]
    public void Set(bool enabled)
    {
        if (!OperatingSystem.IsWindows()) return;
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(KeyPath);
        if (enabled) key.SetValue(ValueName, Command(exePath));
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

/// <summary>~/.config/autostart/quotapilot-tray.desktop (XDG autostart).</summary>
public sealed class LinuxAutostart(string exePath, string? configHome = null) : IAutostart
{
    public bool IsSupported => true;

    string FilePath
    {
        get
        {
            var home = configHome ?? Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
            if (string.IsNullOrEmpty(home))
                home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            return Path.Combine(home, "autostart", "quotapilot-tray.desktop");
        }
    }

    public bool IsEnabled
    {
        get
        {
            try { return File.Exists(FilePath) && File.ReadAllText(FilePath).Contains(ExecLine(exePath) + "\n", StringComparison.Ordinal); }
            catch (IOException) { return false; }
        }
    }

    static string ExecLine(string exePath)
    {
        var entry = DesktopEntry(exePath);
        return entry.Split('\n').First(l => l.StartsWith("Exec=", StringComparison.Ordinal));
    }

    /// <summary>Exec values quote the path and escape the characters the desktop-entry spec reserves.</summary>
    public static string DesktopEntry(string exePath)
    {
        var escaped = new StringBuilder();
        foreach (var c in exePath)
        {
            if (c is '"' or '`' or '$' or '\\') escaped.Append('\\').Append(c);
            else if (c == '%') escaped.Append("%%");
            else escaped.Append(c);
        }
        return "[Desktop Entry]\nType=Application\nName=QuotaPilot\nComment=Codex and Claude Code quota in the tray\n" +
               $"Exec=\"{escaped}\"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n";
    }

    public void Set(bool enabled)
    {
        if (enabled)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, DesktopEntry(exePath), new UTF8Encoding(false));
        }
        else if (File.Exists(FilePath))
        {
            File.Delete(FilePath);
        }
    }
}
