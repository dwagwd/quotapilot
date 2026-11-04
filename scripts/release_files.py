"""Allowlisted, credential-free source export shared by release checks and packaging."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = ("Sources", "Tests", "scripts", "skills", ".github", ".codex-plugin", "docs", "assets",
               # Website, collector and cask, so the archive can reproduce what the workflows deploy.
               "site", "collector", "Casks")
# Local tool state (Wrangler cache with account details, editor/agent folders) and build output never ship.
SKIPPED_PARTS = {"node_modules", "_site", "__pycache__"}
# Pages that site/scripts/build-pages.mjs regenerates (ignored in site/.gitignore).
GENERATED = ("site/plans/", "site/effort/", "site/resets/", "site/zh/", "site/sitemap.xml", "site/robots.txt")
FILES = ("Package.swift", "VERSION", "LICENSE", "README.md", "README.zh-TW.md", "CONTRIBUTING.md", "SECURITY.md", "PRIVACY.md", "CHANGELOG.md", ".gitignore")
def public_files():
    files = [ROOT / name for name in FILES if (ROOT / name).is_file()]
    for name in DIRECTORIES:
        base = ROOT / name
        if base.is_dir():
            for p in base.rglob("*"):
                inner = p.relative_to(base).parts
                if not p.is_file() or p.is_symlink() or p.suffix in {".pyc", ".log", ".jsonl"}:
                    continue
                if SKIPPED_PARTS.intersection(inner) or any(part.startswith(".") for part in inner[:-1]) \
                        or p.relative_to(ROOT).as_posix().startswith(GENERATED):
                    continue
                files.append(p)
    return sorted(files)
