using System.Globalization;

namespace QuotaPilotTray.Core;

public enum Severity { Unknown, Ok, Warning, Critical }

/// <summary>Pure formatting helpers (no UI), covered by unit tests.</summary>
public static class Format
{
    public const double WarningAt = 75;
    public const double CriticalAt = 90;

    public static Severity SeverityOf(QuotaWindow w)
    {
        if (w.LimitReached) return Severity.Critical;
        if (w.UsedPercent is not { } p) return Severity.Unknown;
        return p >= CriticalAt ? Severity.Critical : p >= WarningAt ? Severity.Warning : Severity.Ok;
    }

    /// <summary>Used share in percent for ranking; a reached limit counts as 100.</summary>
    public static double? Effective(QuotaWindow w) => w.LimitReached ? 100 : w.UsedPercent;

    public static string Percent(double? value) =>
        value is { } v && !double.IsNaN(v) ? Math.Round(Math.Clamp(v, 0, 100), MidpointRounding.AwayFromZero).ToString("0", CultureInfo.InvariantCulture) + "%" : "—";

    /// <summary>Bar fill 0..1 (a reached limit fills the bar).</summary>
    public static double Fraction(QuotaWindow w) => w.LimitReached ? 1 : w.UsedPercent is { } v ? Math.Clamp(v, 0, 100) / 100 : 0;

    /// <summary>Time until reset, e.g. "1h 20m", "2d 3h", "45m"; null when the reset time is unknown.</summary>
    public static string? Countdown(double? resetsAt, double now, Loc loc)
    {
        if (resetsAt is not { } at) return null;
        var seconds = at - now;
        if (seconds <= 0) return null;
        var minutes = (long)Math.Floor(seconds / 60);
        var days = minutes / 1440;
        var hours = minutes % 1440 / 60;
        var mins = minutes % 60;
        if (days > 0) return loc.Format("time.dh", days, hours);
        if (hours > 0) return loc.Format("time.hm", hours, mins);
        return minutes > 0 ? loc.Format("time.m", mins) : loc["time.lt1m"];
    }

    /// <summary>"resets in 1h 20m", "resetting now" or "reset time unknown".</summary>
    public static string ResetLine(double? resetsAt, double now, Loc loc)
    {
        if (resetsAt is null) return loc["card.resetUnknown"];
        var c = Countdown(resetsAt, now, loc);
        return c is null ? loc["card.resetNow"] : loc.Format("card.reset", c);
    }

    /// <summary>Window length: 300 -> "5h", 10080 -> "7d".</summary>
    public static string? DurationLabel(int? minutes, Loc loc)
    {
        if (minutes is not { } m || m <= 0) return null;
        if (m % 1440 == 0) return loc.Format("dur.d", m / 1440);
        if (m % 60 == 0) return loc.Format("dur.h", m / 60);
        return loc.Format("dur.m", m);
    }

    /// <summary>1234 -> "1.2K", 766622804 -> "766.6M".</summary>
    public static string Compact(double n)
    {
        var abs = Math.Abs(n);
        (double div, string unit) = abs >= 1e12 ? (1e12, "T") : abs >= 1e9 ? (1e9, "B") : abs >= 1e6 ? (1e6, "M") : abs >= 1e3 ? (1e3, "K") : (1, "");
        return div == 1 ? Math.Round(n).ToString("0", CultureInfo.InvariantCulture)
                        : (n / div).ToString("0.0", CultureInfo.InvariantCulture) + unit;
    }

    public static string AgentName(string? agent, Loc loc)
    {
        if (string.IsNullOrEmpty(agent)) return "";
        return loc.Has("agent." + agent) ? loc["agent." + agent] : char.ToUpperInvariant(agent[0]) + agent[1..];
    }

    /// <summary>The window closest to its limit (a reached limit wins; ties go to the earlier reset).</summary>
    public static QuotaWindow? Tightest(IEnumerable<QuotaWindow> windows) =>
        windows.Where(w => Effective(w) is not null)
               .OrderByDescending(w => Effective(w)!.Value)
               .ThenBy(w => w.ResetsAt ?? double.MaxValue)
               .FirstOrDefault();

    /// <summary>Tray tooltip: "Codex 92% · resets 1h 20m".</summary>
    public static string Tooltip(StatusSnapshot snapshot, double now, Loc loc)
    {
        var w = Tightest(snapshot.Windows);
        if (w is null) return loc["tip.none"];
        var name = AgentName(w.Name.ToLowerInvariant(), loc);
        if (name.Length == 0) name = w.Name;
        var percent = w.LimitReached ? "100%" : Percent(w.UsedPercent);
        var countdown = Countdown(w.ResetsAt, now, loc);
        return countdown is null ? loc.Format("tip.lineNoReset", name, percent) : loc.Format("tip.line", name, percent, countdown);
    }

    /// <summary>Plain-words text for one entry of the "errors" object.</summary>
    public static string ErrorText(string agent, string code, Loc loc) =>
        loc.Has("err." + code) ? loc["err." + code] : loc.Format("err.unknown", AgentName(agent, loc), code);
}
