namespace QuotaPilotTray.Core;

public sealed record WindowRow(string Title, string Percent, double Fraction, Severity Severity, string ResetLine);

/// <summary>Everything the card shows, already formatted; the view only draws it.</summary>
public sealed record CardModel(IReadOnlyList<WindowRow> Rows, string? TokensLine, string? RouterLine, IReadOnlyList<string> Errors,
                               string StatusLine, string Title)
{
    public static CardModel Loading(Loc loc) =>
        new([], null, null, [], loc["card.loading"], loc["app.name"]);

    /// <summary>A failed read; keeps the last good snapshot visible when there is one.</summary>
    public static CardModel Failed(string message, StatusSnapshot? last, double now, Loc loc)
    {
        var baseModel = last is null ? Loading(loc) with { StatusLine = "" } : From(last, now, loc);
        return baseModel with { Errors = [message, .. baseModel.Errors] };
    }

    public static CardModel From(StatusSnapshot s, double now, Loc loc, double? readAt = null)
    {
        var rows = s.Windows.Select(w =>
        {
            var parts = new List<string> { w.Name };
            if (!string.IsNullOrEmpty(w.PlanName)) parts.Add(w.PlanName!);
            if (Format.DurationLabel(w.WindowDurationMins, loc) is { } d) parts.Add(d);
            var percent = w.LimitReached ? "100%" : Format.Percent(w.UsedPercent);
            var reset = Format.ResetLine(w.ResetsAt, now, loc);
            if (w.LimitReached) reset = loc["card.limit"] + " · " + reset;
            return new WindowRow(string.Join(" · ", parts), percent, Format.Fraction(w), Format.SeverityOf(w), reset);
        }).ToList();

        string? tokens = s.Tokens is { } t ? loc.Format("card.tokens", t.Hours.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture)) + ": " + Format.Compact(t.Total) : null;

        string? router = null;
        if (s.Router is { } r)
        {
            if (r.Agent is { Length: > 0 } agent)
            {
                router = loc["card.suggest"] + ": " + Format.AgentName(agent, loc);
                if (r.Reason is { } reason && loc.Has("reason." + reason)) router += " (" + loc["reason." + reason] + ")";
            }
            else
            {
                router = loc["card.suggest.none"];
            }
        }

        var errors = s.Errors.Select(e => Format.ErrorText(e.Key, e.Value, loc)).ToList();
        var time = DateTimeOffset.FromUnixTimeSeconds((long)(readAt ?? s.GeneratedAt)).ToLocalTime().ToString("HH:mm");
        var status = rows.Count == 0 && errors.Count == 0 ? loc["card.noWindows"] : loc.Format("card.updated", time);
        return new CardModel(rows, tokens, router, errors, status, loc["app.name"]);
    }
}
