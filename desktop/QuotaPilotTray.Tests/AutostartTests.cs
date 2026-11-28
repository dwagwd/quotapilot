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
        Assert.Equal("\"C:\\Program Files\\QuotaPilot\\QuotaPilot.exe\"", WindowsAutostart.Command("C:\\Program Files\\QuotaPilot\\QuotaPilot.exe"));

    [Fact]
    public void TerminalCommandsQuoteThePath()
    {
        Assert.Equal("/c start \"QuotaPilot\" cmd /k \"\"C:\\a b\\quotapilot.exe\" stats\"", Shell.WindowsTerminalArguments("C:\\a b\\quotapilot.exe", "stats"));
        Assert.Equal("'/a/it'\\''s'", Shell.ShellQuote("/a/it's"));
    }
}
