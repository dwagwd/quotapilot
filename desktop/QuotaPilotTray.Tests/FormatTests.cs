using System.Globalization;
using QuotaPilotTray.Core;
using Xunit;
using static QuotaPilotTray.Tests.TestSupport;

namespace QuotaPilotTray.Tests;

public class FormatTests
{
    static QuotaWindow W(double? used, bool limit = false, double? reset = null, string name = "Codex") =>
        new("id", name, null, used, reset, 300, limit);

    [Theory]
    [InlineData(4800, "1h 20m")]
    [InlineData(4799, "1h 19m")]
    [InlineData(3600, "1h 0m")]
    [InlineData(2700, "45m")]
    [InlineData(59, "<1m")]
    [InlineData(90000, "1d 1h")]
    [InlineData(172800 + 3 * 3600 + 120, "2d 3h")]
    public void CountdownEnglish(double seconds, string expected) =>
        Assert.Equal(expected, Format.Countdown(Now + seconds, Now, En));

    [Fact]
    public void CountdownChinese() => Assert.Equal("1小時20分", Format.Countdown(Now + 4800, Now, Zh));

    [Fact]
    public void CountdownIsNullWhenUnknownOrPast()
    {
        Assert.Null(Format.Countdown(null, Now, En));
        Assert.Null(Format.Countdown(Now - 5, Now, En));
        Assert.Equal("reset time unknown", Format.ResetLine(null, Now, En));
        Assert.Equal("resetting now", Format.ResetLine(Now - 5, Now, En));
        Assert.Equal("resets in 45m", Format.ResetLine(Now + 2700, Now, En));
    }

    [Theory]
    [InlineData(92.0, "92%")]
    [InlineData(91.6, "92%")]
    [InlineData(0.0, "0%")]
    [InlineData(100.0, "100%")]
    [InlineData(140.0, "100%")]
    [InlineData(-3.0, "0%")]
    public void PercentRoundsAndClamps(double value, string expected) => Assert.Equal(expected, Format.Percent(value));

    [Fact]
    public void PercentOfNullIsDash() => Assert.Equal("—", Format.Percent(null));

    [Theory]
    [InlineData(null, false, Severity.Unknown)]
    [InlineData(10.0, false, Severity.Ok)]
    [InlineData(74.9, false, Severity.Ok)]
    [InlineData(75.0, false, Severity.Warning)]
    [InlineData(89.9, false, Severity.Warning)]
    [InlineData(90.0, false, Severity.Critical)]
    [InlineData(100.0, false, Severity.Critical)]
    [InlineData(20.0, true, Severity.Critical)]
    [InlineData(null, true, Severity.Critical)]
    public void SeverityThresholds(double? used, bool limit, Severity expected) => Assert.Equal(expected, Format.SeverityOf(W(used, limit)));

    [Theory]
    [InlineData(0.0, "0")]
    [InlineData(999.0, "999")]
    [InlineData(1234.0, "1.2K")]
    [InlineData(766622804.0, "766.6M")]
    [InlineData(2.5e9, "2.5B")]
    public void CompactNumbers(double n, string expected) => Assert.Equal(expected, Format.Compact(n));

    [Theory]
    [InlineData(300, "5h")]
    [InlineData(10080, "7d")]
    [InlineData(45, "45m")]
    public void DurationLabels(int mins, string expected) => Assert.Equal(expected, Format.DurationLabel(mins, En));

    [Fact]
    public void DurationLabelNullForUnknown() => Assert.Null(Format.DurationLabel(null, En));

    [Fact]
    public void TightestPicksHighestUsageAndLimitWins()
    {
        Assert.Equal("Codex", Format.Tightest(Load("ok.json").Windows)!.Name);
        var limited = Load("limit-reached.json").Windows;
        Assert.True(Format.Tightest(limited)!.LimitReached);
        Assert.Null(Format.Tightest([W(null)]));
    }

    [Fact]
    public void TooltipShowsTightestWindow()
    {
        Assert.Equal("Codex 92% · resets 1h 20m", Format.Tooltip(Load("ok.json"), Now, En));
        Assert.Equal("Codex 92% · 1小時20分後重置", Format.Tooltip(Load("ok.json"), Now, Zh));
        Assert.Equal("QuotaPilot", Format.Tooltip(Load("empty.json"), Now, En));
    }

    [Fact]
    public void ErrorTextsUsePlainWords()
    {
        Assert.Equal("Codex not found. Install the desktop app or CLI.", Format.ErrorText("codex", "clientMissing", En));
        Assert.Equal("找不到 Codex，請先安裝桌面 App 或 CLI。", Format.ErrorText("codex", "clientMissing", Zh));
        Assert.Equal("Claude: somethingNew", Format.ErrorText("claude", "somethingNew", En));
    }

    [Theory]
    [InlineData("zh-TW", "zh-Hant")]
    [InlineData("zh-HK", "zh-Hant")]
    [InlineData("zh-Hant-TW", "zh-Hant")]
    [InlineData("zh-CN", "en")]
    [InlineData("en-US", "en")]
    [InlineData("de-DE", "en")]
    public void LanguageFollowsSystem(string culture, string expected) =>
        Assert.Equal(expected, Loc.LanguageFor(new CultureInfo(culture)));

    [Fact]
    public void EveryEnglishKeyHasChineseText()
    {
        foreach (var key in Loc.Tables["en"].Keys) Assert.True(Loc.Tables["zh-Hant"].ContainsKey(key), key);
    }
}
