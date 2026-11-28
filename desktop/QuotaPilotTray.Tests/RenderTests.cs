using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Styling;
using QuotaPilotTray.Core;
using QuotaPilotTray.UI;
using Xunit;
using static QuotaPilotTray.Tests.TestSupport;

[assembly: AvaloniaTestApplication(typeof(QuotaPilotTray.Tests.TestAppBuilder))]

namespace QuotaPilotTray.Tests;

public class TestApp : Application
{
    public override void Initialize() => Theme.Apply(this);
}

public static class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<TestApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}

/// <summary>Renders the card to PNG files (screenshots/ next to the test binary, or QUOTAPILOT_SCREENSHOT_DIR) as evidence for reviewers.</summary>
public class RenderTests
{
    static string OutDir()
    {
        var dir = Environment.GetEnvironmentVariable("QUOTAPILOT_SCREENSHOT_DIR") is { Length: > 0 } d ? d : Path.Combine(AppContext.BaseDirectory, "screenshots");
        Directory.CreateDirectory(dir);
        return dir;
    }

    [AvaloniaTheory]
    [InlineData("ok.json", "light", "en")]
    [InlineData("ok.json", "dark", "en")]
    [InlineData("ok.json", "dark", "zh")]
    [InlineData("limit-reached.json", "light", "en")]
    [InlineData("client-missing.json", "dark", "en")]
    public void RendersCardToPng(string fixture, string theme, string lang)
    {
        var loc = lang == "zh" ? Zh : En;
        var model = CardModel.From(Load(fixture), Now, loc);
        var window = new Window
        {
            Content = new CardView(model, loc), Width = CardView.CardWidth, SizeToContent = SizeToContent.Height,
            RequestedThemeVariant = theme == "dark" ? ThemeVariant.Dark : ThemeVariant.Light,
        };
        window.Show();
        var frame = window.CaptureRenderedFrame();
        Assert.NotNull(frame);
        var path = Path.Combine(OutDir(), $"card-{Path.GetFileNameWithoutExtension(fixture)}-{theme}-{lang}.png");
        frame!.Save(path);
        var info = new FileInfo(path);
        Assert.True(info.Length > 3000, "PNG looks blank: " + path);
        Assert.Equal((int)CardView.CardWidth, frame.PixelSize.Width);
        Assert.True(frame.PixelSize.Height > 150);
    }
}
