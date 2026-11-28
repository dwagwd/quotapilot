using QuotaPilotTray.Core;
using Xunit;
using static QuotaPilotTray.Tests.TestSupport;

namespace QuotaPilotTray.Tests;

public class CardModelTests
{
    [Fact]
    public void RowsCarryNamePlanBarAndCountdown()
    {
        var m = CardModel.From(Load("ok.json"), Now, En);
        Assert.Equal(4, m.Rows.Count);
        var r = m.Rows[0];
        Assert.Equal("Codex · Plus · 5h", r.Title);
        Assert.Equal("92%", r.Percent);
        Assert.Equal(0.92, r.Fraction, 3);
        Assert.Equal(Severity.Critical, r.Severity);
        Assert.Equal("resets in 1h 20m", r.ResetLine);
        Assert.Equal(Severity.Ok, m.Rows[1].Severity);
        Assert.Equal(Severity.Warning, m.Rows[3].Severity);
        Assert.Equal("Tokens, last 24 h: 766.6M", m.TokensLine);
        Assert.Equal("Use next: Claude (most room left)", m.RouterLine);
        Assert.Empty(m.Errors);
    }

    [Fact]
    public void ClientMissingBecomesPlainSentence()
    {
        var m = CardModel.From(Load("client-missing.json"), Now, En);
        Assert.Equal(["Codex not found. Install the desktop app or CLI."], m.Errors);
        Assert.Single(m.Rows);
    }

    [Fact]
    public void LimitReachedIsRedAndFull()
    {
        var m = CardModel.From(Load("limit-reached.json"), Now, En);
        Assert.Equal(Severity.Critical, m.Rows[0].Severity);
        Assert.Equal(1.0, m.Rows[0].Fraction);
        Assert.StartsWith("Limit reached · resets in", m.Rows[0].ResetLine);
        Assert.Equal("—", m.Rows[1].Percent);
        Assert.Equal(Severity.Unknown, m.Rows[1].Severity);
        Assert.Equal("reset time unknown", m.Rows[1].ResetLine);
        Assert.Equal("No agent has room right now", m.RouterLine);
        Assert.Equal("Claude: somethingNew", m.Errors[0]);
    }

    [Fact]
    public void FailureKeepsLastGoodRows()
    {
        var m = CardModel.Failed("quotapilot did not answer in time.", Load("ok.json"), Now, En);
        Assert.Equal(4, m.Rows.Count);
        Assert.Equal("quotapilot did not answer in time.", m.Errors[0]);
        Assert.Empty(CardModel.Failed("x", null, Now, En).Rows);
    }

    [Fact]
    public void ChineseCard()
    {
        var m = CardModel.From(Load("ok.json"), Now, Zh);
        Assert.Equal("1小時20分後重置", m.Rows[0].ResetLine);
        Assert.Equal("建議使用: Claude (剩餘額度最多)", m.RouterLine);
    }
}
