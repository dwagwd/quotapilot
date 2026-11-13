"""Bundle the site and datasets into one HTML file. Usage: build-preview.py OUT.html [--demo]."""
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
html = (root / "index.html").read_text()
# A standalone document must allow its own bundled scripts and styles.
html = re.sub(r'<meta http-equiv="Content-Security-Policy"[^>]*>', "", html)
html = re.sub(r'<link rel="stylesheet" href="assets/style.css">',
              lambda _: "<style>" + (root / "assets/style.css").read_text() + "</style>", html)
html = re.sub(r'\s*<script src="assets/[^"/]+\.js"></script>', "", html)
data = {f"data/{name}.json": json.loads((root / f"data/{name}.json").read_text())
        for name in ["plans", "models", "changes", "community", "community.sample", "resets"]}
# Escaping < keeps text in a dataset from ending the script element.
encoded = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
script = lambda name: "<script>" + (root / f"assets/{name}.js").read_text().replace("</script", "<\\/script") + "</script>"
head = script("theme")
html = html.replace("</head>", head + "</head>")
bundle = script("config") + "<script>window.__AQW_DATA = " + encoded + "; window.__AQW_DEMO = " + ("true" if "--demo" in sys.argv else "false") + ";</script>"
bundle += "".join(script(name) for name in ["i18n", "community-state", "theme-toggle", "app"])
html = html.replace("</body>", bundle + "</body>")
Path(sys.argv[1]).write_text(html)
print(f"wrote {sys.argv[1]} ({len(html):,} bytes)")
