using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using QuotaPilotTray.Core;

namespace QuotaPilotTray.UI;

/// <summary>Borderless card window near the tray. It hides when it loses focus.</summary>
public sealed class CardWindow : Window
{
    DateTime hiddenAt = DateTime.MinValue;
    readonly Loc loc;
    public event Action? RefreshRequested;

    public CardWindow(Loc loc)
    {
        this.loc = loc;
        Width = CardView.CardWidth;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        ShowInTaskbar = false;
        Topmost = true;
        SystemDecorations = SystemDecorations.None;
        ShowActivated = true;
        Title = loc["app.name"];
        Deactivated += (_, _) => { if (IsVisible) { hiddenAt = DateTime.UtcNow; Hide(); } };
    }

    public void SetModel(CardModel model)
    {
        var view = new CardView(model, loc);
        view.RefreshRequested += () => RefreshRequested?.Invoke();
        Content = view;
    }

    /// <summary>Tray click: the click that deactivated the card also hides it, so a click right after a hide must not reopen it.</summary>
    public void Toggle()
    {
        if (IsVisible) { Hide(); return; }
        if (DateTime.UtcNow - hiddenAt < TimeSpan.FromMilliseconds(350)) return;
        Show();
        Activate();
        Dispatcher.UIThread.Post(PlaceNearTray, DispatcherPriority.Background);
    }

    void PlaceNearTray()
    {
        var screen = Screens.Primary ?? Screens.All.FirstOrDefault();
        if (screen is null) return;
        var area = screen.WorkingArea;
        var scale = screen.Scaling;
        var margin = (int)(12 * scale);
        var w = (int)(Bounds.Width * scale);
        var h = (int)(Bounds.Height * scale);
        Position = new PixelPoint(area.Right - w - margin, area.Bottom - h - margin);
    }
}
