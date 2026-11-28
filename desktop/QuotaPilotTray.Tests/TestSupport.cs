using QuotaPilotTray.Core;

namespace QuotaPilotTray.Tests;

static class TestSupport
{
    /// <summary>Time used with the fixtures: codex:primary resets exactly 1h 20m later.</summary>
    public const double Now = 1795854366.0;

    public static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));
    public static StatusSnapshot Load(string name) => StatusParser.Parse(Fixture(name));
    public static readonly Loc En = new("en");
    public static readonly Loc Zh = new("zh-Hant");
}
