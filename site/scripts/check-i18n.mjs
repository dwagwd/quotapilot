// Checks that English and Chinese strings have the same keys. Run: node scripts/check-i18n.mjs
import { readFileSync } from "node:fs";
const src = readFileSync(new URL("../assets/i18n.js", import.meta.url), "utf8");
const window = {}; new Function("window", src)(window);
const en = Object.keys(window.I18N.en), zh = new Set(Object.keys(window.I18N.zh));
const missing = en.filter((k) => !zh.has(k)), extra = [...zh].filter((k) => !en.includes(k));
const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const app = readFileSync(new URL("../assets/app.js", import.meta.url), "utf8");
// data-i18n="key" sets text; data-i18n-title="key" etc. set attributes. t("key") is the runtime lookup in app.js.
const used = [...html.matchAll(/data-i18n(?:-[a-z]+)?="([^"]+)"/g), ...app.matchAll(/\bt\("([^"]+)"\)/g)].map((m) => m[1]).filter((k) => !en.includes(k));
if (missing.length || extra.length || used.length) { console.error({ missing, extra, undefinedInHtml: used }); process.exit(1); }
console.log(`OK: ${en.length} strings in en and zh.`);
