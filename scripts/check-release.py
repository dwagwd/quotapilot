#!/usr/bin/env python3
"""Static release hygiene checks; never prints matching secret values."""
import json
import os
import re
import subprocess
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
    if path.name == "check-release.py" or path.suffix in {".png", ".icns"}:
        continue  # binary artwork
    text = path.read_text(encoding="utf-8")
    for pattern in patterns:
        assert not re.search(pattern, text), f"Potential private data in {path.relative_to(ROOT)}"
# The formula links the CLI that the website's install steps invoke; it must point where build.sh puts it.
formula = (ROOT / "Formula/quotapilot.rb").read_text()
build = (ROOT / "scripts/build.sh").read_text()
cli_path = re.search(r'bin\.install_symlink prefix/"QuotaPilot\.app/(Contents/[^"]+)"', formula)
assert cli_path, "Formula does not link the quotapilot command"
assert f'"$APP/{cli_path.group(1)}"' in build, "build.sh does not place the CLI where the formula links it"
assert f'tag: "v{version}"' in formula, "Formula does not build the current VERSION"
# A bottle block belongs to one release: bumping the version must drop the old one (scripts/add-bottle.sh adds the new one).
bottle_root = re.search(r'^  bottle do\n\s*root_url "([^"]+)"', formula, re.M)
assert not re.search(r"^  bottle do$", formula, re.M) or bottle_root, "Formula bottle block has no root_url"
if bottle_root:
    expected_root = f"https://github.com/dwagwd/quotapilot/releases/download/v{version}"
    assert bottle_root.group(1) == expected_root, f"Formula bottle is for {bottle_root.group(1)}, not v{version}; remove the bottle block when bumping the version"
# The tag alone can be moved; the formula must also pin the commit.
PLACEHOLDER_REVISION = "0" * 40
revision = re.search(r'revision: "([0-9a-f]{40})"', formula)
assert revision, "Formula has no 40-character revision: next to tag:"
revision = revision.group(1)


def tag_commit(tag):
    """Return (state, commit): state is 'ok', 'missing' (tag absent) or 'nogit' (git or repository unavailable)."""
    try:
        inside = subprocess.run(["git", "rev-parse", "--git-dir"], cwd=ROOT, capture_output=True, text=True)
        if inside.returncode != 0:
            return "nogit", None
        found = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"], cwd=ROOT, capture_output=True, text=True)
    except FileNotFoundError:
        return "nogit", None
    if found.returncode != 0:
        return "missing", None
    return "ok", found.stdout.strip()


def remote_tag_commit(tag):
    """Ask origin for the tag: returns ('ok', commit), ('missing', None) or ('unreachable', None)."""
    try:
        found = subprocess.run(["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}^{{}}", f"refs/tags/{tag}"],
                               cwd=ROOT, capture_output=True, text=True, timeout=60,
                               env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "unreachable", None
    if found.returncode != 0:
        return "unreachable", None
    refs = {}
    for line in found.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            refs[parts[1]] = parts[0]
    # The peeled ref is the commit of an annotated tag; a lightweight tag only has the plain ref.
    commit = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    return ("ok", commit) if commit else ("missing", None)


state, commit = tag_commit(f"v{version}")
if state == "nogit":
    print("Notice: git is unavailable here; skipped the formula revision check.")
else:
    if state == "missing":
        state, commit = remote_tag_commit(f"v{version}")
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    # The release workflow builds the tag commit itself; its formula is pinned by the next commit (docs/releasing.md).
    if state == "ok" and os.environ.get("QUOTAPILOT_RELEASE_BUILD") == "1" and commit == head and revision == PLACEHOLDER_REVISION:
        print(f"Notice: building tag v{version} itself; the formula is pinned by the next commit.")
    elif state == "ok":
        assert revision != PLACEHOLDER_REVISION, f"Tag v{version} exists; run scripts/pin-formula.sh v{version} and commit the result"
        assert revision == commit, f"Formula revision {revision} differs from v{version} commit {commit}"
    elif state == "unreachable":
        print(f"Notice: tag v{version} is not present locally and origin could not be queried; cannot verify the formula revision.")
    elif revision != PLACEHOLDER_REVISION:
        print(f"Notice: tag v{version} does not exist locally or on origin; cannot verify the formula revision.")
print(f"Release hygiene passed ({len(public_files())} source files, version {version}).")
