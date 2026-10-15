#!/usr/bin/env python3
"""Static release hygiene checks; never prints matching secret values."""
import json
import re
from release_files import ROOT, FILES, public_files

required = list(FILES) + [".codex-plugin/plugin.json", ".github/workflows/ci.yml"]
for name in required:
    assert (ROOT / name).is_file(), f"Missing release file: {name}"
version = (ROOT / "VERSION").read_text().strip()
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid VERSION"
manifest = json.loads((ROOT / ".codex-plugin/plugin.json").read_text())
assert manifest["name"] == "quotapilot"
assert manifest["version"].split("+")[0] == version, "Plugin and app versions differ"
assert "MIT License" in (ROOT / "LICENSE").read_text()
# Match accidental machine-specific paths, real credentials, or private key material.
patterns = [r"/Users/[^/\s]+/", r"/Volumes/[^\n]+/coding/", r"sk-[A-Za-z0-9_-]{20,}", r"gh[pousr]_[A-Za-z0-9]{20,}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"]
for path in public_files():
    if path.name == "check-release.py":
        continue
    text = path.read_text(encoding="utf-8")
    for pattern in patterns:
        assert not re.search(pattern, text), f"Potential private data in {path.relative_to(ROOT)}"
print(f"Release hygiene passed ({len(public_files())} source files, version {version}).")
