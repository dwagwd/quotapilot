using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using QuotaPilotTray.Core;

namespace QuotaPilotTray.UI;

public sealed class AboutWindow : Window
{
    public const string Website = "https://aiquotawatch.pages.dev/";
    public const string GitHub = "https://github.com/dwagwd/quotapilot";

    public AboutWindow(Loc loc, string trayVersion, string? cliVersion)
    {
        Title = loc["about.title"];
        Width = 380; SizeToContent = SizeToContent.Height; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(20) };
        stack.Children.Add(new TextBlock { Text = loc["app.name"], FontSize = 20, FontWeight = Avalonia.Media.FontWeight.SemiBold });
        stack.Children.Add(new TextBlock { Text = loc.Format("about.version", trayVersion) });
        if (cliVersion is not null) stack.Children.Add(new TextBlock { Text = loc.Format("about.cli", cliVersion) });
        stack.Children.Add(new TextBlock { Text = loc["about.privacy"], TextWrapping = Avalonia.Media.TextWrapping.Wrap, Opacity = 0.75 });
        var links = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
        var web = new Button { Content = loc["about.website"] };
        web.Click += (_, _) => Shell.OpenUrl(Website);
        var gh = new Button { Content = loc["about.github"] };
        gh.Click += (_, _) => Shell.OpenUrl(GitHub);
        var close = new Button { Content = loc["about.close"] };
        close.Click += (_, _) => Close();
        links.Children.Add(web); links.Children.Add(gh); links.Children.Add(close);
        stack.Children.Add(links);
        Content = stack;
    }
}
