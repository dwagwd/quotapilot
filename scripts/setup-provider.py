#!/usr/bin/env python3
"""Install a status-line bridge while retaining the user's current status line command."""
import argparse
import ast
import json
import os
import re
import tempfile
from pathlib import Path
import shlex
import shutil
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=["claude", "antigravity"])
    args = parser.parse_args()
    base = Path.home() / (".claude" if args.provider == "claude" else ".gemini/antigravity-cli")
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = base / "settings.json"
    data = json.loads(config.read_text()) if config.exists() else {}
    old = data.get("statusLine") or {}
    bridge = Path.home() / "Library/Application Support/QuotaPilot/bridges"
    bridge.mkdir(parents=True, exist_ok=True, mode=0o700)
    script = bridge / (args.provider + "-statusline.py")
    # Prefer the stable system launcher; sys.executable may point inside a versioned Xcode bundle.
    python = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    command = shlex.quote(python) + " " + shlex.quote(str(script))
    if old.get("command") == command:
        print("Bridge already installed."); return
    original = old.get("command")
    try:
        words = shlex.split(original or "")
    except ValueError:
        words = []
    previous = next((w for w in words if re.search(r"/bridges/[a-z0-9_-]+-statusline\.py$", w)), None)
    if previous:
        # An older bridge (also from before the rename): wrap what it wrapped, never the bridge itself.
        old_script = Path(previous)
        text = old_script.read_text() if old_script.exists() else ""
        # Current bridges store it as ORIGINAL = ...; earlier ones inlined it as `if <literal>:`.
        match = re.search(r"^ORIGINAL = (.*)$", text, re.M) or re.search(r"^if (.+):\s*$", text, re.M)
        try:
            original = ast.literal_eval(match.group(1)) if match else None
        except (ValueError, SyntaxError):
            original = None
        if not isinstance(original, str) or "/bridges/" in original:
            original = None
    if old and (old.get("type") != "command" or not isinstance(old.get("command"), str)):
        raise SystemExit("Existing status line is not a shell command; configure manually using docs/providers.md.")
    shutil.copyfile(Path(__file__).with_name("provider_bridge.py"), bridge / "provider_bridge.py")
    script.write_text('''import json, subprocess, sys
ORIGINAL = ORIGINAL_VALUE
from provider_bridge import normalize, write_snapshot
raw = sys.stdin.buffer.read(262145)
try:
    if len(raw) > 262144: raise ValueError()
    write_snapshot(normalize(PROVIDER, json.loads(raw)))
except Exception:
    pass
if ORIGINAL:
    try:
        result = subprocess.run(ORIGINAL, shell=True, input=raw, timeout=10)
    except subprocess.TimeoutExpired:
        sys.exit(1)
    sys.exit(result.returncode)
else:
    print(PROVIDER.capitalize() + " usage → desktop widget")
'''.replace("PROVIDER", repr(args.provider)).replace("ORIGINAL_VALUE", repr(original)))
    if config.exists():
        backup = base / ("settings.json.usage-widget-backup-" + str(time.time_ns()))
        backup_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(backup_fd, "wb") as output:
            output.write(config.read_bytes())
    data["statusLine"] = {**old, "type": "command", "command": command}
    fd, temporary = tempfile.mkstemp(prefix=".usage-widget-", dir=base)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Bridge installed. Enable ‘Import other agents’ in widget Settings. Existing status line preserved.")

if __name__ == "__main__":
    main()
