// The /models/ pages: the ranking with its calculators, "local LLM speed by Mac chip" and "LLM API price comparison", in English and
// Traditional Chinese. Static HTML built from data/models.json and data/community.json with the same code the browser uses
// (assets/models-core.js); assets/models-page.js adds filters, sorting and the calculators on top. Without JavaScript the tables still read.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function loadCore(root) {
  const w = {};
  new Function("window", readFileSync(join(root, "assets", "models-core.js"), "utf8"))(w);
  return w.AQW_MODELS;
}

const host = (u) => { try { return new URL(u).hostname.replace(/^www\./, ""); } catch { return u; } };

// Returns page definitions for build-pages.mjs's page(): { path, alt, title, description, body, jsonLd, scripts, lastmod }.
export function modelsPages({ lang, root, models, community, base }) {
  const M = loadCore(root), t = M.T(lang), esc = M.esc;
  const prefix = lang === "zh" ? "zh/" : "", other = lang === "zh" ? "" : "zh/";
  const rows = [...M.cloudRows(models, community), ...M.localRows(community)];
  const ordered = M.defaultOrder(rows);
  const cloud = rows.filter((r) => r.kind === "cloud"), local = rows.filter((r) => r.kind === "local");
  const generated = community && community.generated ? String(community.generated).slice(0, 10) : null;
  const sourceLine = Object.values(models.sources || {}).map((s) => `<a href="${esc(s.url)}" rel="noopener">${esc(s.name)}</a> (${esc(t.pricesChecked)} ${esc(s.checked)})`).join(" · ");
  const crumbs = (name, path) => ({ "@context": "https://schema.org", "@type": "BreadcrumbList", itemListElement: [
    { "@type": "ListItem", position: 1, name: "AI Quota Watch", item: base + prefix },
    ...(path ? [{ "@type": "ListItem", position: 2, name: t.linkRanking, item: `${base}${prefix}models/` }, { "@type": "ListItem", position: 3, name, item: `${base}${prefix}${path}` }]
      : [{ "@type": "ListItem", position: 2, name, item: `${base}${prefix}models/` }]) ] });
  const links = `<h2>${esc(t.linkRanking)}</h2><ul class="plain"><li><a href="${prefix ? "" : ""}./">${esc(t.linkRanking)}</a></li><li><a href="local-llm-speed-by-mac-chip">${esc(t.linkChips)}</a></li><li><a href="llm-api-price-comparison">${esc(t.linkPrices)}</a></li></ul>`;
  const pages = [];

  // ---- the ranking ----
  const select = (id, label, options) => `<label class="field"><span>${esc(label)}</span><select id="${id}">${options.map(([v, text]) => `<option value="${esc(v)}">${esc(text)}</option>`).join("")}</select></label>`;
  const num = (id, label, attrs = "") => `<label class="field"><span>${esc(label)}</span><input id="${id}" type="number" inputmode="decimal" step="any" min="0" autocomplete="off"${attrs}></label>`;
  const currencyOptions = M.COMMON_CURRENCIES.map((c) => `<option value="${c}">`).join("");
  const tools = `<section class="models-tools" id="modelsTools" hidden aria-label="${esc(t.fType)}">
  <div class="field-grid">
    ${select("fType", t.fType, [["all", t.fAll], ["cloud", t.fCloud], ["local", t.fLocal]])}
    ${select("fProvider", t.fProvider, [["all", t.fAll], ...Object.entries(M.PROVIDERS)])}
    ${num("fBudget", t.fBudget)}
    ${select("fChip", t.fChip, [["all", t.fAny]])}
    ${select("fMem", t.fMem, [["all", t.fAny]])}
  </div>
  <p class="fine"><button class="btn ghost btn-sm" type="button" id="fReset">${esc(t.fReset)}</button> <span id="rowCount" aria-live="polite"></span></p>
</section>`;
  const calc = `<section class="calc" id="calc" hidden aria-labelledby="calcTitle">
  <h2 id="calcTitle">${esc(t.calcTitle)}</h2>
  <p>${esc(t.calcIntro)}</p>
  <div class="field-grid">
    ${num("inTok", t.inTok)}${num("outTok", t.outTok)}${num("cachedPct", t.cachedShare, ' max="100"')}
  </div>
  <details class="paste"><summary>${esc(t.paste)}</summary>
    <textarea id="pasteBox" rows="5" spellcheck="false" autocomplete="off" aria-label="${esc(t.paste)}"></textarea>
    <p><button class="btn ghost btn-sm" type="button" id="pasteBtn">${esc(t.pasteUse)}</button> <span class="fine" id="pasteMsg" aria-live="polite"></span></p>
  </details>
  <h3>${esc(t.numbers)}</h3>
  <div class="field-grid">
    <label class="field"><span>${esc(t.currency)}</span><input id="cur" type="text" list="currencyList" maxlength="3" autocomplete="off" autocapitalize="characters" value="USD"></label>
    <datalist id="currencyList">${currencyOptions}</datalist>
    ${num("rate", t.rate)}${num("kwh", t.kwh)}${num("watts", t.watts)}${num("hoursDay", t.hours, ' max="24"')}
  </div>
  <p class="fine">${esc(t.rateHelp)}</p><p class="fine">${esc(t.wattsHelp)}</p>
  <h3>${esc(t.resTitle)}</h3>
  <div class="table-scroll" tabindex="0"><table class="models calc-table"><thead><tr><th scope="col">${esc(t.resModel)}</th><th scope="col" class="num">${esc(t.resCost)}</th><th scope="col" class="num">${esc(t.resSpeed)}</th><th scope="col" class="num">${esc(t.resTime)}</th></tr></thead><tbody id="resBody"></tbody></table></div>
  <p class="fine" id="resNote"></p>
</section>
<section class="calc" id="elec" hidden aria-labelledby="elecTitle">
  <h2 id="elecTitle">${esc(t.elecTitle)}</h2>
  <p>${esc(t.elecIntro)}</p>
  <div class="field-grid">
    ${num("elSpeed", t.elecSpeed)}
    ${select("elCompare", t.elecCompare, cloud.filter((r) => r.output != null).map((r) => [r.id, r.name]))}
  </div>
  <dl class="result-list" id="elOut" aria-live="polite"></dl>
  <p class="fine">${esc(t.elecFootnote)}</p>
</section>`;
  const mainBody = `<h1>${esc(t.h1)}</h1>
<p class="lede">${esc(t.intro)}</p>
<noscript><p class="fine">${esc(t.noscript)}</p></noscript>
${tools}
<div class="table-scroll" tabindex="0"><table class="models rank-table" id="rankTable"><thead>${M.headerHtml(lang)}</thead><tbody id="rankBody">${ordered.map((r) => M.rowHtml(r, lang)).join("")}</tbody></table></div>
<p class="fine">${esc(t.blendNote)}</p><p class="fine">${esc(t.speedNote)}</p><p class="fine">${esc(t.smartNote)}</p>
<p class="fine">${esc(t.checked)}: ${sourceLine}${generated ? ` · ${esc(t.dataAsOf)} ${esc(generated)}` : ""}</p>
${calc}
${links}`;
  pages.push({ path: `${prefix}models/index.html`, alt: `${other}models/index.html`, title: t.title, description: t.desc, body: mainBody, lastmod: models.lastReviewed,
    jsonLd: [crumbs(t.linkRanking)], scripts: ["assets/models-core.js", "assets/models-page.js"], dataLang: lang });

  // ---- local LLM speed by Mac chip ----
  const apple = (r) => /^Apple M/.test(r.chip);
  const chipTable = (list, speedHeader) => {
    const sorted = list.slice().sort((a, b) => a.chip.localeCompare(b.chip) || a.memGB - b.memGB || a.name.localeCompare(b.name) || (b.speed?.value ?? 0) - (a.speed?.value ?? 0));
    return `<div class="table-scroll" tabindex="0"><table class="models"><thead><tr><th scope="col">${esc(t.chipsChip)}</th><th scope="col" class="num">${esc(t.chipsMemory)}</th><th scope="col">${esc(t.cModel)}</th><th scope="col">${esc(t.chipsEngine)}</th><th scope="col" class="num">${esc(speedHeader)}</th><th scope="col" class="num">${esc(t.chipsPrompt)}</th><th scope="col" class="num">${esc(t.chipsPeople)}</th></tr></thead><tbody>${sorted.map((r) =>
      `<tr><td>${esc(r.chip)}</td><td class="num">${r.memGB} GB</td><td><strong>${esc(r.name)}</strong></td><td>${esc(M.ENGINES[r.engine] || r.engine)}</td><td class="num">${r.prelim ? "≈" + Math.round(r.speed.value) : r.speed.value}</td><td class="num">${r.promptTps != null ? Math.round(r.promptTps) : esc(t.none)}</td><td class="num">${r.people}</td></tr>`).join("")}</tbody></table></div>`;
  };
  const published = local.filter((r) => apple(r) && !r.prelim), prelim = local.filter((r) => apple(r) && r.prelim);
  const empty = `<div class="empty-state"><h2>${esc(t.chipsEmptyTitle)}</h2><p>${esc(t.chipsEmpty)}</p>
<h3>${esc(t.chipsHow)}</h3><ol><li>${esc(t.chipsHow1)}</li><li>${esc(t.chipsHow2)}</li><li>${esc(t.chipsHow3)}</li></ol>
<div class="table-scroll" tabindex="0"><pre><code>${esc(t.chipsCmd)}</code></pre></div></div>`;
  const chipsBody = `<p class="crumbs"><a href="./">${esc(t.linkRanking)}</a> › ${esc(t.chipsH1)}</p>
<h1>${esc(t.chipsH1)}</h1><p class="lede">${esc(t.chipsIntro)}</p>
${published.length ? chipTable(published, t.chipsGen) : ""}
${prelim.length ? `<h2>${esc(t.chipsPrelimTitle)}</h2><p class="fine">${esc(t.chipsPrelimNote)}</p>${chipTable(prelim, t.chipsGen)}` : ""}
${!published.length && !prelim.length ? empty : ""}
<p class="fine">${esc(t.speedNote)}</p>${generated ? `<p class="fine">${esc(fillAsOf(t.chipsAsOf, generated))}</p>` : ""}
${links}`;
  pages.push({ path: `${prefix}models/local-llm-speed-by-mac-chip.html`, alt: `${other}models/local-llm-speed-by-mac-chip.html`, title: t.chipsTitle, description: t.chipsDesc, body: chipsBody,
    lastmod: generated || models.lastReviewed, jsonLd: [crumbs(t.chipsH1, "models/local-llm-speed-by-mac-chip")] });

  // ---- API price comparison ----
  const byPrice = M.defaultOrder(cloud);
  const cheapest = byPrice.find((r) => r.blended != null);
  const priceRow = (r) => `<tr><td><strong>${esc(r.name)}</strong>${r.priceNote ? `<div class="note">${esc(r.priceNote[lang === "zh" ? "zh" : "en"] || r.priceNote.en || "")}</div>` : ""}</td><td>${esc(M.PROVIDERS[r.provider] || r.provider)}</td><td class="num">${M.usd(r.input)}</td><td class="num">${M.usd(r.output)}</td><td class="num">${r.cacheRead == null ? esc(t.none) : M.usd(r.cacheRead)}</td><td class="num">${r.cacheWrite == null ? esc(t.none) : M.usd(r.cacheWrite)}</td><td class="num"><strong>${M.usd(r.blended)}</strong></td><td class="num">${esc(r.context || t.none)}</td><td>${r.priceSrc && models.sources[r.priceSrc] ? `<a href="${esc(models.sources[r.priceSrc].url)}" rel="noopener">${esc(host(models.sources[r.priceSrc].url))}</a><div class="note">${esc(t.pricesChecked)} ${esc(models.sources[r.priceSrc].checked)}</div>` : esc(t.none)}</td></tr>`;
  const faq = cheapest ? [[t.pricesFaqQ1, M.fill(t.pricesFaqA1, { name: cheapest.name, price: M.usd(cheapest.blended) })], [t.pricesFaqQ2, t.pricesFaqA2], [t.pricesFaqQ3, t.pricesFaqA3]] : [];
  const pricesBody = `<p class="crumbs"><a href="./">${esc(t.linkRanking)}</a> › ${esc(t.linkPrices)}</p>
<h1>${esc(t.pricesH1)}</h1><p class="lede">${esc(t.pricesIntro)}</p>
<div class="table-scroll" tabindex="0"><table class="models"><thead><tr><th scope="col">${esc(t.cModel)}</th><th scope="col">${esc(t.fProvider)}</th><th scope="col" class="num">${esc(t.cInput)}</th><th scope="col" class="num">${esc(t.cOutput)}</th><th scope="col" class="num">${esc(t.cCache)}</th><th scope="col" class="num">${esc(t.pricesWritePrice)}</th><th scope="col" class="num">${esc(t.cBlended)}</th><th scope="col" class="num">${esc(t.cContext)}</th><th scope="col">${esc(t.pricesSource)}</th></tr></thead><tbody>${byPrice.map(priceRow).join("")}</tbody></table></div>
<p class="fine">${esc(t.blendNote)}</p><p class="fine">${esc(t.checked)}: ${sourceLine}</p>
${faq.map(([q, a]) => `<h3>${esc(q)}</h3><p>${esc(a)}</p>`).join("")}
${links}`;
  pages.push({ path: `${prefix}models/llm-api-price-comparison.html`, alt: `${other}models/llm-api-price-comparison.html`, title: t.pricesTitle, description: t.pricesDesc, body: pricesBody, lastmod: models.lastReviewed,
    jsonLd: [crumbs(t.linkPrices, "models/llm-api-price-comparison"), ...(faq.length ? [{ "@context": "https://schema.org", "@type": "FAQPage", mainEntity: faq.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) }] : [])] });
  return pages;
}

function fillAsOf(s, d) { return s.replace("{d}", d); }
