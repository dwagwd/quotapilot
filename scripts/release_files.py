"""Allowlisted, credential-free source export shared by release checks and packaging."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = ("Sources", "Tests", "scripts", "skills", ".github", ".codex-plugin", "docs", "assets")
FILES = ("Package.swift", "VERSION", "LICENSE", "README.md", "README.zh-TW.md", "CONTRIBUTING.md", "SECURITY.md", "PRIVACY.md", "CHANGELOG.md", ".gitignore")
def public_files():
    files = [ROOT / name for name in FILES if (ROOT / name).is_file()]
    for name in DIRECTORIES:
        base = ROOT / name
        if base.is_dir():
            files.extend(p for p in base.rglob("*") if p.is_file() and not p.is_symlink() and "__pycache__" not in p.parts and p.suffix != ".pyc")
    return sorted(files)
