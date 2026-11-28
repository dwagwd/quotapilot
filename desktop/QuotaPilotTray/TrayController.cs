using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Platform;
using Avalonia.Threading;
using QuotaPilotTray.Core;
using QuotaPilotTray.UI;

namespace QuotaPilotTray;

/// <summary>
/// Owns the tray icon, menu and card. Data comes only from <see cref="IStatusSource"/> (the bundled CLI).
/// Later windows (statistics, settings, notifications) hang off this class and share its source and strings.
/// </summary>
public sealed class TrayController : IDisposable
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(60);
    readonly IStatusSource source;
    readonly IAutostart autostart;
    readonly Loc loc;
    readonly TrayIcon tray;
    readonly CardWindow card;
    readonly NativeMenuItem autostartItem;
    readonly DispatcherTimer timer;
    StatusSnapshot? last;
    DateTime lastFetch = DateTime.MinValue;
    bool fetching;

    public TrayController(IStatusSource source, IAutostart autostart, Loc loc, bool showCardAfterFirstRead = false)
    {
        this.source = source; this.autostart = autostart; this.loc = loc;
        card = new CardWindow(loc);
        card.RefreshRequested += () => _ = RefreshAsync();
        card.SetModel(CardModel.Loading(loc));

        var menu = new NativeMenu();
        var refresh = new NativeMenuItem(loc["menu.refresh"]);
        refresh.Click += (_, _) => _ = RefreshAsync();
        var stats = new NativeMenuItem(loc["menu.stats"]);
        stats.Click += (_, _) => OpenStats();
        autostartItem = new NativeMenuItem(loc[OperatingSystem.IsWindows() ? "menu.autostart.win" : "menu.autostart.linux"])
        {
            ToggleType = NativeMenuItemToggleType.CheckBox, IsChecked = autostart.IsEnabled, IsEnabled = autostart.IsSupported,
        };
        autostartItem.Click += (_, _) => ToggleAutostart();
        var about = new NativeMenuItem(loc["menu.about"]);
        about.Click += (_, _) => new AboutWindow(loc, TrayVersion, last?.Version).Show();
        var quit = new NativeMenuItem(loc["menu.quit"]);
        quit.Click += (_, _) => Quit();
        foreach (var item in new NativeMenuItemBase[] { refresh, stats, autostartItem, new NativeMenuItemSeparator(), about, quit }) menu.Items.Add(item);

        var assembly = typeof(TrayController).Assembly.GetName().Name;
        tray = new TrayIcon
        {
            Icon = new WindowIcon(AssetLoader.Open(new Uri($"avares://{assembly}/Assets/tray.png"))),
            ToolTipText = loc["tip.none"],
            Menu = menu,
            IsVisible = true,
        };
        tray.Clicked += (_, _) => OnTrayClicked();

        timer = new DispatcherTimer { Interval = Interval };
        timer.Tick += (_, _) => _ = RefreshAsync();
        timer.Start();
        _ = FirstRefreshAsync(showCardAfterFirstRead);
    }

    async Task FirstRefreshAsync(bool showCard)
    {
        card.KeepOpen = showCard;
        await RefreshAsync();
        if (showCard && !card.IsVisible) card.Toggle();
    }

    public static string TrayVersion =>
        typeof(TrayController).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

    void OnTrayClicked()
    {
        card.Toggle();
        if (card.IsVisible && DateTime.UtcNow - lastFetch > TimeSpan.FromSeconds(15)) _ = RefreshAsync();
    }

    void OpenStats()
    {
        var problem = Shell.OpenStats(CliRunner.Locate());
        if (problem is null) return;
        card.SetModel(CardModel.Failed(loc[problem], last, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), loc));
        if (!card.IsVisible) card.Toggle();
    }

    void ToggleAutostart()
    {
        try { autostart.Set(!autostart.IsEnabled); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        autostartItem.IsChecked = autostart.IsEnabled;
    }

    public async Task RefreshAsync()
    {
        if (fetching) return;
        fetching = true;
        try
        {
            StatusResult result;
            try { result = await Task.Run(() => source.FetchAsync(CancellationToken.None)); }
            catch (Exception e) when (e is not OutOfMemoryException) { result = new StatusResult(null, "err.cliFailed", e.Message); }
            lastFetch = DateTime.UtcNow;
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (result.Snapshot is { } snapshot)
            {
                try
                {
                    tray.ToolTipText = Format.Tooltip(snapshot, now, loc);
                    card.SetModel(CardModel.From(snapshot, now, loc));
                    last = snapshot;
                }
                catch (Exception e) when (e is not OutOfMemoryException)
                {
                    tray.ToolTipText = loc["tip.error"];
                    card.SetModel(CardModel.Failed(loc.Format("err.cliFailed", e.Message), last, now, loc));
                }
            }
            else
            {
                var message = loc[result.ErrorKey ?? "err.cliBadOutput"];
                if (result.ErrorKey == "err.cliFailed") message = loc.Format("err.cliFailed", result.ErrorDetail ?? "");
                tray.ToolTipText = loc["tip.error"];
                card.SetModel(CardModel.Failed(message, last, now, loc));
            }
        }
        finally { fetching = false; }
    }

    void Quit()
    {
        Dispose();
        (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

    public void Dispose()
    {
        timer.Stop();
        tray.IsVisible = false;
        tray.Dispose();
    }
}
