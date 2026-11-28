using System.Diagnostics;
using System.Text;

namespace QuotaPilotTray.Core;

public sealed record StatusResult(StatusSnapshot? Snapshot, string? ErrorKey, string? ErrorDetail);

public interface IStatusSource
{
    Task<StatusResult> FetchAsync(CancellationToken ct);
}

/// <summary>Runs the bundled command-line tool. The tray never reads quota itself and opens no network connection.</summary>
public sealed class CliRunner : IStatusSource
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);

    public static string ExecutableName => OperatingSystem.IsWindows() ? "quotapilot.exe" : "quotapilot";

    /// <summary>quotapilot next to this app, else on PATH. QUOTAPILOT_TRAY_CLI overrides both (development and tests).</summary>
    public static string? Locate() => Locate(
        Environment.GetEnvironmentVariable("QUOTAPILOT_TRAY_CLI"),
        Environment.ProcessPath is { Length: > 0 } p ? Path.GetDirectoryName(p) : AppContext.BaseDirectory,
        Environment.GetEnvironmentVariable("PATH"), Environment.ProcessPath);

    /// <summary>Never returns the running program itself (on Windows file names are case-insensitive).</summary>
    public static string? Locate(string? forced, string? appDirectory, string? pathVariable, string? self)
    {
        bool IsSelf(string candidate)
        {
            if (string.IsNullOrEmpty(self)) return false;
            try
            {
                var comparison = OperatingSystem.IsLinux() ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
                return string.Equals(Path.GetFullPath(candidate), Path.GetFullPath(self), comparison);
            }
            catch (ArgumentException) { return false; }
        }
        bool Usable(string candidate) => File.Exists(candidate) && !IsSelf(candidate);

        if (!string.IsNullOrEmpty(forced)) return Usable(forced) ? forced : null;
        if (!string.IsNullOrEmpty(appDirectory))
        {
            var beside = Path.Combine(appDirectory, ExecutableName);
            if (Usable(beside)) return beside;
        }
        foreach (var dir in (pathVariable ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), ExecutableName);
                if (Usable(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    public async Task<StatusResult> FetchAsync(CancellationToken ct)
    {
        var exe = Locate();
        if (exe is null) return new StatusResult(null, "err.cliMissing", null);
        var (code, stdout, stderr, timedOut) = await RunAsync(exe, ["status", "--json"], Timeout, ct).ConfigureAwait(false);
        if (timedOut) return new StatusResult(null, "err.cliTimeout", null);
        if (code != 0) return new StatusResult(null, "err.cliFailed", FirstLine(stderr) ?? $"exit {code}");
        try { return new StatusResult(StatusParser.Parse(stdout), null, null); }
        catch (FormatException) { return new StatusResult(null, "err.cliBadOutput", null); }
    }

    static string? FirstLine(string text) =>
        text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();

    public static async Task<(int Code, string Stdout, string Stderr, bool TimedOut)> RunAsync(
        string exe, IEnumerable<string> args, TimeSpan timeout, CancellationToken ct)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            UseShellExecute = false, CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        using var process = new Process { StartInfo = info };
        try { process.Start(); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return (-1, "", e.Message, false);
        }
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        try
        {
            // The deadline covers the pipe reads too: a child that outlives the CLI and keeps the pipe open must not hang the tray.
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            await Task.WhenAll(stdout, stderr).WaitAsync(cts.Token).ConfigureAwait(false);
            return (process.ExitCode, stdout.Result, stderr.Result, false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            try { process.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            // Reads abandoned here end when the pipe closes; observe them so they never surface as unobserved exceptions.
            _ = stdout.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            _ = stderr.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            return (-1, "", "", true);
        }
    }
}

/// <summary>Fixed answer for screenshots and tests.</summary>
public sealed class StaticStatusSource(StatusResult result) : IStatusSource
{
    public Task<StatusResult> FetchAsync(CancellationToken ct) => Task.FromResult(result);
}
