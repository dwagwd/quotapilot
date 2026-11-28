using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using QuotaPilotTray.Core;

namespace QuotaPilotTray.UI;

/// <summary>The card's content, drawn from a <see cref="CardModel"/>. Colors come from the theme resources in <see cref="Theme"/>.</summary>
public sealed class CardView : UserControl
{
    public const double CardWidth = 360;
    readonly string refreshLabel;
    public event Action? RefreshRequested;

    public CardView(CardModel model, Loc loc)
    {
        refreshLabel = loc["card.refresh"];
        Width = CardWidth;
        Content = Build(model);
    }

    void Themed(AvaloniaObject target, AvaloniaProperty property, string key)
    {
        target.Bind(property, this.GetResourceObservable(key));
    }

    TextBlock Text(string text, string colorKey, double size = 13, FontWeight weight = FontWeight.Normal)
    {
        var t = new TextBlock { Text = text, FontSize = size, FontWeight = weight, TextWrapping = TextWrapping.Wrap };
        Themed(t, TextBlock.ForegroundProperty, colorKey);
        return t;
    }

    static string SeverityKey(Severity s) => s switch { Severity.Critical => "QpDanger", Severity.Warning => "QpWarn", Severity.Ok => "QpOk", _ => "QpUnknown" };

    Control Build(CardModel m)
    {
        var stack = new StackPanel { Spacing = 14 };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        header.Children.Add(Text(m.Title, "QpText", 16, FontWeight.SemiBold));
        var status = Text(m.StatusLine, "QpMuted", 12);
        status.VerticalAlignment = VerticalAlignment.Center;
        status.Margin = new Thickness(0, 0, 8, 0);
        Grid.SetColumn(status, 1);
        header.Children.Add(status);
        var refresh = new Button { Content = "↻", Padding = new Thickness(6, 0), MinHeight = 24, FontSize = 14 };
        ToolTip.SetTip(refresh, refreshLabel);
        refresh.Click += (_, _) => RefreshRequested?.Invoke();
        Grid.SetColumn(refresh, 2);
        header.Children.Add(refresh);
        stack.Children.Add(header);

        foreach (var row in m.Rows) stack.Children.Add(Row(row));

        if (m.TokensLine is not null || m.RouterLine is not null)
        {
            var sep = new Border { Height = 1 };
            Themed(sep, Border.BackgroundProperty, "QpBorder");
            stack.Children.Add(sep);
            if (m.TokensLine is not null) stack.Children.Add(Text(m.TokensLine, "QpText"));
            if (m.RouterLine is not null) stack.Children.Add(Text(m.RouterLine, "QpText", 13, FontWeight.SemiBold));
        }

        foreach (var error in m.Errors) stack.Children.Add(Text(error, "QpDanger", 12));

        var card = new Border { Padding = new Thickness(16), BorderThickness = new Thickness(1), Child = stack };
        Themed(card, Border.BackgroundProperty, "QpBg");
        Themed(card, Border.BorderBrushProperty, "QpBorder");
        return card;
    }

    Control Row(WindowRow row)
    {
        var color = SeverityKey(row.Severity);
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        top.Children.Add(Text(row.Title, "QpText", 13));
        var percent = Text(row.Percent, color, 13, FontWeight.Bold);
        Grid.SetColumn(percent, 1);
        top.Children.Add(percent);

        // The fill is a star-sized column, so no measuring is needed.
        var f = Math.Clamp(row.Fraction, 0, 1);
        var bar = new Grid { Height = 6, ColumnDefinitions = new ColumnDefinitions { new(f, GridUnitType.Star), new(1 - f, GridUnitType.Star) } };
        var track = new Border { CornerRadius = new CornerRadius(3) };
        Themed(track, Border.BackgroundProperty, "QpTrack");
        Grid.SetColumnSpan(track, 2);
        bar.Children.Add(track);
        if (f > 0)
        {
            var fill = new Border { CornerRadius = new CornerRadius(3) };
            Themed(fill, Border.BackgroundProperty, color);
            bar.Children.Add(fill);
        }

        return new StackPanel { Spacing = 4, Children = { top, bar, Text(row.ResetLine, "QpMuted", 12) } };
    }
}
