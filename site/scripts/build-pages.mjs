// Generates static, search-friendly pages from site/data: one page per product's plans,
// one per model's effort levels, and the reset history, in English and Traditional Chinese,
// plus sitemap.xml and robots.txt. No JavaScript is needed to read them.
// Usage: node scripts/build-pages.mjs [outDir] [--base https://example.com/path/]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const args = process.argv.slice(2);
const baseIndex = args.indexOf("--base");
const BASE = (baseIndex >= 0 ? args[baseIndex + 1] : process.env.SITE_URL || "https://aiquotawatch.pages.dev/").replace(/\/?$/, "/");
const OUT = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--base") || root;

const load = (f) => JSON.parse(readFileSync(join(root, "data", f), "utf8"));
const plans = load("plans.json"), changes = load("changes.json"), resets = load("resets.json"), efforts = load("efforts.json"), models = load("models.json");

// Sponsor link comes from the same config the home page uses (assets/config.js); empty or non-https = no sponsor link.
const runBrowserScript = (file) => { const w = {}; new Function("window", readFileSync(join(root, "assets", file), "utf8"))(w); return w; };
const SITE_CONFIG = runBrowserScript("config.js").SITE_CONFIG || {};
const SPONSOR = runBrowserScript("community-state.js").AQW_STATE.sponsorHref(SITE_CONFIG);
const REPO = "https://github.com/dwagwd/quotapilot";
const HEART = `<svg class="ico" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false"><path fill="currentColor" d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`;
const THEME_ICONS = `<svg class="ico ico-auto" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor"/></svg><svg class="ico ico-sun" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg><svg class="ico ico-moon" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>`;

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const host = (u) => { try { return new URL(u).hostname.replace(/^www\./, ""); } catch { return u; } };
const money = (v) => v == null ? "—" : v === 0 ? "$0" : "$" + (v % 1 ? v.toFixed(2) : v);
const monthYear = (iso, lang) => new Date(iso + "T00:00:00Z").toLocaleDateString(lang === "zh" ? "zh-TW" : "en-US", { year: "numeric", month: "long", timeZone: "UTC" });

const T = {
  en: {
    home: "AI Quota Watch", all: "All products", dataAsOf: "Data checked", source: "Source", checked: "checked",
    official: "Official", reported: "Reported", tracker: "Tracker", priceIs: "· price:",
    plansTitle: (n, d) => `${n} usage limits and plans (${d})`,
    plansIntro: (p) => `How much ${p.name} each plan really gives you, how the limit resets, and what changed recently. Every row links to its source.`,
    plan: "Plan", price: "Price / month", usage: "Usage vs. baseline", notes: "Notes", window: "How the limit resets",
    notPublished: "not published", varies: "varies",
    changesTitle: "Recent changes", noChanges: "No tracked changes yet.",
    faqTitle: "Questions",
    faq: (p, base, top) => [
      [`Does ${p.vendor} publish exact ${p.name} message limits?`, p.publishesNumbers ? "Yes." : `No. ${p.vendor} publishes relative multiples, not message counts. Your account's usage page shows the live percentage.`],
      [`How does the ${p.name} limit reset?`, p.windowText],
      [`Which ${p.name} plan gives the most usage?`, top ? `${top.name} (${money(top.priceUsd)}/month) at ${top.multiple}x the ${base ? base.name : "baseline"} plan.` : "The vendor does not publish multiples for every plan."]
    ],
    resetsTitle: "Codex usage limit reset history", resetsIntro: "Every Codex usage-limit reset we can trace to a post by OpenAI's Codex lead Tibo (@thsottiaux), with the time of the post. Your account may update a little later.",
    when: "Posted (UTC)", kind: "Type", what: "What happened", full: "Full reset", banked: "Banked reset card",
    stats: (n, m, gap) => `${n} resets on record, ${m} in the last 30 days. Average gap over the last 90 days: ${gap} days.`,
    effortTitle: (n) => `${n} reasoning effort levels: intelligence, cost and speed`,
    effortIntro: (n) => `How much smarter ${n} gets at each reasoning effort, what each level costs per task, and how fast it answers. Benchmarks from Artificial Analysis.`,
    effort: "Effort", iq: "Intelligence Index", step: "Gain vs. previous", cost: "Cost per task", speed: "Output tokens/s",
    bestValue: "Best intelligence per dollar", openTool: "Open the live dashboard", lang: "中文", effortIndex: "Effort levels by model", plansIndex: "Plans by product",
    resetsNav: "Reset history", notAffiliated: "Independent tracker, not affiliated with OpenAI, Anthropic, Google or xAI.",
    privacy: "Privacy", method: "How the numbers are made", sourceCode: "Source on GitHub", sponsor: "Sponsor",
    resetsFoot: "Codex reset history", installLine: "Free macOS app: QuotaPilot",
    theme: "Theme", themeAuto: "Auto", themeLight: "Light", themeDark: "Dark"
  },
  zh: {
    home: "AI Quota Watch", all: "所有產品", dataAsOf: "資料查證於", source: "來源", checked: "查證於",
    official: "官方", reported: "第三方", tracker: "追蹤站", priceIs: "· 價格：",
    plansTitle: (n, d) => `${n} 用量額度與方案（${d}）`,
    plansIntro: (p) => `${p.name} 各方案實際能用多少、額度怎麼重置，以及最近的變動。每一列都附上來源。`,
    plan: "方案", price: "月費", usage: "相對基準用量", notes: "說明", window: "額度如何重置",
    notPublished: "未公布", varies: "依地區",
    changesTitle: "近期變動", noChanges: "目前沒有追蹤到的變動。",
    faqTitle: "常見問題",
    faq: (p, base, top) => [
      [`${p.vendor} 有公布 ${p.name} 的確切訊息上限嗎？`, p.publishesNumbers ? "有。" : `沒有。${p.vendor} 只公布相對倍數，不公布訊息數。你帳號的用量頁會顯示即時百分比。`],
      [`${p.name} 的額度怎麼重置？`, p.windowText],
      [`哪個 ${p.name} 方案用量最多？`, top ? `${top.name}（每月 ${money(top.priceUsd)}），是 ${base ? base.name : "基準"} 方案的 ${top.multiple} 倍。` : "廠商沒有公布每個方案的倍數。"]
    ],
    resetsTitle: "Codex 額度重置紀錄", resetsIntro: "整理所有能對應到 OpenAI Codex 負責人 Tibo（@thsottiaux）貼文的 Codex 額度重置，時間為貼文發布時間，實際帳號生效可能稍晚。",
    when: "發布時間（UTC）", kind: "類型", what: "內容", full: "完整重置", banked: "可儲存重置卡",
    stats: (n, m, gap) => `共 ${n} 筆紀錄，近 30 天 ${m} 次。近 90 天平均間隔 ${gap} 天。`,
    effortTitle: (n) => `${n} 推理強度比較：智力、成本與速度`,
    effortIntro: (n) => `${n} 在不同推理強度下智力增加多少、每任務成本多少、輸出多快。基準數據來自 Artificial Analysis。`,
    effort: "推理強度", iq: "智力分數", step: "比上一級增加", cost: "每任務成本", speed: "輸出 tokens/秒",
    bestValue: "每美元智力最高", openTool: "開啟即時儀表板", lang: "English", effortIndex: "各模型推理強度", plansIndex: "各產品方案",
    resetsNav: "重置紀錄", notAffiliated: "獨立追蹤網站，與 OpenAI、Anthropic、Google、xAI 無關。",
    privacy: "隱私政策", method: "數據怎麼來的", sourceCode: "GitHub 原始碼", sponsor: "贊助",
    resetsFoot: "Codex 重置紀錄", installLine: "免費 macOS App：QuotaPilot",
    theme: "主題", themeAuto: "自動", themeLight: "淺色", themeDark: "深色"
  }
};

const pages = [];
// Cloudflare Pages (and GitHub Pages) serve "plans/claude.html" at "plans/claude"; link to that form.
const pretty = (path) => path.replace(/index\.html$/, "").replace(/\.html$/, "");
function page({ lang, path, title, description, body, alt, jsonLd, lastmod }) {
  const t = T[lang];
  const depth = path.split("/").length - 1;
  const up = "../".repeat(depth);
  const altPath = alt;
  const zh = lang === "zh" ? "zh/" : "";
  const home = `${up}${lang === "zh" ? "?lang=zh" : ""}`;
  const sponsorChip = SPONSOR ? `<a class="sponsor-chip" href="${esc(SPONSOR)}" target="_blank" rel="noopener">${HEART}<span class="chip-text">${t.sponsor}</span></a>` : "";
  const html = `<!doctype html>
<html lang="${lang === "zh" ? "zh-Hant" : "en"}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://aiquotawatch.pages.dev; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'none'">
<meta name="referrer" content="strict-origin-when-cross-origin">
<meta name="color-scheme" content="light dark">
<script src="${up}assets/theme.js"></script>
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${BASE}${pretty(path)}">
<link rel="alternate" hreflang="${lang === "zh" ? "zh-Hant" : "en"}" href="${BASE}${pretty(path)}">
<link rel="alternate" hreflang="${lang === "zh" ? "en" : "zh-Hant"}" href="${BASE}${pretty(altPath)}">
<meta property="og:type" content="article">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${BASE}${pretty(path)}">
<meta property="og:image" content="${BASE}assets/og.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="${up}assets/style.css">
${jsonLd ? `<script type="application/ld+json">${JSON.stringify(jsonLd)}</script>` : ""}
</head>
<body>
<header class="topbar"><div class="wrap topbar-inner">
  <a class="brand" href="${home}"><span class="brand-mark" aria-hidden="true"></span><span>${t.home}</span></a>
  <nav class="nav"><a href="${up}${zh}plans/">${t.plansIndex}</a><a href="${up}${zh}resets/codex">${t.resetsNav}</a><a href="${up}${zh}effort/">${t.effortIndex}</a></nav>
  <div class="topbar-actions">
    ${sponsorChip}
    <button class="icon-btn theme-toggle" id="themeToggle" type="button" data-mode="auto" aria-label="${t.theme}: ${t.themeAuto}" title="${t.theme}: ${t.themeAuto}" data-l-label="${t.theme}" data-l-auto="${t.themeAuto}" data-l-light="${t.themeLight}" data-l-dark="${t.themeDark}">${THEME_ICONS}</button>
    <a class="lang-toggle" href="${up}${pretty(altPath)}">${t.lang}</a>
  </div>
</div></header>
<main class="wrap article">
${body}
<p class="cta-row"><a class="btn" href="${home}">${t.openTool} →</a></p>
</main>
<footer class="footer"><div class="wrap footer-inner">
  <p class="foot-row"><strong>AI Quota Watch</strong> · ${t.notAffiliated}</p>
  <nav class="footer-links"><a href="${REPO}/blob/main/PRIVACY.md" rel="noopener">${t.privacy}</a><a href="${REPO}/blob/main/collector/README.md" rel="noopener">${t.method}</a><a href="${REPO}" rel="noopener">${t.sourceCode}</a>${SPONSOR ? `<a class="foot-sponsor" href="${esc(SPONSOR)}" target="_blank" rel="noopener">♥ ${t.sponsor}</a>` : ""}</nav>
  <nav class="footer-links"><a href="${up}${zh}plans/">${t.plansIndex}</a><a href="${up}${zh}resets/codex">${t.resetsFoot}</a><a href="${up}${zh}effort/">${t.effortIndex}</a></nav>
  <p class="foot-install"><a href="${home}#install">${t.installLine} ↗</a></p>
  <div class="foot-controls"><label class="foot-theme"><span>${t.theme}</span><select id="themeSelect"><option value="auto">${t.themeAuto}</option><option value="light">${t.themeLight}</option><option value="dark">${t.themeDark}</option></select></label></div>
</div></footer>
<script src="${up}assets/theme-toggle.js"></script>
<script src="${up}assets/hit.js"></script>
</body>
</html>
`;
  pages.push({ path, lastmod: lastmod || plans.lastReviewed });
  const file = join(OUT, path);
  mkdirSync(join(file, ".."), { recursive: true });
  writeFileSync(file, html);
}

const badge = (lang, c) => `<span class="badge ${c === "official" ? "official" : "reported"}">${T[lang][c] || c}</span>`;
// A plan row's price can come from a weaker source than its usage numbers; say so next to the row badge.
const planBadge = (lang, pl) => badge(lang, pl.confidence) + (pl.fields?.price && pl.fields.price !== pl.confidence ? ` ${T[lang].priceIs} ${badge(lang, pl.fields.price)}` : "");

for (const lang of ["en", "zh"]) {
  const t = T[lang], prefix = lang === "zh" ? "zh/" : "", other = lang === "zh" ? "" : "zh/";
  const loc = (o) => (o ? o[lang] || o.en : "");

  // plans per product
  const planLinks = [];
  for (const p of plans.providers) {
    const path = `${prefix}plans/${p.id}.html`;
    planLinks.push(`<li><a href="${p.id}">${esc(t.plansTitle(p.name, monthYear(plans.lastReviewed, lang)))}</a></li>`);
    const base = p.plans.find((x) => x.multiple === 1);
    const top = p.plans.filter((x) => x.multiple).sort((a, b) => b.multiple - a.multiple)[0];
    const withText = { ...p, windowText: loc(p.window) };
    const faq = t.faq(withText, base, top);
    const rows = p.plans.map((pl) => `<tr><td><strong>${esc(pl.name)}</strong></td><td class="num">${pl.priceUsd == null ? t.varies : money(pl.priceUsd)}</td>
      <td class="num">${pl.multiple ? pl.multiple + "x" : t.notPublished}</td><td>${esc(loc(pl.summary))}<br><small>${planBadge(lang, pl)} <a href="${esc(pl.source)}" rel="noopener">${esc(host(pl.source))}</a> · ${t.checked} ${esc(pl.checked)}</small></td></tr>`).join("");
    const subTables = (p.subproducts || []).map((s) => `<h2>${esc(s.name)}</h2>${s.note ? `<p>${esc(loc(s.note))}</p>` : ""}<p><strong>${t.window}:</strong> ${esc(loc(s.window))}</p>
<div class="table-scroll"><table class="models"><thead><tr><th>${t.plan}</th><th class="num">${t.price}</th><th class="num">${t.usage}</th><th>${t.notes}</th></tr></thead><tbody>${s.plans.map((pl) => `<tr><td><strong>${esc(pl.name)}</strong></td><td class="num">${pl.priceUsd == null ? t.varies : money(pl.priceUsd)}</td><td class="num">${pl.multiple ? pl.multiple + "x" : t.notPublished}</td><td>${esc(loc(pl.summary))}<br><small>${planBadge(lang, pl)} <a href="${esc(pl.source)}" rel="noopener">${esc(host(pl.source))}</a> · ${t.checked} ${esc(pl.checked)}</small></td></tr>`).join("")}</tbody></table></div>`).join("");
    const ch = changes.changes.filter((c) => c.provider === p.id).sort((a, b) => b.date.localeCompare(a.date));
    const body = `
<p class="crumbs"><a href="./">${t.plansIndex}</a> › ${esc(p.name)}</p>
<h1>${esc(t.plansTitle(p.name, monthYear(plans.lastReviewed, lang)))}</h1>
<p class="lede">${esc(t.plansIntro(p))}</p>
<p><strong>${t.window}:</strong> ${esc(loc(p.window))}</p>
<div class="table-scroll"><table class="models"><thead><tr><th>${t.plan}</th><th class="num">${t.price}</th><th class="num">${t.usage}</th><th>${t.notes}</th></tr></thead><tbody>${rows}</tbody></table></div>
${subTables}
<h2>${t.changesTitle}</h2>
${ch.length ? `<ul class="plain">${ch.map((c) => `<li><time>${esc(c.date)}</time> ${esc(loc(c.text))} ${badge(lang, c.confidence)} <a href="${esc(c.source)}" rel="noopener">${esc(host(c.source))}</a></li>`).join("")}</ul>` : `<p>${t.noChanges}</p>`}
<h2>${t.faqTitle}</h2>
${faq.map(([q, a]) => `<h3>${esc(q)}</h3><p>${esc(a)}</p>`).join("")}
<p class="fine">${t.dataAsOf} ${esc(plans.lastReviewed)}.</p>`;
    page({ lang, path, alt: `${other}plans/${p.id}.html`, title: t.plansTitle(p.name, monthYear(plans.lastReviewed, lang)), description: t.plansIntro(p), body,
      jsonLd: { "@context": "https://schema.org", "@type": "FAQPage", mainEntity: faq.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) } });
  }
  page({ lang, path: `${prefix}plans/index.html`, alt: `${other}plans/index.html`, title: `${t.plansIndex} · AI Quota Watch`, description: t.plansIndex,
    body: `<h1>${t.plansIndex}</h1><ul class="plain">${planLinks.join("")}</ul>` });

  // reset history
  const rs = resets.resets.slice().sort((a, b) => b.at.localeCompare(a.at));
  const now = new Date(resets.lastReviewed + "T23:59:59Z");
  const in30 = rs.filter((r) => now - new Date(r.at) <= 30 * 864e5).length;
  const recent = rs.filter((r) => now - new Date(r.at) <= 90 * 864e5).map((r) => +new Date(r.at)).sort((a, b) => a - b);
  const gap = recent.length > 1 ? ((recent.at(-1) - recent[0]) / 864e5 / (recent.length - 1)).toFixed(1) : "—";
  page({ lang, path: `${prefix}resets/codex.html`, alt: `${other}resets/codex.html`, title: t.resetsTitle, description: t.resetsIntro, lastmod: resets.lastReviewed,
    body: `<h1>${t.resetsTitle}</h1><p class="lede">${esc(t.resetsIntro)}</p><p>${esc(t.stats(rs.length, in30, gap))}</p>
<div class="table-scroll"><table class="models"><thead><tr><th>${t.when}</th><th>${t.kind}</th><th>${t.what}</th><th>${t.source}</th></tr></thead><tbody>
${rs.map((r) => `<tr><td class="num">${esc(r.timeKnown === false ? r.at.slice(0, 10) : r.at.slice(0, 16).replace("T", " "))}</td><td><span class="kind ${r.kind}">${r.kind === "full" ? t.full : t.banked}</span></td><td>${esc(loc(r.text))}</td><td>${badge(lang, r.confidence)} <a href="${esc(r.source)}" rel="noopener">${esc(host(r.source))}</a></td></tr>`).join("")}
</tbody></table></div><p class="fine">${t.dataAsOf} ${esc(resets.lastReviewed)}.</p>` });

  // effort levels per model
  const effortLinks = [];
  for (const f of efforts.models.filter((m) => m.efforts.length > 1)) {
    const path = `${prefix}effort/${f.model}.html`;
    effortLinks.push(`<li><a href="${f.model}">${esc(t.effortTitle(f.name))}</a></li>`);
    const best = f.efforts.reduce((b, e) => (e.costPerTask && (!b || e.intelligence / e.costPerTask > b.intelligence / b.costPerTask) ? e : b), null);
    const rows = f.efforts.map((e, i) => {
      const d = i ? e.intelligence - f.efforts[i - 1].intelligence : null;
      return `<tr${e === best ? ' class="best"' : ""}><td><strong>${esc(e.effort)}</strong>${e === best ? ` <span class="badge official">${t.bestValue}</span>` : ""}</td><td class="num">${e.intelligence}</td><td class="num">${d == null ? "—" : (d > 0 ? "+" : "") + d}</td><td class="num">${e.costPerTask ? "$" + e.costPerTask.toFixed(2) : "—"}</td><td class="num">${e.speed ?? "—"}</td></tr>`;
    }).join("");
    const m = models.models.find((x) => x.id === f.model);
    page({ lang, path, alt: `${other}effort/${f.model}.html`, title: t.effortTitle(f.name), description: t.effortIntro(f.name),
      lastmod: efforts.source.checked,
      body: `<p class="crumbs"><a href="./">${t.effortIndex}</a> › ${esc(f.name)}</p><h1>${esc(t.effortTitle(f.name))}</h1><p class="lede">${esc(t.effortIntro(f.name))}</p>
<div class="table-scroll"><table class="models ef-table"><thead><tr><th>${t.effort}</th><th class="num">${t.iq}</th><th class="num">${t.step}</th><th class="num">${t.cost}</th><th class="num">${t.speed}</th></tr></thead><tbody>${rows}</tbody></table></div>
${m && m.input != null ? `<p>API: $${m.input} / $${m.output} ${lang === "zh" ? "每百萬輸入／輸出 tokens" : "per 1M input / output tokens"}.</p>` : ""}
<p class="fine">${t.source}: <a href="${esc(efforts.source.url)}" rel="noopener">${esc(efforts.source.name)}</a>, ${t.checked} ${esc(efforts.source.checked)}.</p>` });
  }
  page({ lang, path: `${prefix}effort/index.html`, alt: `${other}effort/index.html`, title: `${t.effortIndex} · AI Quota Watch`, description: t.effortIndex, lastmod: efforts.source.checked,
    body: `<h1>${t.effortIndex}</h1><ul class="plain">${effortLinks.join("")}</ul>` });
}

const urls = [{ path: "", lastmod: plans.lastReviewed }, ...pages].map((p) => `  <url><loc>${BASE}${pretty(p.path)}</loc><lastmod>${p.lastmod}</lastmod></url>`).join("\n");
writeFileSync(join(OUT, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
writeFileSync(join(OUT, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${BASE}sitemap.xml\n`);
console.log(`wrote ${pages.length} pages + sitemap.xml + robots.txt to ${OUT} (base ${BASE})`);
