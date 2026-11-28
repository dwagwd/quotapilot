using QuotaPilotTray.Core;
using Xunit;

namespace QuotaPilotTray.Tests;

public class AutostartTests
{
    [Fact]
    public void LinuxDesktopEntryQuotesAndEscapes()
    {
        var text = LinuxAutostart.DesktopEntry("/home/a b/$x/QuotaPilot%");
        Assert.Contains("Exec=\"/home/a b/\\$x/QuotaPilot%%\"", text);
        Assert.StartsWith("[Desktop Entry]\nType=Application", text);
    }

    [Fact]
    public void LinuxToggleWritesAndRemovesFile()
    {
        var dir = Path.Combine(Path.GetTempPath(), "qp-autostart-" + Guid.NewGuid().ToString("N"));
        try
        {
            var a = new LinuxAutostart("/opt/qp/QuotaPilot", dir);
            Assert.False(a.IsEnabled);
            a.Set(true);
            Assert.True(a.IsEnabled);
            Assert.True(File.Exists(Path.Combine(dir, "autostart", "quotapilot-tray.desktop")));
            a.Set(false);
            Assert.False(a.IsEnabled);
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }

    [Fact]
    public void WindowsRunValueQuotesThePath() =>
        Assert.Equal("\"C:\\Program Files\\QuotaPilot\\QuotaPilotTray.exe\"", WindowsAutostart.Command("C:\\Program Files\\QuotaPilot\\QuotaPilotTray.exe"));

    [Fact]
    public void TerminalCommandsQuoteThePath()
    {
        Assert.Equal("/c start \"QuotaPilot\" cmd /k \"\"C:\\a b\\quotapilot.exe\" stats\"", Shell.WindowsTerminalArguments("C:\\a b\\quotapilot.exe", "stats"));
        Assert.Equal("'/a/it'\\''s'", Shell.ShellQuote("/a/it's"));
    }

    [Fact]
    public void WindowsRunValueMustMatchTheRunningExe()
    {
        var exe = "C:\\Tools\\QuotaPilotTray.exe";
        Assert.True(WindowsAutostart.Matches("\"C:\\tools\\quotapilottray.exe\"", exe));
        Assert.False(WindowsAutostart.Matches("\"C:\\Old\\QuotaPilotTray.exe\"", exe));
        Assert.False(WindowsAutostart.Matches(null, exe));
    }

    [Fact]
    public void LinuxEntryForAnotherPathDoesNotCount()
    {
        var dir = Path.Combine(Path.GetTempPath(), "qp-autostart-" + Guid.NewGuid().ToString("N"));
        try
        {
            new LinuxAutostart("/old/QuotaPilotTray", dir).Set(true);
            var now = new LinuxAutostart("/new/QuotaPilotTray", dir);
            Assert.False(now.IsEnabled);
            now.Set(true);
            Assert.True(now.IsEnabled);
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }

    [Theory]
    [InlineData("C:\\Program Files\\QuotaPilot\\quotapilot.exe", true)]
    [InlineData("C:\\100%\\quotapilot.exe", false)]
    [InlineData("C:\\a^b\\quotapilot.exe", false)]
    [InlineData("C:\\a&b\\quotapilot.exe", false)]
    public void CmdUnsafePathsAreRefused(string path, bool safe) => Assert.Equal(safe, Shell.IsSafeForCmd(path));
}
