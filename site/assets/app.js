(function () {
  "use strict";

  const state = {
    lang: "en",
    plans: null,
    models: null,
    changes: null,
    sort: { key: "monthly", dir: 1 },
    changeFilter: "all",
    providers: new Set(["chatgpt", "claude", "gemini", "grok"])
  };
  const S = window.AQW_STATE; // pure helpers from community-state.js
  const CFG = window.SITE_CONFIG || {};
  const SITE_BASE = new URL("../", document.currentScript.src || new URL("assets/app.js", document.baseURI));
  const homePath = () => location.pathname.slice(SITE_BASE.pathname.length);
  const getData = (file, refresh = false) => S.readDataset(file, {
    base: SITE_BASE, embedded: window.__AQW_DATA, fetcher: fetch, refresh
  });

  const $ = (sel) => document.querySelector(sel);
  const t = (key) => (I18N[state.lang] && I18N[state.lang][key]) || I18N.en[key] || key;
  const loc = (obj) => (obj ? obj[state.lang] || obj.en : "");
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  function money(v, digits) {
    if (v == null || !isFinite(v)) return t("calc.na");
    const d = digits != null ? digits : v >= 100 ? 0 : v >= 1 ? 2 : 3;
    return "$" + v.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
  }
  function host(url) { try { return new URL(url).hostname.replace(/^www\./, ""); } catch (e) { return url; } }
  function providerById(id) { return state.plans.providers.find((p) => p.id === id); }

  // ---------- language ----------
  function initLang() {
    let lang = "en";
    const q = new URLSearchParams(location.search).get("lang");
    if (q === "zh" || q === "en") lang = q;
    else if (/^zh(\/|$)/.test(homePath())) lang = "zh"; // /zh/ is the Chinese home page
    else {
      try { const saved = localStorage.getItem("aqw-lang"); if (saved) lang = saved; } catch (e) { /* storage blocked */ }
    }
    state.lang = lang;
    // The nav button and the footer button both switch the language.
    document.querySelectorAll("[data-lang-toggle]").forEach((b) => b.addEventListener("click", () => {
      state.lang = state.lang === "en" ? "zh" : "en";
      try { localStorage.setItem("aqw-lang", state.lang); } catch (e) { /* ignore */ }
      // On the two home pages the language is part of the address, so a shared link keeps its language.
      if (/^(zh\/?)?(index\.html)?$/.test(homePath()) && !location.search) {
        const to = SITE_BASE.pathname + (state.lang === "zh" ? "zh/" : "");
        if (location.pathname !== to) { history.replaceState(null, "", to + location.hash); }
      }
      renderAll();
    }));
  }

  function applyStatic() {
    document.documentElement.lang = state.lang === "zh" ? "zh-Hant" : "en";
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    document.querySelectorAll("[data-i18n-title]").forEach((el) => { el.title = t(el.dataset.i18nTitle); });
    document.querySelectorAll("[data-lang-toggle]").forEach((b) => { b.textContent = state.lang === "en" ? "中文" : "English"; });
    // Theme labels follow the page language (theme-toggle.js reads I18N and <html lang>).
    if (window.AQW_THEME) window.AQW_THEME.refresh();
    applyPlatform();
  }

  // ---------- theme ----------
  // theme.js applies the saved choice in <head>; theme-toggle.js owns the controls and storage.
  const themeMode = () => (window.AQW_THEME ? window.AQW_THEME.get() : "auto");

  // ---------- config-driven pieces: sponsor link, install box, copy buttons ----------
  // Every [data-sponsor] element stays hidden unless SITE_CONFIG.sponsor.url is a valid https:// URL.
  function applySponsor() {
    const href = S.sponsorHref(CFG);
    const label = CFG.sponsor && typeof CFG.sponsor.label === "string" ? CFG.sponsor.label.trim() : "";
    document.querySelectorAll("[data-sponsor]").forEach((el) => {
      el.hidden = !href;
      if (href && el.tagName === "A") el.href = href;
    });
    if (label) document.querySelectorAll("[data-sponsor-label]").forEach((el) => { el.textContent = label; });
  }

  function installCommands() {
    const cmds = CFG.install && Array.isArray(CFG.install.commands) ? CFG.install.commands.filter((c) => typeof c === "string" && c.trim()) : [];
    return cmds.length ? cmds.map((c) => c.trim()) : null;
  }
  // The static HTML carries the default commands and links; config overrides them when set.
  function applyInstall() {
    const cmds = installCommands();
    if (cmds) document.querySelectorAll("[data-install-cmd] code").forEach((el) => { el.textContent = cmds.join("\n"); });
    const links = { notes: S.safeHttps(CFG.install && CFG.install.notesUrl), source: S.safeHttps(CFG.install && CFG.install.sourceUrl) };
    document.querySelectorAll("[data-install-link]").forEach((a) => { const h = links[a.dataset.installLink]; if (h) a.href = h; });
  }

  // Platform picker for the install box. The system is guessed locally from the browser (nothing is sent anywhere);
  // the buttons always let the visitor pick another one. The CPU is not guessed: the Linux and Windows commands choose x64/arm64 themselves.
  let installPlatform = null, macDefaults = null;
  function detectPlatform() {
    let id = "";
    try { id = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || navigator.userAgent || ""; } catch (e) { /* ignore */ }
    id = String(id).toLowerCase();
    if (/android|iphone|ipad|ipod|cros/.test(id)) return "mac"; // no desktop CLI on phones; show the default
    if (/win/.test(id)) return "windows";
    if (/linux|x11/.test(id)) return "linux";
    return "mac";
  }
  function applyPlatform() {
    const pre = $("#installCmd"), title = $("#installTitle"), req = $("#installReq"), pre2 = $("#installPrereq"), launch = $("#installLaunch");
    if (!pre || !title) return;
    const code = pre.querySelector("code");
    if (!macDefaults) macDefaults = code.textContent;
    if (!installPlatform) installPlatform = detectPlatform();
    const p = installPlatform;
    const plat = CFG.install && CFG.install.platforms && CFG.install.platforms[p];
    const mac = p === "mac" || !Array.isArray(plat) || !plat.length;
    const hero = $("#heroInstall");
    if (hero) hero.textContent = mac ? t("hero.ctaQp") : t("hero.ctaCli").replace("{os}", p === "windows" ? "Windows" : "Linux");
    document.querySelectorAll("[data-platform]").forEach((b) => {
      const on = b.dataset.platform === (mac ? "mac" : p);
      b.classList.toggle("on", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
    const group = document.querySelector(".install-os");
    if (group) group.setAttribute("aria-label", t("install.os"));
    if (mac) {
      code.textContent = (installCommands() || [macDefaults]).join("\n");
      title.textContent = t("install.title"); if (req) req.textContent = t("install.req");
      if (pre2) { pre2.hidden = false; pre2.textContent = t("install.prereq"); }
      if (launch) launch.textContent = t("install.launch");
    } else {
      code.textContent = plat.join("\n");
      title.textContent = t("install.title." + p); if (req) req.textContent = t("install.req." + p);
      if (pre2) pre2.hidden = true;
      if (launch) launch.textContent = t("install.launch." + p);
    }
  }
  function initPlatformButtons() {
    document.querySelectorAll("[data-platform]").forEach((b) => b.addEventListener("click", () => { installPlatform = b.dataset.platform; applyPlatform(); }));
  }

  // One delegated handler covers the hero box and the invite card (which is re-rendered).
  // Copies the commands as one line joined with " && "; without clipboard access, selects the text instead.
  function initCopyButtons() {
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-copy-target]");
      if (!btn) return;
      const pre = document.getElementById(btn.dataset.copyTarget);
      if (!pre) return;
      const status = btn.dataset.copyStatus ? document.getElementById(btn.dataset.copyStatus) : null;
      let text = S.joinCommands(pre.textContent);
      // Windows PowerShell 5.1 has no "&&"; its lines are joined with ";" instead.
      if (pre.id === "installCmd" && installPlatform === "windows") text = text.split(" && ").join("; ");
      const done = (key) => {
        btn.textContent = t(key);
        if (status) status.textContent = t(key);
        clearTimeout(btn._copyTimer);
        btn._copyTimer = setTimeout(() => { btn.textContent = t("install.copy"); if (status) status.textContent = ""; }, key === "install.copied" ? 1500 : 4000);
      };
      const manual = () => {
        try { window.getSelection().selectAllChildren(pre); } catch (err) { /* ignore */ }
        done("install.copyManual");
      };
      if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(() => done("install.copied"), manual);
      else manual();
    });
    // The hero button jumps to the install box; move keyboard focus there too.
    const hero = $("#heroInstall"), cmd = $("#installCmd");
    if (hero && cmd) hero.addEventListener("click", () => { try { cmd.focus({ preventScroll: true }); } catch (err) { cmd.focus(); } });
  }

  // Newest hand-check date across all data files.
  // Per-dataset check dates. The headline date is the OLDEST of them, so one freshly edited file never makes
  // every section look as new as the newest one; the full list is in the tooltip.
  function reviewedDates() {
    return [["plans", state.plans && state.plans.lastReviewed], ["changes", state.changes && state.changes.lastReviewed], ["resets", state.resets && state.resets.lastReviewed],
      ["models", state.models && state.models.lastReviewed]]
      .filter(([, d]) => typeof d === "string" && d);
  }
  function reviewedMax() {
    return reviewedDates().map(([, d]) => d).sort()[0] || "—";
  }

  // ---------- plans ----------
  // Each number in a plan row gets its own source label: the price can come from third-party coverage
  // while the usage multiple is on the vendor's page. "fields" overrides the row's confidence per field.
  function fieldConfidence(pl) {
    const f = pl.fields || {};
    const out = [["price", f.price || pl.confidence]];
    if (pl.multiple != null) out.push(["multiple", f.multiple || pl.confidence]);
    out.push(["limits", pl.confidence]);
    return out;
  }
  // Optional pl.fieldSources = { price: { url, checked }, multiple: {...}, limits: {...} } gives a field its own evidence.
  // Without one, an official field is backed by the row's source; a third-party ("reported") field says so plainly,
  // because the row's source link may not show that number.
  function fieldBadges(pl) {
    const fs = pl.fieldSources || {};
    return fieldConfidence(pl).map(([k, c]) => {
      const own = fs[k] && S.safeHttps(fs[k].url);
      const badge = `<span class="badge ${c}"${c === "reported" && !own ? ` title="${esc(t("conf.noFieldSource"))}"` : ""}>${t("conf." + c)}${c === "reported" && !own ? "*" : ""}</span>`;
      return `<span class="field-conf"><span class="field-name">${t("field." + k)}</span>${own ? `<a href="${esc(own)}" target="_blank" rel="noopener" title="${esc(host(own))}${fs[k].checked ? " · " + esc(fs[k].checked) : ""}">${badge}</a>` : badge}</span>`;
    }).join("");
  }

  function planRows(plans, color) {
    const maxMult = Math.max(...plans.map((pl) => pl.multiple || 0), 1);
    return plans.map((pl) => {
      // Linear scale: bar length is proportional to the quota multiple (5x is five times 1x).
      const width = pl.multiple ? Math.max(3, (pl.multiple / maxMult) * 100) : 0;
      const price = pl.priceUsd == null ? t("plan.varies") : pl.priceUsd === 0 ? "$0" : money(pl.priceUsd, pl.priceUsd % 1 ? 2 : 0) + t("plan.perMonth");
      const perX = pl.multiple && pl.priceUsd ? money(pl.priceUsd / pl.multiple, 2) + " " + t("plan.perX") : "";
      return `
          <li class="plan">
            <div class="plan-top">
              <span class="plan-name">${esc(pl.name)}</span>
              <span class="plan-price">${price}${perX ? `<small>${perX}</small>` : ""}</span>
            </div>
            <div class="bar" title="${pl.multiple ? pl.multiple + "x" : t("plan.noMultiple")}">
              <div class="bar-fill" style="width:${width}%;background:${color}"></div>
              <span class="bar-label">${pl.multiple ? pl.multiple + "x" : t("plan.noMultiple")}</span>
            </div>
            <p class="plan-sum">${esc(loc(pl.summary))}</p>
            <div class="plan-meta">
              ${fieldBadges(pl)}
              <a href="${esc(pl.source)}" target="_blank" rel="noopener">${t("plan.source")}: ${esc(host(pl.source))}</a>
              <span>${t("plan.checked")} ${esc(pl.checked)}</span>
            </div>
          </li>`;
    }).join("");
  }

  function renderPlans() {
    $("#providerGrid").innerHTML = state.plans.providers.map((p) => {
      const subs = (p.subproducts || []).map((s) => `
          <section class="subproduct">
            <h4>${esc(s.name)} <span class="sub-tag">${t("plan.alsoFrom")} ${esc(p.vendor)}</span></h4>
            ${s.note ? `<p class="sub-note">${esc(loc(s.note))}${s.noteSource ? ` <a href="${esc(s.noteSource)}" target="_blank" rel="noopener">${esc(host(s.noteSource))}</a>` : ""}</p>` : ""}
            <p class="window"><strong>${t("plan.window")}:</strong> ${esc(loc(s.window))}</p>
            ${s.support ? `<p class="support ${s.support}">${t("sup." + s.support)}</p>` : ""}
            <ul class="plans">${planRows(s.plans, p.color)}</ul>
          </section>`).join("");
      return `
        <article class="provider" style="--accent:${p.color}">
          <header class="provider-head">
            <span class="dot"></span>
            <h3>${esc(p.name)}</h3>
            <span class="vendor">${esc(p.vendor)}</span>
          </header>
          <p class="window"><strong>${t("plan.window")}:</strong> ${esc(loc(p.window))}</p>
          ${p.support ? `<p class="support ${p.support}">${t("sup." + p.support)}</p>` : ""}
          <ul class="plans">${planRows(p.plans, p.color)}</ul>
          ${subs}
        </article>`;
    }).join("");
  }

  // ---------- changes ----------
  const isUpcoming = (c) => c.upcoming && new Date(c.date + "T00:00:00Z") > new Date();
  function renderChanges() {
    const filters = ["all", "upcoming", ...new Set(state.changes.changes.map((c) => c.provider))];
    $("#changeFilters").innerHTML = filters.map((f) => {
      const label = f === "all" ? t("changes.all") : f === "upcoming" ? t("changes.upcoming") : providerById(f).name;
      return `<button type="button" class="chip ${state.changeFilter === f ? "on" : ""}" aria-pressed="${state.changeFilter === f}" data-filter="${f}">${esc(label)}</button>`;
    }).join("");
    $("#changeFilters").querySelectorAll("button").forEach((b) => b.addEventListener("click", () => { state.changeFilter = b.dataset.filter; renderChanges(); }));

    const items = state.changes.changes
      .filter((c) => state.changeFilter === "all" || (state.changeFilter === "upcoming" ? isUpcoming(c) : c.provider === state.changeFilter))
      .sort((a, b) => b.date.localeCompare(a.date));
    $("#timeline").innerHTML = items.map((c) => {
      const p = providerById(c.provider);
      return `
        <li class="change ${c.direction}">
          <time>${esc(c.date)}${isUpcoming(c) ? ` · <em>${t("changes.upcoming")}</em>` : ""}</time>
          <div class="change-body">
            <span class="pill" style="--accent:${p.color}">${esc(p.name)}</span>
            <span>${esc(loc(c.text))}</span>
          </div>
          <div class="plan-meta">
            <span class="badge ${c.confidence}">${t("conf." + c.confidence)}</span>
            <a href="${esc(c.source)}" target="_blank" rel="noopener">${esc(host(c.source))}</a>
          </div>
        </li>`;
    }).join("");
  }

  // ---------- calculator ----------
  // Monthly API cost from each vendor's own price list. Third-party benchmark scores are
  // not shown: they belong to third-party benchmark sites, which the section links to instead.
  function readInputs() {
    const num = (id) => Math.max(0, parseFloat($(id).value) || 0);
    return { inTok: num("#inTok"), outTok: num("#outTok"), req: num("#reqDay"), days: Math.min(31, Math.max(1, num("#days"))) };
  }

  function computeRows() {
    const inp = readInputs();
    return state.models.models
      .filter((m) => state.providers.has(m.provider))
      .map((m) => {
        const perReq = m.input != null && m.output != null ? (inp.inTok * m.input + inp.outTok * m.output) / 1e6 : null;
        return Object.assign({}, m, { monthly: perReq != null ? perReq * inp.req * inp.days : null, ctx: ctxTokens(m.context) });
      });
  }

  function ctxTokens(c) { const m = /^([\d.]+)\s*([kM])$/.exec(c || ""); return m ? parseFloat(m[1]) * (m[2] === "M" ? 1e6 : 1e3) : null; }

  function sortRows(rows) {
    const { key, dir } = state.sort;
    return rows.slice().sort((a, b) => {
      const av = a[key], bv = b[key];
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      if (typeof av === "string") return av.localeCompare(bv) * dir;
      return (av - bv) * dir;
    });
  }

  function best(rows, key, lowest) {
    const valid = rows.filter((r) => r[key] != null);
    if (!valid.length) return null;
    return valid.reduce((a, b) => (lowest ? (b[key] < a[key] ? b : a) : (b[key] > a[key] ? b : a)));
  }

  function renderCalc() {
    const inp = readInputs();
    const rows = sortRows(computeRows());
    const cheap = best(rows, "monthly", true), dear = best(rows, "monthly"), unpriced = rows.filter((r) => r.monthly == null);
    const tokens = (inp.inTok + inp.outTok) * inp.req * inp.days;
    const kpi = (label, name, val) => `<div class="kpi"><span class="kpi-label">${label}</span><strong>${name}</strong><span class="kpi-val">${val || ""}</span></div>`;
    $("#kpis").innerHTML =
      kpi(t("kpi.cheapest"), cheap ? esc(cheap.name) : t("calc.na"), cheap && money(cheap.monthly)) +
      kpi(t("kpi.dearest"), dear ? esc(dear.name) : t("calc.na"), dear && money(dear.monthly)) +
      kpi(t("kpi.tokens"), (tokens / 1e6).toFixed(2) + "M", `${esc(inp.req)} × ${esc(inp.days)}`) +
      (unpriced.length ? kpi(t("kpi.unpriced"), unpriced.length, esc(unpriced.map((r) => r.name).join(", "))) : "");

    const tbody = $("#modelTable tbody");
    if (!rows.length) { tbody.innerHTML = `<tr><td colspan="4" class="empty">${t("calc.empty")}</td></tr>`; }
    else tbody.innerHTML = rows.map((r) => {
      const p = providerById(r.provider);
      const priceSrc = r.priceSrc ? state.models.sources[r.priceSrc] : null;
      const price = r.input != null ? `${money(r.input, 2)} / ${money(r.output, 2)}` : t("calc.na");
      const note = r.priceNote ? `<div class="note">${esc(loc(r.priceNote))}</div>` : "";
      return `<tr>
        <td><span class="dot" style="background:${p.color}"></span>${esc(r.name)}<div class="note">${esc(p.vendor)}</div></td>
        <td class="num">${esc(r.context)}</td>
        <td class="num">${priceSrc ? `<a href="${esc(priceSrc.url)}" target="_blank" rel="noopener" title="${esc(priceSrc.name)} · ${esc(priceSrc.checked)}">${price}</a>` : price}${note}</td>
        <td class="num strong">${money(r.monthly)}</td>
      </tr>`;
    }).join("");

    document.querySelectorAll("#modelTable th").forEach((th) => {
      th.classList.toggle("sorted", th.dataset.sort === state.sort.key);
      th.dataset.dir = th.dataset.sort === state.sort.key ? (state.sort.dir > 0 ? "asc" : "desc") : "";
      if (th.dataset.sort) th.setAttribute("aria-sort", th.dataset.dir === "asc" ? "ascending" : th.dataset.dir === "desc" ? "descending" : "none");
    });
  }

  function initCalc() {
    const pf = $("#provFilter");
    state.plans.providers.filter((p) => state.models.models.some((m) => m.provider === p.id)).forEach((p) => {
      const lab = document.createElement("label");
      lab.className = "check";
      lab.innerHTML = `<input type="checkbox" value="${p.id}" checked><span class="dot" style="background:${p.color}"></span>${esc(p.name)}`;
      pf.appendChild(lab);
    });
    pf.addEventListener("change", (e) => {
      if (e.target.checked) state.providers.add(e.target.value); else state.providers.delete(e.target.value);
      renderCalc();
    });
    $("#calcForm").addEventListener("input", renderCalc);
    // Enter in a number field must not submit (an inline onsubmit would be blocked by the CSP).
    $("#calcForm").addEventListener("submit", (e) => e.preventDefault());
    const presets = { chat: [1500, 600, 50, 30], code: [30000, 3000, 200, 22], bulk: [8000, 400, 2000, 30] };
    document.querySelectorAll("[data-preset]").forEach((b) => b.addEventListener("click", () => {
      const v = presets[b.dataset.preset];
      ["#inTok", "#outTok", "#reqDay", "#days"].forEach((id, i) => { $(id).value = v[i]; });
      renderCalc();
    }));
    // Native buttons inside the headers make sorting reachable by keyboard (Enter/Space) and screen readers.
    document.querySelectorAll("#modelTable th[data-sort] .sort-btn").forEach((btn) => btn.addEventListener("click", () => {
      const k = btn.closest("th").dataset.sort;
      state.sort = { key: k, dir: state.sort.key === k ? -state.sort.dir : (k === "ctx" ? -1 : 1) };
      renderCalc();
    }));
  }

  // ---------- resets ----------
  state.rsFilter = "all";
  const DAY = 864e5;
  function sinceParts(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    return { d: Math.floor(s / 86400), h: Math.floor((s % 86400) / 3600), m: Math.floor((s % 3600) / 60), s: s % 60 };
  }
  function fmtSince(ms, withSecs) {
    const p = sinceParts(ms), pad = (n) => String(n).padStart(2, "0");
    return `${p.d}${t("unit.d")} ${pad(p.h)}:${pad(p.m)}${withSecs ? ":" + pad(p.s) : ""}`;
  }
  function fmtLocal(iso, timeKnown) {
    const d = new Date(iso);
    const date = d.toLocaleDateString(state.lang === "zh" ? "zh-TW" : "en-US", { year: "numeric", month: "short", day: "numeric" });
    if (timeKnown === false) return date;
    return date + " " + d.toLocaleTimeString(state.lang === "zh" ? "zh-TW" : "en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
  }
  function resetStats(now, provider) {
    const rs = state.resets.resets.filter((r) => !provider || r.provider === provider).slice().sort((a, b) => b.at.localeCompare(a.at));
    const last = rs[0];
    const in30 = rs.filter((r) => now - new Date(r.at) <= 30 * DAY);
    const month = rs.filter((r) => { const d = new Date(r.at); return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth(); });
    const recent = rs.filter((r) => now - new Date(r.at) <= 90 * DAY).map((r) => +new Date(r.at)).sort((a, b) => a - b);
    const gaps = recent.slice(1).map((v, i) => (v - recent[i]) / DAY);
    const avgGap = gaps.length ? gaps.reduce((a, b) => a + b, 0) / gaps.length : null;
    const all = rs.map((r) => +new Date(r.at)).sort((a, b) => a - b);
    const longest = all.slice(1).reduce((m, v, i) => Math.max(m, (v - all[i]) / DAY), 0);
    return { rs, last, in30, month, avgGap, longest };
  }

  function renderResets() {
    const now = new Date();
    const st = resetStats(now);
    const L = st.last;
    $("#rsStatus").innerHTML = `
      <div class="rs-label"><span class="pulse"></span>${t("rs.since")}</div>
      <div class="rs-clock" data-since="${esc(L.at)}">${fmtSince(now - new Date(L.at), true)}</div>
      <div class="rs-last"><span class="kind ${L.kind}">${t("rs.kind." + L.kind)}</span> ${esc(L.product)} · ${esc(fmtLocal(L.at, L.timeKnown))}</div>
      <p>${esc(loc(L.text))}</p>
      <div class="plan-meta"><span class="badge ${L.confidence === "official" ? "official" : "reported"}">${t("rs.conf." + L.confidence)}</span><a href="${esc(L.source)}" target="_blank" rel="noopener">${esc(host(L.source))}</a></div>`;
    const stat = (v, label) => `<div class="kpi"><span class="kpi-label">${label}</span><span class="kpi-val">${v}</span></div>`;
    $("#rsStats").innerHTML =
      stat(st.month.length, t("rs.thisMonth")) +
      stat(`${st.in30.length} <small>${st.in30.filter((r) => r.kind === "full").length} ${t("rs.full")} · ${st.in30.filter((r) => r.kind === "banked").length} ${t("rs.banked")}</small>`, t("rs.last30")) +
      stat(st.avgGap != null ? st.avgGap.toFixed(1) + t("unit.d") : t("calc.na"), t("rs.avgGap")) +
      stat(Math.round(st.longest) + t("unit.d"), t("rs.longest"));

    // months: last 7 calendar months
    const months = [];
    for (let i = 6; i >= 0; i--) { const d = new Date(now.getFullYear(), now.getMonth() - i, 1); months.push({ y: d.getFullYear(), m: d.getMonth(), full: 0, banked: 0 }); }
    st.rs.forEach((r) => { const d = new Date(r.at); const mo = months.find((x) => x.y === d.getFullYear() && x.m === d.getMonth()); if (mo) mo[r.kind]++; });
    const maxM = Math.max(1, ...months.map((x) => x.full + x.banked));
    const mLabel = (x) => new Date(x.y, x.m, 1).toLocaleDateString(state.lang === "zh" ? "zh-TW" : "en-US", { month: "short" });
    $("#rsMonths").innerHTML = `<div class="months">${months.map((x) => `
      <div class="month"><span class="mval">${x.full + x.banked || ""}</span><div class="mbar">
        ${x.banked ? `<i class="banked" style="height:${(x.banked / maxM) * 100}%"></i>` : ""}${x.full ? `<i class="full" style="height:${(x.full / maxM) * 100}%"></i>` : ""}
      </div><span class="mlab">${esc(mLabel(x))}</span></div>`).join("")}</div>
      <div class="radar-legend"><span><i class="lg full"></i>${t("rs.full")}</span><span><i class="lg banked"></i>${t("rs.banked")}</span></div>`;

    const hours = Array(24).fill(0);
    st.rs.filter((r) => r.timeKnown !== false).forEach((r) => { hours[new Date(r.at).getHours()]++; });
    const maxH = Math.max(1, ...hours);
    const peak = hours.indexOf(Math.max(...hours));
    $("#rsHours").innerHTML = `<div class="hours">${hours.map((n, h) => `<div class="hour" title="${String(h).padStart(2, "0")}:00 · ${n}">${n ? `<i class="full" style="height:${(n / maxH) * 100}%"></i>` : ""}</div>`).join("")}</div>
      <div class="hour-axis"><span>00</span><span>06</span><span>12</span><span>18</span><span>23</span></div>
      <p class="com-note">${t("rs.peak").replace("{h}", String(peak).padStart(2, "0") + ":00").replace("{n}", hours[peak])}</p>`;

    const filters = ["all", "full", "banked", "official"];
    $("#rsFilters").innerHTML = filters.map((f) => `<button type="button" class="chip ${state.rsFilter === f ? "on" : ""}" aria-pressed="${state.rsFilter === f}" data-f="${f}">${t("rs.filter." + f)}</button>`).join("");
    const items = st.rs.filter((r) => state.rsFilter === "all" || (state.rsFilter === "official" ? r.confidence === "official" : r.kind === state.rsFilter));
    $("#rsLedger").innerHTML = items.map((r) => `
      <li>
        <time>${esc(fmtLocal(r.at, r.timeKnown))}</time>
        <span class="kind ${r.kind}">${t("rs.kind." + r.kind)}</span>
        <span class="ledger-text">${esc(loc(r.text))} <span class="muted">· ${esc(r.product)}</span></span>
        <span class="plan-meta"><span class="badge ${r.confidence === "official" ? "official" : "reported"}">${t("rs.conf." + r.confidence)}</span><a href="${esc(r.source)}" target="_blank" rel="noopener">${esc(host(r.source))}</a></span>
      </li>`).join("");
    $("#rsTrackers").innerHTML = `${t("rs.trackers")} ${state.resets.trackers.map((tr) => `<a href="${esc(tr.url)}" target="_blank" rel="noopener">${esc(tr.name)}</a>`).join(" · ")}. ${t("plan.checked")} ${esc(state.resets.lastReviewed)}.`;
  }

  // ---------- live strip ----------
  state.loadedAt = new Date();
  // "At a glance": live proof only. No visitor count and no community "fastest" (that belongs in its card, next to n).
  function renderLive() {
    const now = new Date();
    const st = resetStats(now, "chatgpt");
    const upcoming = state.changes.changes.filter((c) => c.upcoming && new Date(c.date) > now).sort((a, b) => a.date.localeCompare(b.date))[0];
    const item = (label, value, extra) => `<span class="live-item"><span class="live-label">${label}</span><strong>${value}</strong>${extra ? `<small>${extra}</small>` : ""}</span>`;
    // Three different clocks, kept apart so "loaded just now" is never read as "measured just now":
    // when we last checked the vendor sources by hand, when community reports were last aggregated,
    // and when this browser last fetched the files.
    const comAt = state.community.generated ? new Date(state.community.generated) : null;
    $("#liveInner").innerHTML =
      `<span class="live-tag">${t("live.tag")}</span>` +
      item(t("live.lastReset"), `<span data-since="${esc(st.last.at)}">${fmtSince(now - new Date(st.last.at), true)}</span>`, t("rs.kind." + st.last.kind)) +
      item(t("live.resets30"), st.in30.length) +
      (upcoming ? item(t("live.next"), `<span data-until="${esc(upcoming.date)}T00:00:00Z">${fmtSince(new Date(upcoming.date + "T00:00:00Z") - now, false)}</span>`, esc(loc(upcoming.text).slice(0, 26)) + "…") : "") +
      item(t("live.checked"), esc(reviewedMax()), t("live.checkedNote")) +
      (comAt && !isNaN(comAt) ? item(t("live.collected"), esc(S.fmtUtc(state.community.generated)) + " UTC", state.community.sample ? t("live.example") : "") : "") +
      item(t("live.loaded"), `<span data-ago="${state.loadedAt.toISOString()}">${t("live.justNow")}</span>`, t("live.loadedNote"));
  }
  function tick() {
    const now = Date.now();
    document.querySelectorAll("[data-since]").forEach((el) => { el.textContent = fmtSince(now - new Date(el.dataset.since), true); });
    document.querySelectorAll("[data-until]").forEach((el) => { el.textContent = fmtSince(new Date(el.dataset.until) - now, false); });
    document.querySelectorAll("[data-ago]").forEach((el) => {
      const m = Math.floor((now - new Date(el.dataset.ago)) / 60000);
      el.textContent = m < 1 ? t("live.justNow") : t("live.minAgo").replace("{m}", m);
    });
  }

  function initResets() {
    $("#rsFilters").addEventListener("click", (e) => { const b = e.target.closest("button[data-f]"); if (!b) return; state.rsFilter = b.dataset.f; renderResets(); });
    setInterval(tick, 1000);
  }

  // ---------- community ----------
  const REP_TYPES = ["speed", "rating", "quota", "event"];
  state.repType = "speed";
  const modelName = (id) => { const m = state.models.models.find((x) => x.id === id); return m ? m.name.replace(/\s*\(.*\)$/, "") : id; };
  const fmtTokens = (v) => v >= 1e9 ? (v / 1e9).toFixed(1) + "B" : v >= 1e6 ? (v / 1e6).toFixed(1) + "M" : v >= 1e3 ? Math.round(v / 1e3) + "k" : String(v);
  const minPeople = () => state.community.minSamples || 3;
  // One-line invite inside a card that has no rows while other cards do.
  const emptyNote = () => `<p class="stat-empty"><a href="#install">${esc(t("empty.inline").replace("{n}", minPeople()))}</a></p>`;
  // Card footer: n meaning, window, compiled date (marked when older than 48 h) and the method link.
  function metaHtml(opts) {
    const m = S.statMeta(Object.assign({ generated: state.community.generated }, opts), t);
    return m.parts.map((p) => `<span>${esc(p)}</span>`).join(" · ") +
      ` · <span class="${m.stale ? "stale" : ""}">${esc(m.compiled)}${m.stale ? ` (${esc(t("stat.staleNote"))})` : ""}</span>` +
      ` · <a href="#sources">${esc(t("stat.method"))} ↗</a>`;
  }
  function installBox(id) {
    const cmds = installCommands() || [($("#installCmd") || {}).textContent || ""];
    return `<div class="install-cmd"><pre id="${id}Cmd" tabindex="0"><code>${esc(cmds.join("\n"))}</code></pre>
      <button type="button" class="btn btn-copy" data-copy-target="${id}Cmd" data-copy-status="${id}Copied">${esc(t("install.copy"))}</button>
      <span class="sr-only" id="${id}Copied" aria-live="polite"></span></div>`;
  }
  // Shown instead of the card grid while no row has reached the threshold: no empty charts, no "0 reports".
  function renderInvite(c) {
    const n = minPeople(), date = S.fmtUtc(c.generated);
    const pr = S.inviteProgress(c, n);
    const progressText = (pr.have === 0 ? t("empty.progress0") : pr.missing > 0 ? t("empty.progress") : t("empty.progressSpread"))
      .replace("{have}", pr.have).replace("{need}", pr.need).replace("{missing}", pr.missing);
    const s2 = esc(t("empty.s2")).replace("quotapilot share", "<code>quotapilot share</code>");
    $("#comInvite").innerHTML = `
      <h3>${esc(t("empty.title").replace("{n}", n))}</h3>
      <p>${esc(t("empty.sub").replace("{n}", n).replace("{d}", c.windowDays || 7))}</p>
      <p class="invite-progress"><strong>${esc(progressText)}</strong>${state.demo ? "" : ` <a href="?demo=1#community">${esc(t("empty.demo"))} →</a>`}</p>
      <ol class="invite-steps">
        <li><span>${esc(t("empty.s1"))}</span>${installBox("invite")}</li>
        <li><span>${s2}</span></li>
        <li><span>${esc(t("empty.s3"))}</span></li>
      </ol>
      <div class="invite-actions">
        <a class="btn btn-primary" href="#install">${esc(t("empty.cta"))}</a>
        <a href="#report">${esc(t("empty.alt"))} ↓</a>
      </div>
      <p class="invite-sponsor"><a id="inviteSponsor" href="#" target="_blank" rel="noopener" data-sponsor hidden>♥ ${esc(t("empty.sponsor"))}</a></p>
      <p class="stat-meta"><span class="${S.isStale(c.generated) ? "stale" : ""}">${esc(t("empty.meta").replace("{date}", date || "—"))}</span> · <a href="#sources">${esc(t("stat.method"))} ↗</a></p>`;
  }

  function renderCommunity() {
    const c = state.community;
    $("#sampleBanner").hidden = !c.sample;
    $("#comCompiled").textContent = c.generated ? S.fmtUtc(c.generated) + " UTC" : "—";
    // Totals only make sense next to published rows; with none, the invite card replaces the grid.
    const published = S.publishedCount(c);
    $("#comInvite").hidden = published > 0;
    $("#comGrid").hidden = published === 0;
    $("#comTotals").hidden = published === 0;
    if (!published) {
      renderInvite(c);
      applySponsor();
      return;
    }
    $("#comInvite").innerHTML = "";
    const reporters = c.totals.reporters;
    $("#comTotals").innerHTML = `<span><strong>${esc(c.totals.reports)}</strong> ${t("com.reports").replace("{d}", c.windowDays)}</span>
      <span><strong>${esc(reporters)}</strong> ${t(reporters === 1 ? "com.reporters1" : "com.reportersN")}</span>
      <span>${t("com.updated")} ${esc(S.fmtUtc(c.generated))} UTC</span>
      <a href="#report">${t("rep.title")} →</a>`;
    const rowsMeta = metaHtml({ days: c.windowDays, perRow: true });
    const setMeta = (id, has, html) => { const el = $(id); el.innerHTML = has ? html : ""; el.hidden = !has; };
    setMeta("#comSpeedMeta", c.speed.length, rowsMeta);
    setMeta("#comRatingMeta", c.ratings.length, rowsMeta);
    setMeta("#comQuotaMeta", c.quota.length, rowsMeta);
    setMeta("#comMixMeta", (c.tokenMix || []).length, rowsMeta);

    const maxSp = Math.max(1, ...c.speed.map((r) => r.p75 || r.median));
    $("#comSpeed").innerHTML = c.speed.length ? `<ul class="com-list">${c.speed.map((r) => {
      const p = providerById(state.models.models.find((m) => m.id === r.model)?.provider || "claude");
      return `<li><span class="com-name"><span class="dot" style="background:${p.color}"></span>${esc(modelName(r.model))}</span>
        <span class="range"><i class="iqr" style="left:${(r.p25 / maxSp) * 100}%;width:${Math.max(1, ((r.p75 - r.p25) / maxSp) * 100)}%;background:${p.color}"></i><i class="med" style="left:${(r.median / maxSp) * 100}%"></i></span>
        <span class="com-val">${r.median} <small>tok/s · n=${r.n}</small></span></li>`;
    }).join("")}</ul>` : emptyNote();

    $("#comRating").innerHTML = c.ratings.length ? `<ul class="com-list">${c.ratings.map((r) => `
      <li><span class="com-name">${esc(modelName(r.model))}${r.alert ? ` <span class="warn">${t("com.degraded")} ${Math.round(r.degradedShare * 100)}%</span>` : ""}</span>
        <span class="score-bar"><i style="width:${r.avg * 10}%"></i></span>
        <span class="com-val">${r.avg}<small>/10 · n=${r.n}</small></span></li>`).join("")}</ul>` : emptyNote();

    // data-label lets phones show each cell as "label: value" when the table stacks.
    const dl = (key) => `data-label="${esc(t(key))}"`;
    $("#comQuota").innerHTML = c.quota.length ? `<table class="com-table"><thead><tr><th>${t("com.plan")}</th><th>${t("com.window")}</th><th class="num">${t("com.tokens")}</th><th class="num">${t("com.usd")}</th></tr></thead><tbody>${c.quota.map((q) => `
      <tr><td ${dl("com.plan")}><span class="dot" style="background:${providerById(q.provider).color}"></span>${esc(providerById(q.provider).name)} ${esc(q.plan)}</td>
      <td ${dl("com.window")}>${q.window === "5h" ? t("com.w5h") : t("com.wweek")}</td>
      <td class="num" ${dl("com.tokens")} title="${esc(t("stat.lowerHelp"))}">≥${fmtTokens(q.medianTokens)}<small>${fmtTokens(q.p25Tokens)}–${fmtTokens(q.p75Tokens)} · n=${q.n}</small></td>
      <td class="num" ${dl("com.usd")}>${q.medianUsd != null ? money(q.medianUsd, 0) : t("calc.na")}</td></tr>`).join("")}</tbody></table>` : emptyNote();

    const mix = c.tokenMix || [];
    $("#comMix").innerHTML = mix.length ? `<table class="com-table"><thead><tr><th>${t("col.model")}</th><th class="num">${t("com.mixRatio")}</th><th class="num">${t("com.mixCache")}</th></tr></thead><tbody>${mix.map((r) => `
      <tr><td ${dl("col.model")}>${esc(modelName(r.model))}</td>
      <td class="num" ${dl("com.mixRatio")}>${r.inputPerOutput}:1<small>${r.inputPerOutputP25}–${r.inputPerOutputP75} · n=${r.n}</small></td>
      <td class="num" ${dl("com.mixCache")}>${r.cacheHit != null ? Math.round(r.cacheHit * 100) + "%" : t("calc.na")}${r.cacheWriteShare != null ? `<small>${t("com.mixWrite").replace("{p}", Math.round(r.cacheWriteShare * 100))}</small>` : ""}</td></tr>`).join("")}</tbody></table>` : emptyNote();

    // shift UTC hours into the viewer's local time
    const off = -new Date().getTimezoneOffset() / 60;
    const hours = Array(24).fill(0).map(() => ({}));
    let total = 0;
    Object.entries(c.events.byHourUtc).filter(([prov]) => providerById(prov)).forEach(([prov, arr]) => arr.forEach((n, h) => {
      const lh = (((h + Math.round(off)) % 24) + 24) % 24; hours[lh][prov] = (hours[lh][prov] || 0) + n; total += n;
    }));
    setMeta("#comEventsMeta", total > 0, metaHtml({ days: c.eventWindowDays || 30 }));
    if (!total) { $("#comEvents").innerHTML = emptyNote(); return; }
    const maxH = Math.max(...hours.map((o) => Object.values(o).reduce((a, b) => a + b, 0)), 1);
    const order = state.plans.providers.map((p) => p.id).filter((p) => c.events.byHourUtc[p]);
    $("#comEvents").innerHTML = `<div class="hours">${hours.map((o, h) => `<div class="hour" title="${String(h).padStart(2, "0")}:00 · ${Object.values(o).reduce((a, b) => a + b, 0)}">${order.map((p) => o[p] ? `<i style="height:${(o[p] / maxH) * 100}%;background:${providerById(p).color}"></i>` : "").join("")}</div>`).join("")}</div>
      <div class="hour-axis"><span>00</span><span>06</span><span>12</span><span>18</span><span>23</span></div>
      <div class="radar-legend">${order.map((p) => `<span><i style="background:${providerById(p).color}"></i>${esc(providerById(p).name)}</span>`).join("")}</div>`;
  }

  // ---------- report form ----------
  function field(id, label, input) { return `<label for="${id}"><span>${label}</span>${input}</label>`; }
  function modelSelect(id, withNone) {
    return `<select id="${id}">${withNone ? `<option value="">—</option>` : ""}${state.models.models.map((m) => `<option value="${m.id}">${esc(m.name)}</option>`).join("")}</select>`;
  }
  function planSelect(id) {
    return `<select id="${id}">${state.plans.providers.map((p) => `<optgroup label="${esc(p.name)}">${p.plans.filter((pl) => pl.priceUsd !== 0).map((pl) => `<option value="${p.id}|${esc(pl.name)}">${esc(p.name)} ${esc(pl.name)}</option>`).join("")}</optgroup>`).join("")}</select>`;
  }
  function localNow() { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); }

  // Cloudflare Turnstile: the script loads only when the report preview opens, never on page load.
  let tsWidget = null, tsLoading = null;
  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve();
    if (tsLoading) return tsLoading;
    tsLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
      s.async = true;
      s.onload = () => (window.turnstile ? resolve() : reject(new Error("turnstile")));
      s.onerror = () => { s.remove(); reject(new Error("turnstile")); };
      document.head.appendChild(s);
    }).catch((e) => { tsLoading = null; throw e; });
    return tsLoading;
  }
  function cleanupTurnstile() {
    if (tsWidget != null && window.turnstile) { try { window.turnstile.remove(tsWidget); } catch (e) { /* already gone */ } }
    tsWidget = null;
  }

  // Drafts survive a re-render (language switch, report type switch): values are kept by control id and put back.
  state.repDrafts = {};
  function snapshotReport() {
    const out = {};
    document.querySelectorAll("#repForm input[id], #repForm select[id]").forEach((el) => { out[el.id] = el.type === "checkbox" ? el.checked : el.value; });
    return out;
  }
  function restoreReport(d) {
    Object.entries(d || {}).forEach(([id, v]) => {
      const el = document.getElementById(id);
      if (!el) return;
      if (el.type === "checkbox") el.checked = !!v;
      else if (el.tagName !== "SELECT" || [...el.options].some((o) => o.value === v)) el.value = v;
    });
    const sc = $("#rRaScore"); if (sc) $("#rRaScoreOut").textContent = sc.value;
  }
  // A quota report names the model that was used: only models of the plan's provider are offered.
  function syncQuotaModels() {
    const plan = $("#rQuPlan"), sel = $("#rQuModel");
    if (!plan || !sel) return;
    const provider = plan.value.split("|")[0], keep = sel.value;
    const list = state.models.models.filter((m) => m.provider === provider);
    sel.innerHTML = (list.length ? list : state.models.models).map((m) => `<option value="${m.id}">${esc(m.name)}</option>`).join("");
    if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
  }
  function renderReportForm() {
    if (state.repRendered) state.repDrafts[state.repRendered] = snapshotReport();
    $("#repType").innerHTML = REP_TYPES.map((k) => `<button type="button" aria-pressed="${state.repType === k}" class="${state.repType === k ? "on" : ""}" data-type="${k}">${t("rep.type." + k)}</button>`).join("");
    const f = {
      speed: field("rSpModel", t("rep.model"), modelSelect("rSpModel")) +
        field("rSpClient", t("rep.client"), `<select id="rSpClient"><option value="">—</option>${["CLI", "Desktop", "API", "Web", "Other"].map((k) => `<option value="${k}">${k}</option>`).join("")}</select>`) +
        field("rSpTokens", t("rep.outTokens"), `<input id="rSpTokens" type="number" min="50" step="1" placeholder="1500" required>`) +
        field("rSpSecs", t("rep.seconds"), `<input id="rSpSecs" type="number" min="0.2" step="0.1" placeholder="20" required>`),
      rating: field("rRaModel", t("rep.model"), modelSelect("rRaModel")) +
        field("rRaScore", t("rep.score"), `<input id="rRaScore" type="range" min="1" max="10" value="7"><output id="rRaScoreOut">7</output>`) +
        field("rRaTask", t("rep.task"), `<select id="rRaTask">${["coding", "chat", "writing", "research", "other"].map((k) => `<option value="${k}">${t("task." + k)}</option>`).join("")}</select>`) +
        `<label class="check-row" for="rRaDeg"><input id="rRaDeg" type="checkbox"> <span>${t("rep.degraded")}</span></label>`,
      quota: field("rQuPlan", t("rep.plan"), planSelect("rQuPlan")) +
        field("rQuModel", t("rep.modelUsed"), modelSelect("rQuModel")) +
        field("rQuWindow", t("rep.window"), `<select id="rQuWindow"><option value="5h">${t("com.w5h")}</option><option value="weekly">${t("com.wweek")}</option></select>`) +
        field("rQuPct", t("rep.pct"), `<input id="rQuPct" type="number" min="0.5" max="100" step="0.1" placeholder="12" required>`) +
        field("rQuTok", t("rep.tokensUsed"), `<input id="rQuTok" type="number" min="1000" step="1000" placeholder="850000" required>`),
      event: field("rEvPlan", t("rep.plan"), planSelect("rEvPlan")) +
        field("rEvKind", t("rep.kind"), `<select id="rEvKind"><option value="hit_limit">${t("rep.kind.hit")}</option><option value="reset">${t("rep.kind.reset")}</option></select>`) +
        field("rEvWhen", t("rep.when"), `<input id="rEvWhen" type="datetime-local" value="${localNow()}">`)
    }[state.repType];
    $("#repForm").innerHTML = `<div class="rep-fields">${f}</div><p class="fine">${t("rep.help." + state.repType)}</p><div class="rep-actions"><button type="submit" class="btn">${t("rep.submit")}</button><span class="rep-err" id="repErr" role="alert"></span></div>`;
    const sc = $("#rRaScore"); if (sc) sc.addEventListener("input", () => { $("#rRaScoreOut").textContent = sc.value; });
    restoreReport(state.repDrafts[state.repType]);
    syncQuotaModels();
    const qp = $("#rQuPlan"); if (qp) qp.addEventListener("change", syncQuotaModels);
    state.repRendered = state.repType;
  }

  function buildReport() {
    const v = (id) => $(id) && $(id).value;
    const n = (id) => parseFloat(v(id));
    const now = new Date().toISOString();
    switch (state.repType) {
      case "speed": {
        const r = { type: "speed", model: v("#rSpModel"), client: v("#rSpClient") || undefined, via: "site", outputTokens: n("#rSpTokens"), seconds: n("#rSpSecs"), date: now };
        if (!(r.outputTokens >= 50) || !(r.seconds >= 0.2)) return { error: t("rep.err.speed"), fields: ["rSpTokens", "rSpSecs"] };
        return { r, title: `Speed: ${modelName(r.model)} ${(r.outputTokens / r.seconds).toFixed(1)} tok/s` };
      }
      case "rating": {
        const r = { type: "rating", model: v("#rRaModel"), score: n("#rRaScore"), degraded: $("#rRaDeg").checked, task: v("#rRaTask"), date: now };
        return { r, title: `Rating: ${modelName(r.model)} ${r.score}/10${r.degraded ? " (feels worse)" : ""}` };
      }
      case "quota": {
        const [provider, plan] = v("#rQuPlan").split("|");
        const r = { type: "quota", provider, plan, model: v("#rQuModel"), window: v("#rQuWindow"), percentUsed: n("#rQuPct"), tokensUsed: n("#rQuTok"), date: now };
        if (!(r.percentUsed >= 0.5 && r.percentUsed <= 100) || !(r.tokensUsed >= 1000)) return { error: t("rep.err.quota"), fields: ["rQuPct", "rQuTok"] };
        return { r, title: `Quota: ${provider} ${plan} ${r.window} ≈ ${fmtTokens(r.tokensUsed / (r.percentUsed / 100))} tokens` };
      }
      default: {
        const [provider, plan] = v("#rEvPlan").split("|");
        const when = new Date(v("#rEvWhen"));
        // Same window as the collector: not in the future, not more than 8 days back.
        if (isNaN(when) || when.getTime() > Date.now() + 5 * 60000 || when.getTime() < Date.now() - 8 * 86400000) return { error: t("rep.err.when"), fields: ["rEvWhen"] };
        const r = { type: "event", provider, plan, kind: v("#rEvKind"), date: when.toISOString() };
        return { r, title: `Limit event: ${provider} ${plan} ${r.kind}` };
      }
    }
  }

  function onReportSubmit(e) {
    e.preventDefault();
    const res = buildReport();
    $("#repErr").textContent = res.error || "";
    document.querySelectorAll("#repForm [aria-invalid]").forEach((el) => { el.removeAttribute("aria-invalid"); el.removeAttribute("aria-describedby"); });
    if (res.error) {
      (res.fields || []).forEach((id) => { const el = document.getElementById(id); if (el) { el.setAttribute("aria-invalid", "true"); el.setAttribute("aria-describedby", "repErr"); } });
      const first = res.fields && document.getElementById(res.fields[0]); if (first) first.focus();
      return;
    }
    const json = JSON.stringify(res.r, null, 2);
    const community = window.SITE_CONFIG.community || {};
    const out = $("#repOut");
    out.hidden = false;
    // Anonymous only: without the collector there is nowhere to send a report.
    if (!community.collector) { out.innerHTML = `<p class="rep-err">${t("rep.failed")}</p>`; return; }
    let install = null;
    try { install = localStorage.getItem("aqw-install"); } catch (e) { /* storage blocked */ }
    if (!install) {
      install = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2)).replace(/[^A-Za-z0-9-]/g, "");
      try { localStorage.setItem("aqw-install", install); } catch (e) { /* ignore */ }
    }
    const siteKey = community.turnstileSiteKey || "";
    let token = null;
    // On failure the report is kept so the user can retry.
    const failed = (message) => {
      out.innerHTML = `<p class="rep-err" role="alert">${esc(message)}</p>
        <p><button type="button" class="btn" id="repRetry">${t("rep.retry")}</button></p>
        <pre>${esc(json)}</pre>`;
      // A Turnstile token works once, so a retry goes back to the preview for a fresh check.
      $("#repRetry").addEventListener("click", siteKey ? preview : send);
    };
    const send = () => {
      const payload = { install, reports: [res.r] };
      if (siteKey) payload.turnstile = token;
      token = null;
      cleanupTurnstile();
      out.innerHTML = `<p>${t("rep.sending")}</p>`;
      fetch(community.collector + "/v1/report", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) })
        .then((r) => r.json().catch(() => ({})).then((body) => ({ ok: r.ok, status: r.status, body })))
        .then(({ ok, status, body }) => { if (ok) { out.innerHTML = `<p>${t("rep.thanks")}</p>`; try { localStorage.setItem("aqw-sent", "1"); } catch (e) { /* ignore */ } $("#repForget").hidden = false; } else failed(status === 403 && siteKey ? t("rep.tsFailed") : body.error || t("rep.failed")); })
        .catch(() => failed(t("rep.failed")));
    };
    // Nothing leaves the browser until the person has seen the exact payload and pressed Send.
    // With a Turnstile site key, the check script loads only now and Send stays off until a token arrives.
    const preview = () => {
      cleanupTurnstile();
      token = null;
      out.hidden = false;
      out.innerHTML = `<p><strong>${t("rep.previewTitle")}</strong></p>
      <p class="fine">${t("rep.previewNote")}</p>
      <pre>${esc(JSON.stringify({ install, reports: [res.r] }, null, 2))}</pre>` +
        (siteKey ? `<p class="fine">${t("rep.tsNote")}</p><div id="repTurnstile"></div><p class="fine" id="repTsMsg" role="status"></p>` : "") +
        `<div class="rep-actions"><button type="button" class="btn" id="repSend">${t("rep.send")}</button><button type="button" class="btn ghost" id="repCancel">${t("rep.cancel")}</button></div>`;
      const sendBtn = $("#repSend"), msg = $("#repTsMsg");
      sendBtn.disabled = !!siteKey;
      sendBtn.addEventListener("click", send);
      $("#repCancel").addEventListener("click", () => { cleanupTurnstile(); out.hidden = true; out.innerHTML = ""; });
      if (!siteKey) return;
      const problem = (key) => {
        token = null;
        sendBtn.disabled = true;
        msg.className = "rep-err";
        msg.innerHTML = `${esc(t(key))} <button type="button" class="linklike" id="repTsRetry">${t("rep.retry")}</button>`;
        $("#repTsRetry").addEventListener("click", startTurnstile);
      };
      const startTurnstile = () => {
        cleanupTurnstile();
        token = null;
        sendBtn.disabled = true;
        msg.className = "fine";
        msg.textContent = t("rep.tsWait");
        loadTurnstile().then(() => {
          if (!msg.isConnected) return; // the preview was closed meanwhile
          // Managed mode (set on the widget in the Cloudflare dashboard); the language follows the page.
          tsWidget = window.turnstile.render($("#repTurnstile"), {
            sitekey: siteKey,
            theme: themeMode(),
            language: state.lang === "zh" ? "zh-TW" : "en",
            callback: (tok) => { token = tok; sendBtn.disabled = false; msg.className = "fine"; msg.textContent = ""; },
            "expired-callback": () => problem("rep.tsExpired"),
            "timeout-callback": () => problem("rep.tsExpired"),
            "error-callback": () => problem("rep.tsError")
          });
        }).catch(() => { if (msg.isConnected) problem("rep.tsLoadFail"); });
      };
      startTurnstile();
    };
    preview();
  }

  function initCommunity() {
    $("#repType").addEventListener("click", (e) => {
      const b = e.target.closest("button[data-type]"); if (!b) return;
      state.repType = b.dataset.type; cleanupTurnstile(); $("#repOut").hidden = true; renderReportForm();
    });
    $("#repForm").addEventListener("submit", onReportSubmit);
    // Right to erasure for the web form: the browser's random id asks the collector to delete its reports,
    // then the id itself is removed so later reports start a new, unlinked id.
    const forgetBox = $("#repForget"), base = (window.SITE_CONFIG.community || {}).collector;
    const stored = () => { try { return localStorage.getItem("aqw-install"); } catch (e) { return null; } };
    const sent = () => { try { return localStorage.getItem("aqw-sent") === "1"; } catch (e) { return false; } };
    forgetBox.hidden = !(base && stored() && sent());
    $("#repForgetBtn").addEventListener("click", () => {
      const id = stored(); if (!id || !confirm(t("rep.forgetConfirm"))) return;
      fetch(base + "/v1/forget", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ install: id }) })
        .then((r) => { if (!r.ok) throw new Error(); try { localStorage.removeItem("aqw-install"); localStorage.removeItem("aqw-sent"); } catch (e) { /* ignore */ } forgetBox.innerHTML = esc(t("rep.forgetDone")); })
        .catch(() => { forgetBox.insertAdjacentHTML("beforeend", ` <span class="rep-err">${esc(t("rep.failed"))}</span>`); });
    });
  }

  // ---------- partners / ads ----------
  function renderPartners() {
    const cfg = window.SITE_CONFIG || { affiliates: {}, officialPricing: {}, ads: {} };
    let anyAffiliate = false;
    $("#partnerGrid").innerHTML = state.plans.providers.map((p) => {
      const aff = cfg.affiliates[p.id];
      if (aff) anyAffiliate = true;
      const href = aff || cfg.officialPricing[p.id];
      const paid = p.plans.filter((pl) => pl.priceUsd > 0).map((pl) => pl.priceUsd);
      const from = paid.length ? money(Math.min(...paid), 0) + t("plan.perMonth") : "";
      return `<a class="partner" style="--accent:${p.color}" href="${esc(href)}" target="_blank" rel="${aff ? "sponsored noopener" : "noopener"}" data-affiliate="${p.id}">
        <span class="dot"></span><strong>${esc(p.name)}</strong>
        <span class="partner-from">${t("partners.from")} ${from}</span>
        <span class="partner-cta">${t("partners.cta")} →</span></a>`;
    }).join("");
    $("#affDisclosure").hidden = !anyAffiliate;
    // No placeholder boxes: the single ad slot appears only once an ad network is actually configured.
    const adTop = $("#adTop");
    if (adTop) adTop.hidden = !(cfg.ads && cfg.ads.enabled === true);
  }

  function renderSources() {
    const seen = new Map();
    Object.values(state.models.sources).forEach((s) => seen.set(s.url, { label: s.name + " — " + s.covers, checked: s.checked }));
    state.plans.providers.forEach((p) => p.plans.forEach((pl) => { if (!seen.has(pl.source)) seen.set(pl.source, { label: p.name + " plans", checked: pl.checked }); }));
    state.resets.trackers.forEach((tr) => { if (!seen.has(tr.url)) seen.set(tr.url, { label: tr.name + " (reset ledger cross-check)", checked: state.resets.lastReviewed }); });
    state.changes.changes.forEach((c) => { if (!seen.has(c.source)) seen.set(c.source, { label: providerById(c.provider).name + " change log", checked: state.changes.lastReviewed }); });
    $("#sourceList").innerHTML = [...seen.entries()].map(([url, s]) =>
      `<li><a href="${esc(url)}" target="_blank" rel="noopener">${esc(host(url))}</a> <span>${esc(s.label)}</span> <span class="when">${t("plan.checked")} ${esc(s.checked)}</span></li>`).join("");
  }

  // Each dataset loads on its own and each section renders on its own: one failed file (or one bug) leaves
  // the other sections working, and the broken one shows a short message with a retry button.
  const DATA_FILES = { plans: "data/plans.json", models: "data/models.json", changes: "data/changes.json", resets: "data/resets.json" };
  const dataFile = (k) => (k === "community" ? (state.demo ? "data/community.sample.json" : "data/community.json") : DATA_FILES[k]);
  state.failed = new Set();
  async function loadData(only, bypassCache) {
    const keys = only || [...Object.keys(DATA_FILES), "community"];
    await Promise.all(keys.map(async (k) => {
      try {
        state[k] = await getData(dataFile(k), bypassCache);
        state.failed.delete(k);
      } catch (e) { state.failed.add(k); }
    }));
  }
  const SECTIONS = [
    { name: "plans", deps: ["plans"], at: "#providerGrid", render: () => { renderPlans(); renderPartners(); } },
    { name: "changes", deps: ["changes"], at: "#changeFilters", render: () => renderChanges() },
    { name: "resets", deps: ["resets"], at: "#rsStatus", init: () => initResets(), render: () => renderResets() },
    { name: "calc", deps: ["models", "plans"], at: "#provFilter", init: () => initCalc(), render: () => renderCalc() },
    { name: "community", deps: ["community", "models", "plans"], at: "#comCompiled", init: () => initCommunity(), render: () => { renderCommunity(); renderReportForm(); } },
    { name: "live", deps: ["changes", "resets"], at: "#liveInner", render: () => renderLive() },
    { name: "sources", deps: ["plans", "models", "resets", "changes"], at: "#sourceList", render: () => renderSources() }
  ];
  const inited = new Set();
  function runSection(sec) {
    const host = $(sec.at) && ($(sec.at).closest("section") || $(sec.at).parentElement);
    if (host) host.querySelectorAll(`[data-section-error="${sec.name}"]`).forEach((n) => n.remove());
    try {
      if (sec.deps.some((d) => !state[d])) throw new Error("missing data");
      if (sec.init && !inited.has(sec.name)) { sec.init(); inited.add(sec.name); }
      sec.render();
    } catch (e) {
      if (host) host.insertAdjacentHTML("afterbegin", `<p class="error" role="alert" data-section-error="${sec.name}">${esc(t("err.section"))} <button type="button" class="btn" data-retry>${esc(t("err.retry"))}</button></p>`);
    }
  }
  function initRetry() {
    document.addEventListener("click", async (e) => {
      if (!e.target.closest("[data-retry]")) return;
      const keys = [...state.failed];
      if (keys.length) await loadData(keys, true);
      renderAll();
    });
  }

  function renderAll() {
    applyStatic();
    $("#reviewed").textContent = reviewedMax();
    $("#footReviewed").textContent = reviewedMax();
    $("#reviewed").title = reviewedDates().map(([k, d]) => k + " " + d).join(" · ");
    SECTIONS.forEach(runSection);
    applySponsor();
  }

  function startAutoRefresh(demo) {
    if (window.__AQW_DATA) return;
    // Refreshes bypass the HTTP cache so a new community.json shows up within a minute.
    const get = (f) => getData(f, true);
    setInterval(async () => {
      if (document.hidden) return;
      try {
        const [community, resets, changes] = await Promise.all([get(demo ? "data/community.sample.json" : "data/community.json"), get("data/resets.json"), get("data/changes.json")]);
        Object.assign(state, { community, resets, changes, loadedAt: new Date() });
        renderChanges(); renderResets(); renderCommunity(); renderLive();
      } catch (e) { /* keep showing the last good data */ }
    }, 60000);
  }

  // The visitor counter (hit.js + collector /v1/visits) is kept for a future /stats page; the home page never shows it.

  async function load() {
    initLang();
    applyStatic();
    applySponsor();
    applyInstall();
    initPlatformButtons();
    applyPlatform();
    initCopyButtons();
    initRetry();
    const demo = new URLSearchParams(location.search).get("demo") === "1" || window.__AQW_DEMO === true;
    state.demo = demo;
    await loadData();
    renderAll();
    // The browser jumps to #anchor before the data has rendered, when the target is still near the top.
    // Jump again once the page has its real height; scroll-margin-top keeps the heading clear of the top bar.
    const target = location.hash.length > 1 && document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (target) requestAnimationFrame(() => target.scrollIntoView({ block: "start" }));
    startAutoRefresh(demo);
  }

  load();
})();
