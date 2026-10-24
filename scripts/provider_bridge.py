#!/usr/bin/env python3
"""Normalize official provider output. Never read credentials or conversation logs."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time

PROVIDERS = ("claude", "antigravity", "cursor")
SUPPORT = Path.home() / "Library/Application Support/QuotaPilot/providers"


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def timestamp(value):
    if number(value) is not None:
        return value
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    return None


def normalize(provider, data, now=None, identity=None):
    now = time.time() if now is None else now
    buckets = {}

    def add(key, name, used, reset=None, duration=None, plan=None):
        used = number(used)
        if used is not None and not 0 <= used <= 100:
            used = None
        buckets[f"{provider}:{str(key)[:100]}"] = {
            "limitName": name[:160], "planType": plan,
            "primary": {"usedPercent": used, "resetsAt": reset, "windowDurationMins": duration}}

    if provider == "claude":
        # The status line does not guarantee an account identifier. Session isolation is
        # deliberately conservative: different sessions never share a rate baseline.
        identity = data.get("session_id")
        limits = data.get("rate_limits") or {}
        for key, duration in (("five_hour", 300), ("seven_day", 10080)):
            window = limits.get(key)
            if isinstance(window, dict):
                add(key, "Claude Code", window.get("used_percentage"), timestamp(window.get("resets_at")), duration)
    elif provider == "antigravity":
        identity = data.get("email") or data.get("conversation_id") or data.get("session_id")
        for key, window in (data.get("quota") or {}).items():
            if not isinstance(window, dict):
                continue
            remaining = number(window.get("remaining_fraction"))
            used = (1 - remaining) * 100 if remaining is not None and 0 <= remaining <= 1 else None
            add(key, "Antigravity · " + key, used, timestamp(window.get("reset_time")), plan=data.get("plan_tier"))
    elif provider == "cursor":
        # Only exact member matches, never the first fuzzy search result.
        matches = [m for m in data.get("teamMemberSpend", []) if m.get("email") == identity]
        if len(matches) != 1:
            raise ValueError("Cursor member not found uniquely")
        member = matches[0]
        limit = number(member.get("effectivePerUserLimitDollars"))
        spent = number(member.get("spendCents"))
        used = spent / limit if limit and limit > 0 and spent is not None else None
        name = "Cursor · on-demand spend cap" + (" (exceeded)" if used is not None and used > 100 else "")
        # Spend can pass the cap; show it as full instead of dropping the reading.
        add("spend", name, min(used, 100) if used is not None and used >= 0 else used)
        # Billing cycle and cap changes invalidate rate history, without inventing a reset date.
        identity = f"{identity}:{data.get('subscriptionCycleStart')}:{limit}"
    else:
        raise ValueError("Unsupported provider")
    if not isinstance(identity, str) or not identity:
        raise ValueError("Missing session/account identity")
    return {"provider": provider, "account": hashlib.sha256(identity.encode()).hexdigest(),
            "updatedAt": now, "limits": {"rateLimitsByLimitId": buckets}}


def write_snapshot(snapshot, directory=SUPPORT):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    marker = directory / (snapshot["provider"] + "-plan.active")
    # The widget writes an account-level plan snapshot itself; a session-level one would reset its baseline.
    if marker.exists() and time.time() - marker.stat().st_mtime < 600:
        return
    path = directory / (snapshot["provider"] + ".json")
    fd, temporary = tempfile.mkstemp(prefix=".snapshot-", dir=directory)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(snapshot, output, allow_nan=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=PROVIDERS)
    parser.add_argument("--member-email", help="Exact Cursor team member email")
    args = parser.parse_args()
    raw = sys.stdin.buffer.read(262145)
    if len(raw) > 262144:
        raise ValueError("Input exceeds 256 KiB")
    snapshot = normalize(args.provider, json.loads(raw), identity=args.member_email)
    write_snapshot(snapshot)
    values = [b["primary"]["usedPercent"] for b in snapshot["limits"]["rateLimitsByLimitId"].values()]
    print(args.provider.capitalize() + " · " + " / ".join("—" if v is None else f"{v:.0f}%" for v in values))

if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not expose raw payloads, paths, or credentials in the terminal status line.
        print("Usage unavailable")
        sys.exit(1)
