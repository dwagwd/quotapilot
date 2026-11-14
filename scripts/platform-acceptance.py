#!/usr/bin/env python3
"""Runs the built `quotapilot` on this machine the way a person would and checks four things:

1. it works: version, status, stats, config, route and the share preview all answer;
2. sharing uploads: `quotapilot share --yes` reaches a collector (a local listener stands in for it) and
   `share --forget` asks for deletion;
3. privacy: the upload carries only the allowed statistics fields, a fixed user agent, no cookies, and none of the
   prompt text, project folder name, private model name or user name planted in the test logs;
4. it is light: peak memory and CPU time of a status call and of `watch` running for a while.

Usage: python3 scripts/platform-acceptance.py <path to quotapilot> [--summary FILE]
In CI (CI=true) it writes small synthetic Claude Code and Codex logs into the runner's home folder first, so the
share has something to send. Outside CI it never writes to the home folder and uses whatever logs exist.
Only the Python standard library is used, so it runs unchanged on macOS, Linux and Windows.
"""
import getpass
import http.server
import json
import os
import pathlib
import platform
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

ALLOWED_REPORT_KEYS = {"type", "model", "provider", "plan", "window", "kind", "effort", "client", "via", "date", "resetAt",
                       "outputTokens", "reasoningTokens", "inputTokens", "cacheReadTokens", "cacheWriteTokens", "seconds", "calls",
                       "percentUsed", "tokensUsed", "inputShare"}
SECRET_PROMPT = "TOP-SECRET-PROMPT-7f3a"
SECRET_PROJECT = "acme-secret-project-9c1d"
PRIVATE_MODEL = "acme-internal-model"
MAX_PEAK_MB = 200          # generous ceilings: the point is to catch a regression, not to tune
MAX_WATCH_CPU_PERCENT = 10

# Runs a command, passes its output through and its exit status back, and prints its CPU seconds and peak memory (MB)
# on stderr when it ends, including on SIGTERM. ru_maxrss is bytes on macOS and kilobytes on Linux.
MEASURE = r"""
import os, resource, signal, subprocess, sys
child = subprocess.Popen(sys.argv[1:])
signal.signal(signal.SIGTERM, lambda *a: child.terminate())
code = child.wait()
r = resource.getrusage(resource.RUSAGE_CHILDREN)
peak = r.ru_maxrss / (1048576 if sys.platform == "darwin" else 1024)
sys.stderr.write("__cost__ %.3f %.1f\n" % (r.ru_utime + r.ru_stime, peak)); sys.stderr.flush()
sys.exit(code)
"""
failures = []
rows = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def plant_logs(home):
    """Three timed calls on a public model and three on a private one, in Claude Code's and Codex's log formats."""
    now = datetime.now(timezone.utc) - timedelta(minutes=30)
    claude = home / ".claude" / "projects" / SECRET_PROJECT
    claude.mkdir(parents=True, exist_ok=True)
    lines = []
    for i, model in enumerate(["claude-opus-5-5"] * 3 + [PRIVATE_MODEL] * 3):
        t = now + timedelta(seconds=i * 30)
        lines.append({"type": "user", "timestamp": iso(t), "message": {"role": "user", "content": SECRET_PROMPT}})
        lines.append({"type": "assistant", "timestamp": iso(t + timedelta(seconds=10)), "effort": "high",
                      "message": {"id": f"m{i}", "model": model, "usage": {"input_tokens": 1200, "output_tokens": 800, "cache_read_input_tokens": 5000}}})
    (claude / "acceptance.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    codex = home / ".codex" / "sessions" / now.strftime("%Y") / now.strftime("%m") / now.strftime("%d")
    codex.mkdir(parents=True, exist_ok=True)
    lines = [{"timestamp": iso(now), "type": "session_meta", "payload": {"id": "acceptance", "cwd": "/work/" + SECRET_PROJECT}},
             {"timestamp": iso(now), "type": "turn_context", "payload": {"model": "gpt-6.1-sol", "effort": "medium"}}]
    for i in range(3):
        t = now + timedelta(seconds=200 + i * 30)
        lines.append({"timestamp": iso(t), "type": "response_item", "payload": {"type": "custom_tool_call_output", "output": SECRET_PROMPT}})
        lines.append({"timestamp": iso(t + timedelta(seconds=8)), "type": "token_usage_record",
                      "payload": {"response_id": f"resp_{i}", "usage": {"input_tokens": 900, "output_tokens": 400, "reasoning_output_tokens": 100}}})
    (codex / "rollout-acceptance.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")


class Capture(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        Capture.seen.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body.decode("utf-8", "replace")})
        try:
            data = json.loads(body)
        except ValueError:
            data = {}
        answer = {"ok": True, "accepted": len(data.get("reports", []))} if self.path.endswith("/report") else {"ok": True, "deleted": 1}
        out = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


def process_cost(proc):
    """(cpu seconds, peak memory MB) of a finished child, or (None, None) where the system does not say."""
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD), ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t), ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]
        handle = wintypes.HANDLE(int(proc._handle))
        created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
        ctypes.windll.kernel32.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user))
        ticks = lambda f: (f.dwHighDateTime << 32) + f.dwLowDateTime
        counters = Counters(); counters.cb = ctypes.sizeof(Counters)
        psapi = ctypes.WinDLL("psapi")
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        ok = psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb)
        return (ticks(kernel) + ticks(user)) / 1e7, (counters.PeakWorkingSetSize / 1048576 if ok else None)
    return None, None


def run(tool, args, env, timeout=120, stop_after=None):
    """Runs one command; returns (exit code, stdout, stderr, wall seconds, cpu seconds, peak MB)."""
    posix = os.name != "nt"
    start = time.time()
    # On POSIX the command runs under a small Python parent that reports the command's own CPU time and peak memory
    # (getrusage of its children). Measuring from this process would mix in every earlier command.
    command = [str(tool)] + args
    if posix:
        command = [sys.executable, "-c", MEASURE] + command
    proc = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
    try:
        out, err = proc.communicate(timeout=stop_after or timeout)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            out, err = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill(); out, err = proc.communicate()
        if stop_after is None:
            return -9, out.decode("utf-8", "replace"), "timed out", time.time() - start, None, None
    wall = time.time() - start
    if posix:
        err = err.decode("utf-8", "replace")
        cost = [l for l in err.splitlines() if l.startswith("__cost__ ")]
        err = "\n".join(l for l in err.splitlines() if not l.startswith("__cost__ ")).encode()
        cpu, peak = (float(x) for x in cost[-1].split()[1:3]) if cost else (None, None)
    else:
        cpu, peak = process_cost(proc)
    return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), wall, cpu, peak


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    tool = pathlib.Path(sys.argv[1]).resolve()
    summary = sys.argv[sys.argv.index("--summary") + 1] if "--summary" in sys.argv else os.environ.get("GITHUB_STEP_SUMMARY")
    home = pathlib.Path.home()
    in_ci = os.environ.get("CI") == "true"
    if in_ci:
        plant_logs(home)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Capture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, QUOTAPILOT_COLLECTOR_URL=f"http://127.0.0.1:{server.server_address[1]}")
    system = f"{platform.system()} {platform.machine()}"
    print(f"quotapilot acceptance on {system} (planted logs: {in_ci})")

    # 1. It works.
    code, out, err, *_ = run(tool, ["version"], env)
    check(code == 0 and out.startswith("quotapilot "), "version prints a version")
    version = out.strip()
    code, out, err, wall, cpu, peak = run(tool, ["status", "--json"], env)
    status_ok = code == 0 and isinstance(json.loads(out or "null"), dict)
    check(status_ok, f"status --json answers ({wall:.1f}s)")
    rows.append(("status --json (one run)", wall, cpu, peak))
    code, out, err, *_ = run(tool, ["stats", "--json"], env)
    check(code == 0 and isinstance(json.loads(out or "null"), dict), "stats --json answers")
    code, out, err, *_ = run(tool, ["config", "show"], env)
    check(code == 0 and "mode:" in out, "config show answers")
    code, out, err, *_ = run(tool, ["route", "review"], env)
    check(code in (0, 3) and out.strip() in ("codex", "claude", "none"), "route review names an agent or none")

    # 2 and 3. The share preview, the upload, and what is in it.
    code, out, err, *_ = run(tool, ["share", "--json"], env)
    preview = json.loads(out) if code == 0 and out.strip().startswith("[") else None
    check(isinstance(preview, list), "share --json prints the preview")
    check(not Capture.seen, "the preview sends nothing")
    if in_ci:
        models = sorted({r.get("model") for r in preview or [] if r.get("type") == "speed"})
        check("claude-opus-5-5" in models and "gpt-6-1-sol" in models, f"the planted Claude Code and Codex calls are measured (models: {models})")
        check(PRIVATE_MODEL not in json.dumps(preview), "the private model is left out of the preview")
    if preview:
        code, out, err, *_ = run(tool, ["share", "--yes"], env)
        check(code == 0 and "Shared" in out, "share --yes reports success")
        uploads = [r for r in Capture.seen if r["path"].endswith("/v1/report")]
        check(len(uploads) == 1, "exactly one upload was made")
        if uploads:
            up = uploads[0]
            body = json.loads(up["body"])
            check(sorted(body) == ["install", "reports"], "the upload has only an install id and reports")
            extra = sorted({k for r in body["reports"] for k in r} - ALLOWED_REPORT_KEYS)
            check(not extra, f"reports contain only allowed statistics fields (extra: {extra})")
            check(up["headers"].get("user-agent") == "QuotaPilot", f"fixed user agent (got {up['headers'].get('user-agent')!r})")
            check("cookie" not in up["headers"] and "authorization" not in up["headers"], "no cookie or authorization header")
            everything = up["body"] + json.dumps(up["headers"])
            planted = [SECRET_PROMPT, SECRET_PROJECT, PRIVATE_MODEL]
            personal = [s for s in {getpass.getuser(), str(home), home.name, platform.node()} if len(s) >= 4]
            leaked = [s for s in planted + personal if s.lower() in everything.lower()]
            check(not leaked, f"no prompt text, project name, private model, user name, home path or host name in the upload (found: {leaked})")
            check(all(str(r.get("date", "")).endswith(":00:00Z") for r in body["reports"]), "times are rounded to the hour")
        code, out, err, *_ = run(tool, ["share", "--forget"], env)
        forgets = [r for r in Capture.seen if r["path"].endswith("/v1/forget")]
        check(code == 0 and len(forgets) == 1 and sorted(json.loads(forgets[0]["body"])) == ["install"], "share --forget asks the collector to delete, sending only the install id")
    else:
        print("note: nothing to share on this machine, so the upload checks were skipped")

    # 4. It is light. `stats` reads the logs without starting the Codex app server, so its peak is QuotaPilot's own
    # memory; status and watch also count the app server they start (on macOS that is most of the figure).
    code, out, err, wall, cpu, peak = run(tool, ["stats", "--json"], env)
    rows.append(("stats --json (reads a day of logs)", wall, cpu, peak))
    if peak is not None:
        check(peak < MAX_PEAK_MB, f"stats: QuotaPilot's own peak memory {peak:.1f} MB is under {MAX_PEAK_MB} MB")
    # watch refreshes every 15 s at the fastest. The first refresh reads the day's logs; later ones read only what was
    # appended. Steady-state CPU = (CPU over a long run - CPU over a short run) / the extra time.
    short = run(tool, ["watch", "--interval", "15"], env, stop_after=8)
    long = run(tool, ["watch", "--interval", "15"], env, stop_after=68)
    rows.append(("watch, first 8 s (first full read)", short[3], short[4], short[5]))
    rows.append(("watch, 68 s (4 refreshes)", long[3], long[4], long[5]))
    if short[4] is not None and long[4] is not None:
        steady = max(0.0, long[4] - short[4]) / max(1.0, long[3] - short[3]) * 100
        rows.append(("watch, steady state (after the first read)", long[3] - short[3], max(0.0, long[4] - short[4]), None))
        check(steady < MAX_WATCH_CPU_PERCENT, f"watch steady state: {steady:.2f}% of one CPU core is under {MAX_WATCH_CPU_PERCENT}%")

    table = [f"### QuotaPilot acceptance: {system}", "", f"`{version}`, {len(failures)} failed checks. No GPU is used: the tool draws text only.", "",
             "| Command | Wall time | CPU time | Average CPU (one core) | Peak memory (status and watch include the Codex app server they start) |", "|---|---:|---:|---:|---:|"]
    for name, wall, cpu, peak in rows:
        table.append(f"| {name} | {wall:.1f} s | {'-' if cpu is None else f'{cpu:.2f} s'} | {'-' if cpu is None else f'{cpu / wall * 100:.2f}%'} | {'-' if peak is None else f'{peak:.1f} MB'} |")
    text = "\n".join(table) + "\n"
    print("\n" + text)
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
    server.shutdown()
    if failures:
        sys.exit("FAILED: " + "; ".join(failures))
    print("All acceptance checks passed.")


if __name__ == "__main__":
    main()
