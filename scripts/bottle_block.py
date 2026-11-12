#!/usr/bin/env python3
"""Turns the JSON written by `brew bottle --json` into the formula's `bottle do` block."""
import json
import re
import sys

EXPECTED_ROOT = "https://github.com/dwagwd/quotapilot/releases/download/"
BLOCK = re.compile(r"^  bottle do\n.*?^  end\n\n?", re.M | re.S)


def block_from(data, tag):
    """Return the Ruby bottle block for release `tag` (vX.Y.Z); raises ValueError on anything unexpected."""
    if not isinstance(data, dict) or len(data) != 1:
        raise ValueError("expected one formula in the bottle JSON")
    bottle = next(iter(data.values())).get("bottle") or {}
    root_url = bottle.get("root_url", "")
    if root_url != EXPECTED_ROOT + tag:
        raise ValueError(f"bottle root_url {root_url!r} is not the {tag} release")
    version = tag[1:]
    lines = []
    for name, spec in sorted((bottle.get("tags") or {}).items()):
        cellar = spec.get("cellar") or bottle.get("cellar") or "any"
        sha = spec.get("sha256", "")
        if not re.fullmatch(r"[a-z0-9_]+", name) or not re.fullmatch(r"[0-9a-f]{64}", sha) or not re.fullmatch(r"[a-z_]+", cellar):
            raise ValueError(f"unexpected bottle entry for {name!r}")
        if spec.get("filename") != f"quotapilot-{version}.{name}.bottle.tar.gz":
            raise ValueError(f"bottle file {spec.get('filename')!r} is not version {version}")
        lines.append(f'    sha256 cellar: :{cellar}, {name}: "{sha}"')
    if not lines:
        raise ValueError("no bottles in the JSON")
    return "  bottle do\n" + f'    root_url "{root_url}"\n' + "\n".join(lines) + "\n  end\n\n"


def without_bottle(formula):
    return BLOCK.sub("", formula)


def with_bottle(formula, block):
    formula = without_bottle(formula)
    # Homebrew's order: url, license, head, then bottle.
    new, count = re.subn(r"(^  head .*\n)\n?", lambda m: m.group(1) + "\n" + block, formula, count=1, flags=re.M)
    if count != 1:
        raise ValueError("could not find the formula's head line")
    return new


if __name__ == "__main__":
    path, tag, json_path = sys.argv[1:4]
    with open(json_path, encoding="utf-8") as handle:
        data = json.load(handle)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        text = with_bottle(text, block_from(data, tag))
    except ValueError as error:
        sys.exit(str(error))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
