"""Bundle the site into one self-contained HTML file (data inlined, theme tokens for
claude.ai Artifact previews). Usage: python3 scripts/build-preview.py OUT.html"""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
css = (root / "assets/style.css").read_text()
# style.css already switches themes with :root[data-theme] and the prefers-color-scheme block.
css = css.replace(".wrap { max-width: var(--wrap); margin: 0 auto; padding: 0 16px; }",
    ".wrap { max-width: var(--wrap); margin: 0 auto; padding-left: max(16px, env(safe-area-inset-left, 0px)); "
    "padding-right: max(16px, env(safe-area-inset-right, 0px)); }")
css = css.replace(".topbar { position: sticky; top: 0;", ".topbar { position: sticky; top: env(safe-area-inset-top, 0px);")
css += '\nbody::before { content: ""; position: fixed; inset: 0 0 auto; height: env(safe-area-inset-top, 0px); z-index: 10; background: var(--bg); }\n'

html = (root / "index.html").read_text()
body = re.search(r"<body>(.*)</body>", html, re.S).group(1)
body = re.sub(r'\s*<script src="assets/(i18n|community-state|theme-toggle|app|hit)\.js"></script>', "", body)
data = {f"data/{n}.json": json.loads((root / f"data/{n}.json").read_text()) for n in ["plans", "models", "changes", "community", "community.sample", "resets"]}
app = (root / "assets/app.js").read_text()
fetch_line = 'const get = (f) => fetch(f).then((r) => { if (!r.ok) throw new Error(f + " " + r.status); return r.json(); });'
assert fetch_line in app
app = app.replace(fetch_line, "const get = (f) => Promise.resolve(window.__AQW_DATA[f]);")

page = f"""<title>AI Quota Watch</title>
<meta name="claude:viewport-fit-sides" content="cover">
<meta name="description" content="Usage limits, plan changes, API prices and community-measured speed for ChatGPT, Claude, Gemini and Grok.">
<style>
{css}
</style>
{body}
<script>{(root / "assets/config.js").read_text()}</script>
<script>window.__AQW_DATA = {json.dumps(data, ensure_ascii=False)}; window.__AQW_DEMO = {"true" if "--demo" in sys.argv else "false"};</script>
<script>{(root / "assets/i18n.js").read_text()}</script>
<script>{(root / "assets/community-state.js").read_text()}</script>
<script>{(root / "assets/theme-toggle.js").read_text()}</script>
<script>{app}</script>
"""
Path(sys.argv[1]).write_text(page)
print(f"wrote {sys.argv[1]} ({len(page):,} bytes)")
