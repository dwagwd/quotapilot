using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace QuotaPilotTray.UI;

/// <summary>Fluent base theme plus QuotaPilot's own colors for light and dark; the system theme decides which one is used.</summary>
public static class Theme
{
    public static void Apply(Application app)
    {
        app.Styles.Add(new FluentTheme());
        app.RequestedThemeVariant = ThemeVariant.Default;
        app.Resources.ThemeDictionaries[ThemeVariant.Light] = Palette("#FFFFFF", "#D9D9DE", "#1C1C1E", "#6B6B73", "#E6E6EA", "#2E9E5B", "#D98A00", "#D13438", "#9A9AA2");
        app.Resources.ThemeDictionaries[ThemeVariant.Dark] = Palette("#242426", "#3D3D42", "#F2F2F5", "#9B9BA4", "#3A3A3E", "#3DBE73", "#F0A429", "#F4585C", "#7C7C85");
    }

    static ResourceDictionary Palette(string bg, string border, string text, string muted, string track, string ok, string warn, string danger, string unknown)
    {
        static SolidColorBrush B(string hex) => new(Color.Parse(hex));
        return new ResourceDictionary
        {
            ["QpBg"] = B(bg), ["QpBorder"] = B(border), ["QpText"] = B(text), ["QpMuted"] = B(muted), ["QpTrack"] = B(track),
            ["QpOk"] = B(ok), ["QpWarn"] = B(warn), ["QpDanger"] = B(danger), ["QpUnknown"] = B(unknown),
        };
    }
}
