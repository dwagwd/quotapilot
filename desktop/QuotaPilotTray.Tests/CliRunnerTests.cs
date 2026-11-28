using System.Diagnostics;
using QuotaPilotTray.Core;
using Xunit;

namespace QuotaPilotTray.Tests;

public class CliRunnerTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "qp-cli-" + Guid.NewGuid().ToString("N"));
    public CliRunnerTests() => Directory.CreateDirectory(dir);
    public void Dispose() { try { Directory.Delete(dir, true); } catch (IOException) { } }

    string Touch(string name, string content = "x")
    {
        var path = Path.Combine(dir, name);
        File.WriteAllText(path, content);
        return path;
    }

    [Fact]
    public void LocateSkipsTheRunningProgramItself()
    {
        var cli = Touch(CliRunner.ExecutableName);
        // The tray itself is named like the CLI (as when a user renames it): it must never be chosen.
        Assert.Null(CliRunner.Locate(null, dir, null, cli));
        Assert.Null(CliRunner.Locate(cli, dir, null, cli));
        if (!OperatingSystem.IsLinux())
            Assert.Null(CliRunner.Locate(null, dir, null, cli.ToUpperInvariant().Replace(dir.ToUpperInvariant(), dir)));
    }

    [Fact]
    public void LocatePrefersTheFolderOfTheAppThenPath()
    {
        var beside = Touch(CliRunner.ExecutableName);
        var other = Path.Combine(dir, "other");
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(other, CliRunner.ExecutableName), "x");
        Assert.Equal(beside, CliRunner.Locate(null, dir, other, Path.Combine(dir, "QuotaPilotTray.exe")));
        Assert.Equal(Path.Combine(other, CliRunner.ExecutableName), CliRunner.Locate(null, Path.Combine(dir, "none"), other, null));
    }

    [Fact]
    public async Task ReadsOutputAndExitCode()
    {
        if (OperatingSystem.IsWindows()) return;
        var script = Touch("ok.sh", "#!/bin/sh\necho '{\"windows\":[]}'\necho oops >&2\nexit 3\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var (code, stdout, stderr, timedOut) = await CliRunner.RunAsync(script, [], TimeSpan.FromSeconds(20), CancellationToken.None);
        Assert.Equal(3, code);
        Assert.Contains("windows", stdout);
        Assert.Equal("oops", stderr.Trim());
        Assert.False(timedOut);
    }

    [Fact]
    public async Task TimesOutWhenAChildKeepsThePipeOpenAfterTheCliExits()
    {
        if (OperatingSystem.IsWindows()) return;
        // The script exits at once but leaves a background child holding stdout open.
        var script = Touch("leaky.sh", "#!/bin/sh\nsleep 8 &\nexit 0\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var watch = Stopwatch.StartNew();
        var (code, _, _, timedOut) = await CliRunner.RunAsync(script, [], TimeSpan.FromSeconds(1.5), CancellationToken.None);
        watch.Stop();
        Assert.True(timedOut);
        Assert.Equal(-1, code);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(6), "returned after " + watch.Elapsed);
    }

    [Fact]
    public async Task TimesOutOnASlowCli()
    {
        if (OperatingSystem.IsWindows()) return;
        var script = Touch("slow.sh", "#!/bin/sh\nsleep 20\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var (_, _, _, timedOut) = await CliRunner.RunAsync(script, [], TimeSpan.FromSeconds(1), CancellationToken.None);
        Assert.True(timedOut);
    }
}
