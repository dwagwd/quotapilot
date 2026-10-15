#!/usr/bin/env python3
"""Install a status-line bridge while retaining the user's current status line command."""
import argparse
import json
import os
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
    bridge = Path.home() / "Library/Application Support/CodexUsageWidget/bridges"
    bridge.mkdir(parents=True, exist_ok=True, mode=0o700)
    script = bridge / (args.provider + "-statusline.py")
    # Prefer the stable system launcher; sys.executable may point inside a versioned Xcode bundle.
    python = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    command = shlex.quote(python) + " " + shlex.quote(str(script))
    if old.get("command") == command:
        print("Bridge already installed."); return
    if old and (old.get("type") != "command" or not isinstance(old.get("command"), str)):
        raise SystemExit("Existing status line is not a shell command; configure manually using docs/providers.md.")
    shutil.copyfile(Path(__file__).with_name("provider_bridge.py"), bridge / "provider_bridge.py")
    script.write_text('''import json, subprocess, sys
from provider_bridge import normalize, write_snapshot
raw = sys.stdin.buffer.read(262145)
try:
    if len(raw) > 262144: raise ValueError()
    write_snapshot(normalize(PROVIDER, json.loads(raw)))
except Exception:
    pass
if ORIGINAL:
    result = subprocess.run(ORIGINAL, shell=True, input=raw, timeout=10)
    sys.exit(result.returncode)
else:
    print(PROVIDER.capitalize() + " usage → desktop widget")
'''.replace("PROVIDER", repr(args.provider)).replace("ORIGINAL", repr(old.get("command"))))
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
