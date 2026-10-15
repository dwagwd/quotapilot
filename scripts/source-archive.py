#!/usr/bin/env python3
import json
import sys
import zipfile
from pathlib import Path
from release_files import ROOT, public_files

version = (ROOT / "VERSION").read_text().strip()
target = Path(sys.argv[1]).resolve()
target.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in public_files():
        relative = path.relative_to(ROOT)
        data = path.read_bytes()
        if relative.as_posix() == ".codex-plugin/plugin.json":
            manifest = json.loads(data)
            manifest["version"] = version  # Local reinstall suffixes do not enter public releases.
            data = (json.dumps(manifest, indent=2, ensure_ascii=False)+"\n").encode()
        info = zipfile.ZipInfo("quotapilot/" + relative.as_posix())
        info.external_attr = (0o100755 if path.suffix == ".sh" else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
print(f"Source package: {target}")
