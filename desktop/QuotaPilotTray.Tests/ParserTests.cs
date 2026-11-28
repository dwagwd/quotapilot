using QuotaPilotTray.Core;
using Xunit;
using static QuotaPilotTray.Tests.TestSupport;

namespace QuotaPilotTray.Tests;

public class ParserTests
{
    [Fact]
    public void ParsesWindowsTokensRouterAndVersion()
    {
        var s = Load("ok.json");
        Assert.Equal("0.9.7", s.Version);
        Assert.Equal(4, s.Windows.Count);
        var w = s.Windows[0];
        Assert.Equal("codex:primary", w.Id);
        Assert.Equal("Codex", w.Name);
        Assert.Equal("Plus", w.PlanName);
        Assert.Equal(92, w.UsedPercent);
        Assert.Equal(300, w.WindowDurationMins);
        Assert.False(w.LimitReached);
        Assert.Equal(1795859166, w.ResetsAt);
        Assert.Equal(766622804, s.Tokens!.Total);
        Assert.Equal(24, s.Tokens.Hours);
        Assert.Equal("claude", s.Router!.Agent);
        Assert.Equal("mostHeadroom", s.Router.Reason);
        Assert.Empty(s.Errors);
    }

    [Fact]
    public void KeepsFractionalResetTimes()
    {
        Assert.Equal(1795857600.28, Load("ok.json").Windows[2].ResetsAt!.Value, 2);
    }

    [Fact]
    public void ReadsClientMissingError()
    {
        var s = Load("client-missing.json");
        Assert.Equal("clientMissing", s.Errors["codex"]);
        Assert.Single(s.Windows);
    }

    [Fact]
    public void ReadsLimitReachedAndNullFields()
    {
        var s = Load("limit-reached.json");
        Assert.True(s.Windows[0].LimitReached);
        var n = s.Windows[1];
        Assert.Null(n.UsedPercent); Assert.Null(n.ResetsAt); Assert.Null(n.PlanName); Assert.Null(n.WindowDurationMins);
        Assert.Null(s.Router!.Agent);
        Assert.Equal("somethingNew", s.Errors["claude"]);
    }

    [Fact]
    public void AcceptsEmptyWindowsWithErrors()
    {
        var s = Load("empty.json");
        Assert.Empty(s.Windows);
        Assert.Null(s.Tokens);
        Assert.Null(s.Router);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{\"hello\":1}")]
    public void RejectsOtherOutput(string text) => Assert.Throws<FormatException>(() => StatusParser.Parse(text));
}
