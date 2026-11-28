using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using QuotaPilotTray.Core;
using QuotaPilotTray.UI;

namespace QuotaPilotTray;

public sealed class App : Application
{
    TrayController? controller;

    public override void Initialize() => Theme.Apply(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = Avalonia.Controls.ShutdownMode.OnExplicitShutdown;
            var exe = Environment.ProcessPath ?? "QuotaPilot";
            controller = new TrayController(new CliRunner(), AutostartFactory.Create(exe), Loc.FromSystem());
            desktop.Exit += (_, _) => controller.Dispose();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
