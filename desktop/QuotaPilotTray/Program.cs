using Avalonia;

namespace QuotaPilotTray;

static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // One tray icon per user session.
        using var mutex = new Mutex(true, "QuotaPilotTray-single-instance", out var first);
        if (!first) return;
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect();
}
