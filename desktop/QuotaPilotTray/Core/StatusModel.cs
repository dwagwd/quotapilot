using System.Text.Json;

namespace QuotaPilotTray.Core;

/// <summary>One quota window from <c>quotapilot status --json</c>.</summary>
public sealed record QuotaWindow(string Id, string Name, string? PlanName, double? UsedPercent, double? ResetsAt,
                                 int? WindowDurationMins, bool LimitReached);

public sealed record TokenTotals(double Hours, double Total);

public sealed record RouterInfo(string? Agent, string? Reason);

/// <summary>The parts of <c>status --json</c> the tray shows. Everything else in the output is ignored.</summary>
public sealed record StatusSnapshot(string? Version, double GeneratedAt, IReadOnlyList<QuotaWindow> Windows,
                                    TokenTotals? Tokens, RouterInfo? Router, IReadOnlyDictionary<string, string> Errors);

public static class StatusParser
{
    /// <summary>Parses the JSON; throws <see cref="FormatException"/> when it is not a status object.</summary>
    public static StatusSnapshot Parse(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch (JsonException e) { throw new FormatException("Not JSON: " + e.Message, e); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new FormatException("Status JSON is not an object");
            if (!root.TryGetProperty("windows", out var windowsElement) && !root.TryGetProperty("errors", out _))
                throw new FormatException("Status JSON has neither windows nor errors");

            var windows = new List<QuotaWindow>();
            if (windowsElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var w in windowsElement.EnumerateArray())
                {
                    if (w.ValueKind != JsonValueKind.Object) continue;
                    var id = Str(w, "id") ?? "";
                    windows.Add(new QuotaWindow(id, Str(w, "name") ?? id, Str(w, "planName"), Num(w, "usedPercent"),
                        Num(w, "resetsAt"), Num(w, "windowDurationMins") is { } m ? (int)m : null,
                        w.TryGetProperty("limitReached", out var lr) && lr.ValueKind == JsonValueKind.True));
                }
            }

            TokenTotals? tokens = null;
            if (root.TryGetProperty("tokens", out var t) && t.ValueKind == JsonValueKind.Object)
            {
                double total = 0;
                if (t.TryGetProperty("total", out var tt) && tt.ValueKind == JsonValueKind.Object) total = Num(tt, "total") ?? 0;
                tokens = new TokenTotals(Num(t, "hours") ?? 24, total);
            }

            RouterInfo? router = null;
            if (root.TryGetProperty("router", out var r) && r.ValueKind == JsonValueKind.Object)
                router = new RouterInfo(Str(r, "agent"), Str(r, "reason"));

            var errors = new SortedDictionary<string, string>(StringComparer.Ordinal);
            if (root.TryGetProperty("errors", out var e) && e.ValueKind == JsonValueKind.Object)
                foreach (var p in e.EnumerateObject())
                    if (p.Value.ValueKind == JsonValueKind.String) errors[p.Name] = p.Value.GetString() ?? "";

            return new StatusSnapshot(Str(root, "version"), Num(root, "generatedAt") ?? 0, windows, tokens, router, errors);
        }
    }

    static string? Str(JsonElement o, string name) =>
        o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static double? Num(JsonElement o, string name) =>
        o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d) ? d : null;
}
