(function () {
  "use strict";

  const state = {
    lang: "en",
    plans: null,
    models: null,
    changes: null,
    sort: { key: "intelligence", dir: -1 },
    changeFilter: "all",
    providers: new Set(["chatgpt", "claude", "gemini", "grok"]),
    radar: ["claude-opus-5-5", "gpt-6-1-sol", "gemini-4-carbon", "grok-4-7"]
  };
  const SLOT_COLORS = ["#3b82f6", "#e4572e", "#17a398", "#a259d9"];
  const S = window.AQW_STATE; // pure helpers from community-state.js
  const CFG = window.SITE_CONFIG || {};

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
    else {
      try { const saved = localStorage.getItem("aqw-lang"); if (saved) lang = saved; } catch (e) { /* storage blocked */ }
    }
    state.lang = lang;
    // The nav button and the footer button both switch the language.
    document.querySelectorAll("[data-lang-toggle]").forEach((b) => b.addEventListener("click", () => {
      state.lang = state.lang === "en" ? "zh" : "en";
      try { localStorage.setItem("aqw-lang", state.lang); } catch (e) { /* ignore */ }
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

  // One delegated handler covers the hero box and the invite card (which is re-rendered).
  // Copies the commands as one line joined with " && "; without clipboard access, selects the text instead.
  function initCopyButtons() {
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-copy-target]");
      if (!btn) return;
      const pre = document.getElementById(btn.dataset.copyTarget);
      if (!pre) return;
      const status = btn.dataset.copyStatus ? document.getElementById(btn.dataset.copyStatus) : null;
      const text = S.joinCommands(pre.textContent);
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
  function reviewedMax() {
    return [state.plans && state.plans.lastReviewed, state.changes && state.changes.lastReviewed, state.resets && state.resets.lastReviewed,
      state.models && state.models.lastReviewed, state.efforts && state.efforts.source && state.efforts.source.checked]
      .filter((d) => typeof d === "string" && d).sort().pop() || "—";
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
  function fieldBadges(pl) {
    return fieldConfidence(pl).map(([k, c]) =>
      `<span class="field-conf"><span class="field-name">${t("field." + k)}</span><span class="badge ${c}">${t("conf." + c)}</span></span>`).join("");
  }

  function planRows(plans, color) {
    const maxMult = Math.max(...plans.map((pl) => pl.multiple || 0), 1);
    return plans.map((pl) => {
      const width = pl.multiple ? Math.max(6, (Math.log(pl.multiple + 1) / Math.log(maxMult + 1)) * 100) : 0;
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
      return `<button type="button" class="chip ${state.changeFilter === f ? "on" : ""}" data-filter="${f}">${esc(label)}</button>`;
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
  function readInputs() {
    const num = (id) => Math.max(0, parseFloat($(id).value) || 0);
    return { inTok: num("#inTok"), outTok: num("#outTok"), req: num("#reqDay"), days: Math.min(31, Math.max(1, num("#days"))), minIq: num("#minIq") };
  }

  function computeRows() {
    const inp = readInputs();
    return state.models.models
      .filter((m) => state.providers.has(m.provider))
      .filter((m) => inp.minIq === 0 || (m.intelligence != null && m.intelligence >= inp.minIq))
      .map((m) => {
        const perReq = m.input != null && m.output != null ? (inp.inTok * m.input + inp.outTok * m.output) / 1e6 : null;
        return Object.assign({}, m, {
          monthly: perReq != null ? perReq * inp.req * inp.days : null,
          latency: m.speed ? inp.outTok / m.speed : null,
          value: m.intelligence != null && m.costPerTask ? m.intelligence / m.costPerTask : null
        });
      });
  }

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
    $("#minIqOut").textContent = inp.minIq;
    const rows = sortRows(computeRows());

    const cheap = best(rows, "monthly", true), smart = best(rows, "intelligence"), fast = best(rows, "speed"), value = best(rows, "value");
    const tokens = (inp.inTok + inp.outTok) * inp.req * inp.days;
    const kpi = (label, model, val) => `<div class="kpi"><span class="kpi-label">${label}</span><strong>${model ? esc(model.name) : t("calc.na")}</strong><span class="kpi-val">${val || ""}</span>${model && model.intelligence == null ? `<span class="kpi-label">${t("kpi.qualityUnknown")}</span>` : ""}</div>`;
    $("#kpis").innerHTML =
      kpi(t("kpi.cheapest"), cheap, cheap && money(cheap.monthly)) +
      kpi(t("kpi.smartest"), smart, smart && smart.intelligence) +
      kpi(t("kpi.fastest"), fast, fast && fast.speed + " tok/s") +
      kpi(t("kpi.value"), value, value && value.value.toFixed(1)) +
      `<div class="kpi"><span class="kpi-label">${t("kpi.tokens")}</span><strong>${(tokens / 1e6).toFixed(2)}M</strong><span class="kpi-val">${esc(inp.req)} × ${esc(inp.days)}</span></div>`;

    renderPick(rows, inp);

    const tbody = $("#modelTable tbody");
    if (!rows.length) { tbody.innerHTML = `<tr><td colspan="7" class="empty">${t("calc.empty")}</td></tr>`; }
    else tbody.innerHTML = rows.map((r) => {
      const p = providerById(r.provider);
      const priceSrc = r.priceSrc ? state.models.sources[r.priceSrc] : null;
      const price = r.input != null ? `${money(r.input, 2)} / ${money(r.output, 2)}` : t("calc.na");
      const note = r.priceNote ? `<div class="note">${esc(loc(r.priceNote))}</div>` : "";
      return `<tr>
        <td><span class="dot" style="background:${p.color}"></span>${esc(r.name)}<div class="note">${esc(p.vendor)} · ${esc(r.context)} ctx</div></td>
        <td class="num">${r.intelligence ?? t("calc.na")}</td>
        <td class="num">${r.speed ?? t("calc.na")}</td>
        <td class="num">${priceSrc ? `<a href="${esc(priceSrc.url)}" target="_blank" rel="noopener" title="${esc(priceSrc.name)} · ${esc(priceSrc.checked)}">${price}</a>` : price}${note}</td>
        <td class="num strong">${money(r.monthly)}</td>
        <td class="num">${r.latency != null ? r.latency.toFixed(1) + "s" : t("calc.na")}</td>
        <td class="num">${r.value != null ? r.value.toFixed(1) : t("calc.na")}</td>
      </tr>`;
    }).join("");

    document.querySelectorAll("#modelTable th").forEach((th) => {
      th.classList.toggle("sorted", th.dataset.sort === state.sort.key);
      th.dataset.dir = th.dataset.sort === state.sort.key ? (state.sort.dir > 0 ? "asc" : "desc") : "";
      if (th.dataset.sort) th.setAttribute("aria-sort", th.dataset.dir === "asc" ? "ascending" : th.dataset.dir === "desc" ? "descending" : "none");
    });

    renderScatter(rows);
  }

  // Workload pick: quality bar first, then the cheapest and the fastest model that clear it.
  // Models without a quality score or a verified price are listed as "not compared", not ranked last.
  function pickFor(rows, minIq) {
    const passing = rows.filter((r) => r.intelligence != null && r.intelligence >= minIq);
    const priced = passing.filter((r) => r.monthly != null);
    // Ties on the main key go to the other key, so equal-cost models resolve to the faster one and vice versa.
    const lowest = (list, key, tie) => list.filter((r) => r[key] != null).reduce((a, b) => {
      if (!a) return b;
      if (Math.abs(b[key] - a[key]) > 1e-9) return b[key] < a[key] ? b : a;
      return (b[tie] ?? Infinity) < (a[tie] ?? Infinity) ? b : a;
    }, null);
    return {
      passing, priced,
      cheapest: lowest(priced, "monthly", "latency"),
      fastest: lowest(priced, "latency", "monthly"),
      noQuality: rows.filter((r) => r.intelligence == null),
      noPrice: passing.filter((r) => r.monthly == null)
    };
  }

  function renderPick(rows, inp) {
    const p = pickFor(rows, inp.minIq);
    const bar = inp.minIq > 0 ? t("pick.bar").replace("{n}", inp.minIq) : t("pick.noBar");
    const facts = (r) => `${money(r.monthly)}${t("plan.perMonth")} · IQ ${r.intelligence}${r.latency != null ? " · " + r.latency.toFixed(1) + "s " + t("pick.perReply") : ""}`;
    const card = (label, r, why) => `<div class="pick-card"><span class="kpi-label">${label}</span><strong>${esc(r.name)}</strong><span>${esc(facts(r))}</span><span class="fine">${esc(why)}</span></div>`;
    let cards;
    if (!p.cheapest) cards = `<p class="com-empty">${t("pick.none")}</p>`;
    else if (p.fastest && p.fastest.id !== p.cheapest.id) {
      const extra = p.fastest.monthly - p.cheapest.monthly, saved = p.cheapest.latency != null ? p.cheapest.latency - p.fastest.latency : null;
      cards = card(t("pick.cheapest"), p.cheapest, t("pick.whyCheap").replace("{k}", p.priced.length)) +
        card(t("pick.fastest"), p.fastest, extra > 0.005
          ? t("pick.whyFast").replace("{s}", saved != null ? saved.toFixed(1) : "?").replace("{c}", money(extra))
          : t("pick.whyFastSame").replace("{s}", saved != null ? saved.toFixed(1) : "?"));
    } else cards = card(t("pick.both"), p.cheapest, t("pick.whyBoth").replace("{k}", p.priced.length));
    const names = (list) => list.map((r) => esc(r.name.replace(/\s*\(.*\)$/, ""))).join(", ");
    const skipped = [
      p.noPrice.length ? `<li>${t("pick.noPrice")}: ${names(p.noPrice)}</li>` : "",
      p.noQuality.length ? `<li>${t("pick.noQuality")}: ${names(p.noQuality)}</li>` : ""
    ].join("");
    $("#pick").innerHTML = `
      <div class="pick-head"><h3>${t("pick.title")}</h3><span class="pick-step">${t("pick.step1")} ${esc(bar)}</span></div>
      <div class="pick-cards">${cards}</div>
      <details class="pick-more"><summary>${t("pick.more")}</summary>
        <ul>${skipped}<li>${t("pick.limitIq")}</li><li>${t("pick.limitCost")}</li><li>${t("pick.limitSpeed")}</li></ul>
      </details>`;
  }

  function renderScatter(rows) {
    const pts = rows.filter((r) => r.intelligence != null && r.costPerTask);
    const W = 640, H = 340, m = { l: 48, r: 16, t: 16, b: 44 };
    if (!pts.length) { $("#scatter").innerHTML = `<p class="empty">${t("calc.empty")}</p>`; return; }
    const lx = (v) => Math.log10(v);
    const xs = pts.map((p) => lx(p.costPerTask)), ys = pts.map((p) => p.intelligence);
    const x0 = Math.floor(Math.min(...xs) * 2) / 2 - 0.1, x1 = Math.ceil(Math.max(...xs) * 2) / 2 + 0.1;
    const y0 = Math.floor((Math.min(...ys) - 3) / 5) * 5, y1 = Math.ceil((Math.max(...ys) + 2) / 5) * 5;
    const X = (v) => m.l + ((lx(v) - x0) / (x1 - x0)) * (W - m.l - m.r);
    const Y = (v) => H - m.b - ((v - y0) / (y1 - y0)) * (H - m.t - m.b);
    const xTicks = [0.25, 0.5, 1, 2, 5, 10, 20].filter((v) => lx(v) >= x0 && lx(v) <= x1);
    const yTicks = []; for (let v = y0; v <= y1; v += 5) yTicks.push(v);
    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(t("chart.title"))}">`;
    yTicks.forEach((v) => { svg += `<line class="grid" x1="${m.l}" x2="${W - m.r}" y1="${Y(v)}" y2="${Y(v)}"/><text class="tick" x="${m.l - 8}" y="${Y(v) + 4}" text-anchor="end">${v}</text>`; });
    xTicks.forEach((v) => { svg += `<line class="grid" y1="${m.t}" y2="${H - m.b}" x1="${X(v)}" x2="${X(v)}"/><text class="tick" x="${X(v)}" y="${H - m.b + 16}" text-anchor="middle">$${v}</text>`; });
    svg += `<text class="axis" x="${(W + m.l) / 2}" y="${H - 6}" text-anchor="middle">${esc(t("chart.x"))}</text>`;
    svg += `<text class="axis" transform="translate(12 ${(H - m.b + m.t) / 2}) rotate(-90)" text-anchor="middle">${esc(t("chart.y"))}</text>`;
    const placed = [];
    const hits = (b) => b.x < m.l || b.x + b.w > W - m.r || b.y < m.t || b.y + b.h > H - m.b ||
      placed.some((o) => b.x < o.x + o.w && b.x + b.w > o.x && b.y < o.y + o.h && b.y + b.h > o.y);
    pts.forEach((p) => { const px = X(p.costPerTask), py = Y(p.intelligence); placed.push({ x: px - 6, y: py - 6, w: 12, h: 12 }); });
    pts.slice().sort((a, b) => b.intelligence - a.intelligence).forEach((p) => {
      const c = providerById(p.provider).color, px = X(p.costPerTask), py = Y(p.intelligence);
      const label = p.name.replace(/\s*\(.*\)$/, "");
      const w = label.length * 6.6, h = 13;
      const tries = [[px + 9, py - 7, "start"], [px - 9 - w, py - 7, "end"], [px - w / 2, py + 9, "middle"], [px - w / 2, py - 22, "middle"], [px + 9, py + 6, "start"], [px - 9 - w, py + 6, "end"]];
      let pick = tries.find(([x, y]) => !hits({ x, y, w, h })) || tries[0];
      placed.push({ x: pick[0], y: pick[1], w, h });
      const tx = pick[2] === "start" ? pick[0] : pick[2] === "end" ? pick[0] + w : pick[0] + w / 2;
      svg += `<g class="pt"><circle cx="${px}" cy="${py}" r="6" fill="${c}"><title>${esc(p.name)} · IQ ${p.intelligence} · $${p.costPerTask}/task · ${p.speed} tok/s</title></circle>`;
      svg += `<text class="pt-label" x="${tx}" y="${pick[1] + 10}" text-anchor="${pick[2]}">${esc(label)}</text></g>`;
    });
    svg += `</svg>`;
    $("#scatter").innerHTML = svg;
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
    // The last number is a suggested quality bar for that kind of work; people can move the slider.
    const presets = { chat: [1500, 600, 50, 30, 30], code: [30000, 3000, 200, 22, 50], bulk: [8000, 400, 2000, 30, 25] };
    document.querySelectorAll("[data-preset]").forEach((b) => b.addEventListener("click", () => {
      const v = presets[b.dataset.preset];
      ["#inTok", "#outTok", "#reqDay", "#days", "#minIq"].forEach((id, i) => { $(id).value = v[i]; });
      renderCalc();
    }));
    // Native buttons inside the headers make sorting reachable by keyboard (Enter/Space) and screen readers.
    document.querySelectorAll("#modelTable th[data-sort] .sort-btn").forEach((btn) => btn.addEventListener("click", () => {
      const k = btn.closest("th").dataset.sort;
      state.sort = { key: k, dir: state.sort.key === k ? -state.sort.dir : (k === "name" || k === "monthly" || k === "latency" || k === "input" ? 1 : -1) };
      renderCalc();
    }));
  }

  // ---------- radar ----------
  const AXES = ["iq", "speed", "cost", "budget", "ctx"];
  function ctxTokens(c) { const m = /^([\d.]+)\s*([kM])$/.exec(c || ""); return m ? parseFloat(m[1]) * (m[2] === "M" ? 1e6 : 1e3) : null; }
  function logScore(v, lo, hi) { if (v == null || !(v > 0)) return 0; if (hi <= lo) return 100; return Math.max(0, Math.min(100, ((Math.log(hi) - Math.log(v)) / (Math.log(hi) - Math.log(lo))) * 100)); }

  function radarData() {
    const inp = readInputs();
    const budget = Math.max(0, parseFloat($("#budget").value) || 0);
    const pool = state.models.models.filter((m) => m.intelligence != null);
    const raw = pool.map((m) => {
      const perReq = m.input != null ? (inp.inTok * m.input + inp.outTok * m.output) / 1e6 : null;
      return { m, iq: m.intelligence, speed: m.speed, cost: m.costPerTask, budget: perReq ? budget / perReq : null, ctx: ctxTokens(m.context) };
    });
    const max = (k) => Math.max(...raw.map((r) => r[k] || 0));
    const min = (k) => Math.min(...raw.filter((r) => r[k] > 0).map((r) => r[k]));
    const costLo = min("cost"), costHi = max("cost");
    const reqVals = raw.filter((r) => r.budget > 0).map((r) => r.budget);
    const reqLo = Math.min(...reqVals), reqHi = Math.max(...reqVals);
    // A missing value stays null ("not scored"), never 0: an unknown price is not the same as an expensive one.
    return raw.map((r) => ({
      m: r.m, raw: r,
      score: {
        iq: r.iq ? (r.iq / max("iq")) * 100 : null,
        speed: r.speed ? (r.speed / max("speed")) * 100 : null,
        cost: r.cost > 0 ? logScore(r.cost, costLo, costHi) : null,
        budget: r.budget > 0 ? 100 - logScore(r.budget, reqLo, reqHi) : null,
        ctx: r.ctx ? (r.ctx / max("ctx")) * 100 : null
      }
    }));
  }

  function renderRadar() {
    const data = radarData();
    state.radar = state.radar.filter((id) => data.some((d) => d.m.id === id));
    const full = state.radar.length >= 4;
    $("#radarPick").innerHTML = data.map((d) => {
      const i = state.radar.indexOf(d.m.id), on = i >= 0;
      return `<button type="button" class="${on ? "on" : ""}" data-id="${d.m.id}" aria-pressed="${on}" ${!on && full ? "disabled" : ""}>
        <span class="swatch" style="${on ? `background:${SLOT_COLORS[i]};border-color:${SLOT_COLORS[i]}` : ""}"></span>${esc(d.m.name)}</button>`;
    }).join("");

    const sel = state.radar.map((id) => data.find((d) => d.m.id === id));
    const W = 520, H = 440, cx = W / 2, cy = H / 2 + 6, R = 150;
    const ang = (i) => -Math.PI / 2 + (i * 2 * Math.PI) / AXES.length;
    const pt = (i, v) => [cx + Math.cos(ang(i)) * R * v / 100, cy + Math.sin(ang(i)) * R * v / 100];
    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(t("radar.title"))}">`;
    [25, 50, 75, 100].forEach((v) => {
      svg += `<polygon class="ring" points="${AXES.map((_, i) => pt(i, v).join(",")).join(" ")}"/>`;
      svg += `<text class="ring-label" x="${cx + 4}" y="${cy - R * v / 100 - 3}">${v}</text>`;
    });
    AXES.forEach((a, i) => {
      const [x, y] = pt(i, 100), [lx, ly] = pt(i, 118);
      const anchor = Math.abs(lx - cx) < 10 ? "middle" : lx > cx ? "start" : "end";
      svg += `<line class="spoke" x1="${cx}" y1="${cy}" x2="${x}" y2="${y}"/>`;
      svg += `<text class="ax" x="${lx}" y="${ly + 4}" text-anchor="${anchor}">${esc(t("axis." + a))}</text>`;
    });
    sel.forEach((d, k) => {
      const c = SLOT_COLORS[k];
      const known = AXES.map((a, i) => (d.score[a] == null ? null : pt(i, d.score[a])));
      const pts = known.filter(Boolean);
      // Incomplete models are drawn as a dashed outline with no fill, skipping the unknown corner,
      // so their area can't be compared with complete shapes; the unknown axis gets a hollow "?" marker.
      const partial = pts.length < AXES.length;
      if (pts.length >= 2) svg += `<polygon class="shape${partial ? " partial" : ""}" points="${pts.map((p) => p.join(",")).join(" ")}" ${partial ? "fill=\"none\"" : `fill="${c}"`} stroke="${c}"><title>${esc(d.m.name)}</title></polygon>`;
      known.forEach((p, i) => {
        const label = `${esc(d.m.name)} · ${esc(t("axis." + AXES[i]))}`;
        if (p) svg += `<circle class="vertex" cx="${p[0]}" cy="${p[1]}" r="4" fill="${c}"><title>${label} ${Math.round(d.score[AXES[i]])}</title></circle>`;
        else { const [ux, uy] = pt(i, 104 + k * 4); svg += `<g class="unknown"><circle cx="${ux}" cy="${uy}" r="6" stroke="${c}"/><text x="${ux}" y="${uy + 3.5}" text-anchor="middle" fill="${c}">?</text><title>${label}: ${esc(t("radar.unknown"))}</title></g>`; }
      });
    });
    svg += `</svg>`;
    const missing = (d) => AXES.filter((a) => d.score[a] == null).map((a) => t("axis." + a));
    const legend = sel.map((d, k) => { const miss = missing(d); return `<span><i style="background:${SLOT_COLORS[k]}"></i>${esc(d.m.name)}${miss.length ? ` <small class="muted">(${esc(t("radar.incomplete"))}: ${esc(miss.join(", "))})</small>` : ""}</span>`; }).join("");
    $("#radarChart").innerHTML = svg + `<div class="radar-legend">${legend}</div>`;

    const fmtRaw = (d, a) => {
      const r = d.raw;
      if (a === "iq") return r.iq;
      if (a === "speed") return r.speed ? r.speed + " tok/s" : t("calc.na");
      if (a === "cost") return r.cost ? money(r.cost, 2) + " " + t("radar.task") : t("calc.na");
      if (a === "budget") return r.budget ? Math.floor(r.budget).toLocaleString("en-US") + " " + t("radar.req") : t("calc.na");
      return d.m.context;
    };
    $("#radarTable thead").innerHTML = `<tr><th>${t("col.model")}</th>${AXES.map((a) => `<th class="num">${esc(t("axis." + a))}</th>`).join("")}</tr>`;
    $("#radarTable tbody").innerHTML = sel.length ? sel.map((d, k) => `<tr>
      <td><span class="dot" style="background:${SLOT_COLORS[k]}"></span>${esc(d.m.name)}</td>
      ${AXES.map((a) => d.score[a] == null
        ? `<td class="num"><span class="score muted">—</span><span class="raw">${esc(t("radar.unknown"))}</span></td>`
        : `<td class="num"><span class="score">${Math.round(d.score[a])}</span><span class="raw">${esc(fmtRaw(d, a))}</span></td>`).join("")}
    </tr>`).join("") : `<tr><td colspan="6" class="empty">${t("calc.empty")}</td></tr>`;
  }

  function initRadar() {
    $("#radarPick").addEventListener("click", (e) => {
      const b = e.target.closest("button[data-id]"); if (!b || b.disabled) return;
      const id = b.dataset.id, i = state.radar.indexOf(id);
      if (i >= 0) state.radar.splice(i, 1); else if (state.radar.length < 4) state.radar.push(id);
      renderRadar();
    });
    $("#budget").addEventListener("input", renderRadar);
    $("#calcForm").addEventListener("input", renderRadar);
    document.querySelectorAll("[data-preset]").forEach((b) => b.addEventListener("click", renderRadar));
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
    $("#rsFilters").innerHTML = filters.map((f) => `<button type="button" class="chip ${state.rsFilter === f ? "on" : ""}" data-f="${f}">${t("rs.filter." + f)}</button>`).join("");
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

  // ---------- effort ladder ----------
  const EF_SHORT = { minimal: "Mi", low: "L", medium: "M", high: "H", xhigh: "XH", max: "Max", ultra: "U" };
  state.efPick = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6-1-sol", "gpt-6-astra", "gpt-6-1-terra"];
  state.efFamily = "gpt-6-1-sol";
  const EF_COLORS = ["#3b82f6", "#e4572e", "#17a398", "#a259d9", "#d4a017", "#6b7280", "#db2777", "#0ea5e9"];

  function renderEffort() {
    const E = state.efforts;
    $("#efPick").innerHTML = E.models.map((f) => `<button type="button" class="chip ${state.efPick.includes(f.model) ? "on" : ""}" data-m="${f.model}">${esc(f.name)}</button>`).join("");
    const fams = E.models.filter((f) => state.efPick.includes(f.model));
    const pts = fams.flatMap((f) => f.efforts.filter((e) => e.costPerTask));
    if (!pts.length) { $("#efChart").innerHTML = `<p class="empty">${t("calc.empty")}</p>`; }
    else {
      const W = 760, H = 380, m = { l: 48, r: 130, t: 16, b: 44 };
      const lx = Math.log10;
      const xs = pts.map((p) => lx(p.costPerTask)), ys = pts.map((p) => p.intelligence);
      const x0 = Math.min(...xs) - 0.15, x1 = Math.max(...xs) + 0.15;
      const y0 = Math.floor((Math.min(...ys) - 3) / 5) * 5, y1 = Math.ceil((Math.max(...ys) + 3) / 5) * 5;
      const X = (v) => m.l + ((lx(v) - x0) / (x1 - x0)) * (W - m.l - m.r);
      const Y = (v) => H - m.b - ((v - y0) / (y1 - y0)) * (H - m.t - m.b);
      let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(t("ef.chartTitle"))}">`;
      for (let v = y0; v <= y1; v += 5) svg += `<line class="grid" x1="${m.l}" x2="${W - m.r}" y1="${Y(v)}" y2="${Y(v)}"/><text class="tick" x="${m.l - 8}" y="${Y(v) + 4}" text-anchor="end">${v}</text>`;
      [0.01, 0.03, 0.1, 0.3, 1, 3, 10].filter((v) => lx(v) >= x0 && lx(v) <= x1).forEach((v) => {
        svg += `<line class="grid" y1="${m.t}" y2="${H - m.b}" x1="${X(v)}" x2="${X(v)}"/><text class="tick" x="${X(v)}" y="${H - m.b + 16}" text-anchor="middle">$${v}</text>`;
      });
      svg += `<text class="axis" x="${(W + m.l) / 2}" y="${H - 6}" text-anchor="middle">${esc(t("chart.x"))}</text>`;
      svg += `<text class="axis" transform="translate(12 ${(H - m.b + m.t) / 2}) rotate(-90)" text-anchor="middle">${esc(t("chart.y"))}</text>`;
      fams.forEach((f) => {
        const c = EF_COLORS[E.models.indexOf(f) % EF_COLORS.length];
        const es = f.efforts.filter((e) => e.costPerTask);
        svg += `<polyline fill="none" stroke="${c}" stroke-width="2.2" points="${es.map((e) => X(e.costPerTask) + "," + Y(e.intelligence)).join(" ")}"/>`;
        es.forEach((e, i) => {
          svg += `<circle cx="${X(e.costPerTask)}" cy="${Y(e.intelligence)}" r="${i === es.length - 1 ? 6 : 4.5}" fill="${c}" class="vertex"><title>${esc(f.name)} (${e.effort}) · IQ ${e.intelligence} · $${e.costPerTask}/task${e.speed ? " · " + e.speed + " tok/s" : ""}</title></circle>`;
          svg += `<text class="pt-label" x="${X(e.costPerTask)}" y="${Y(e.intelligence) - 9}" text-anchor="middle">${EF_SHORT[e.effort] || e.effort}</text>`;
        });
        const last = es[es.length - 1];
        svg += `<text class="pt-label strong" x="${X(last.costPerTask) + 10}" y="${Y(last.intelligence) + 4}" style="fill:${c}">${esc(f.name)}</text>`;
      });
      $("#efChart").innerHTML = svg + `</svg><p class="com-note">${t("ef.legend")}</p>`;
    }

    if (!E.models.some((f) => f.model === state.efFamily)) state.efFamily = E.models[0].model;
    $("#efFamily").innerHTML = E.models.filter((f) => f.efforts.length > 1).map((f) => `<button type="button" role="tab" aria-selected="${state.efFamily === f.model}" class="${state.efFamily === f.model ? "on" : ""}" data-f="${f.model}">${esc(f.name)}</button>`).join("");
    const fam = E.models.find((f) => f.model === state.efFamily);
    const usage = (state.community.effortUsage || []).filter((u) => u.model === fam.model);
    const totalCalls = usage.reduce((a, u) => a + (u.calls || 0), 0);
    const minCost = Math.min(...fam.efforts.filter((e) => e.costPerTask).map((e) => e.costPerTask));
    const bestValue = fam.efforts.reduce((b, e) => (e.costPerTask && (!b || e.intelligence / e.costPerTask > b.intelligence / b.costPerTask) ? e : b), null);
    $("#efTable thead").innerHTML = `<tr><th>${t("ef.col.effort")}</th><th class="num">${t("col.iq")}</th><th class="num">${t("ef.col.cost")}</th><th class="num">${t("ef.col.aaSpeed")}</th>
      <th class="num">${t("ef.col.realSpeed")}</th><th class="num">${t("ef.col.perCall")}</th><th class="num">${t("ef.col.reason")}</th><th class="num">${t("ef.col.share")}</th></tr>`;
    $("#efTable tbody").innerHTML = fam.efforts.map((e, i) => {
      const prev = fam.efforts[i - 1];
      const d = prev ? e.intelligence - prev.intelligence : null;
      const u = usage.find((x) => x.effort === e.effort);
      const na = `<span class="muted">—</span>`;
      return `<tr class="${e === bestValue ? "best" : ""}">
        <td><strong>${esc(e.effort)}</strong>${e === bestValue ? ` <span class="badge official">${t("ef.bestValue")}</span>` : ""}</td>
        <td class="num">${e.intelligence}${d != null ? `<small class="${d > 0 ? "up" : d < 0 ? "down" : ""}">${d > 0 ? "+" : ""}${d}</small>` : ""}</td>
        <td class="num">${e.costPerTask ? money(e.costPerTask, 2) + `<small>×${(e.costPerTask / minCost).toFixed(1)}</small>` : na}</td>
        <td class="num">${e.speed ?? na}</td>
        <td class="num">${u ? u.tps + `<small>n=${u.n}</small>` : na}</td>
        <td class="num">${u ? u.perCall.toLocaleString("en-US") : na}</td>
        <td class="num">${u && u.reasoningShare != null ? Math.round(u.reasoningShare * 100) + "%" : na}</td>
        <td class="num">${u && totalCalls ? Math.round((u.calls / totalCalls) * 100) + "%" : na}</td>
      </tr>`;
    }).join("");
    $("#efNote").innerHTML = `${t("ef.note")} <a href="${esc(E.source.url)}" target="_blank" rel="noopener">${esc(E.source.name)}</a>, ${t("plan.checked")} ${esc(E.source.checked)}.${state.community.sample ? " " + t("ef.sampleNote") : ""}${!usage.length ? " " + t("ef.noUsage") : ""}`;
  }

  function initEffort() {
    $("#efPick").addEventListener("click", (e) => {
      const b = e.target.closest("button[data-m]"); if (!b) return;
      const i = state.efPick.indexOf(b.dataset.m);
      if (i >= 0) state.efPick.splice(i, 1); else state.efPick.push(b.dataset.m);
      renderEffort();
    });
    $("#efFamily").addEventListener("click", (e) => { const b = e.target.closest("button[data-f]"); if (!b) return; state.efFamily = b.dataset.f; renderEffort(); });
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
    const s2 = esc(t("empty.s2")).replace("quotapilot share", "<code>quotapilot share</code>");
    $("#comInvite").innerHTML = `
      <h3>${esc(t("empty.title").replace("{n}", n))}</h3>
      <p>${esc(t("empty.sub").replace("{n}", n).replace("{d}", c.windowDays || 7))}</p>
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
      <td class="num" ${dl("com.mixCache")}>${Math.round(r.cacheHit * 100)}%<small>${t("com.mixWrite").replace("{p}", Math.round(r.cacheWriteShare * 100))}</small></td></tr>`).join("")}</tbody></table>` : emptyNote();

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

  function renderReportForm() {
    $("#repType").innerHTML = REP_TYPES.map((k) => `<button type="button" role="tab" aria-selected="${state.repType === k}" class="${state.repType === k ? "on" : ""}" data-type="${k}">${t("rep.type." + k)}</button>`).join("");
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
  }

  function buildReport() {
    const v = (id) => $(id) && $(id).value;
    const n = (id) => parseFloat(v(id));
    const now = new Date().toISOString();
    switch (state.repType) {
      case "speed": {
        const r = { type: "speed", model: v("#rSpModel"), client: v("#rSpClient") || undefined, via: "site", outputTokens: n("#rSpTokens"), seconds: n("#rSpSecs"), date: now };
        if (!(r.outputTokens >= 50) || !(r.seconds >= 0.2)) return { error: t("rep.err.speed") };
        return { r, title: `Speed: ${modelName(r.model)} ${(r.outputTokens / r.seconds).toFixed(1)} tok/s` };
      }
      case "rating": {
        const r = { type: "rating", model: v("#rRaModel"), score: n("#rRaScore"), degraded: $("#rRaDeg").checked, task: v("#rRaTask"), date: now };
        return { r, title: `Rating: ${modelName(r.model)} ${r.score}/10${r.degraded ? " (feels worse)" : ""}` };
      }
      case "quota": {
        const [provider, plan] = v("#rQuPlan").split("|");
        const r = { type: "quota", provider, plan, model: v("#rQuModel"), window: v("#rQuWindow"), percentUsed: n("#rQuPct"), tokensUsed: n("#rQuTok"), date: now };
        if (!(r.percentUsed >= 0.5 && r.percentUsed <= 100) || !(r.tokensUsed >= 1000)) return { error: t("rep.err.quota") };
        return { r, title: `Quota: ${provider} ${plan} ${r.window} ≈ ${fmtTokens(r.tokensUsed / (r.percentUsed / 100))} tokens` };
      }
      default: {
        const [provider, plan] = v("#rEvPlan").split("|");
        const when = new Date(v("#rEvWhen"));
        if (isNaN(when)) return { error: t("rep.err.when") };
        const r = { type: "event", provider, plan, kind: v("#rEvKind"), date: when.toISOString() };
        return { r, title: `Limit event: ${provider} ${plan} ${r.kind}` };
      }
    }
  }

  function onReportSubmit(e) {
    e.preventDefault();
    const res = buildReport();
    $("#repErr").textContent = res.error || "";
    if (res.error) return;
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
    if (state.efforts) seen.set(state.efforts.source.url, { label: state.efforts.source.name + " — " + state.efforts.source.covers, checked: state.efforts.source.checked });
    state.resets.trackers.forEach((tr) => { if (!seen.has(tr.url)) seen.set(tr.url, { label: tr.name + " (reset ledger cross-check)", checked: state.resets.lastReviewed }); });
    state.changes.changes.forEach((c) => { if (!seen.has(c.source)) seen.set(c.source, { label: providerById(c.provider).name + " change log", checked: state.changes.lastReviewed }); });
    $("#sourceList").innerHTML = [...seen.entries()].map(([url, s]) =>
      `<li><a href="${esc(url)}" target="_blank" rel="noopener">${esc(host(url))}</a> <span>${esc(s.label)}</span> <span class="when">${t("plan.checked")} ${esc(s.checked)}</span></li>`).join("");
  }

  function renderAll() {
    applyStatic();
    $("#reviewed").textContent = reviewedMax();
    $("#footReviewed").textContent = reviewedMax();
    renderPlans();
    renderChanges();
    renderResets();
    renderCalc();
    renderRadar();
    renderEffort();
    renderCommunity();
    renderLive();
    renderReportForm();
    renderPartners();
    renderSources();
    applySponsor();
  }

  function startAutoRefresh(demo) {
    if (window.__AQW_DATA) return;
    // Refreshes bypass the HTTP cache so a new community.json shows up within a minute.
    const get = (f) => fetch(f, { cache: "no-cache" }).then((r) => { if (!r.ok) throw new Error(f + " " + r.status); return r.json(); });
    setInterval(async () => {
      if (document.hidden) return;
      try {
        const [community, resets, changes] = await Promise.all([get(demo ? "data/community.sample.json" : "data/community.json"), get("data/resets.json"), get("data/changes.json")]);
        Object.assign(state, { community, resets, changes, loadedAt: new Date() });
        renderResets(); renderCommunity(); renderEffort(); renderLive();
      } catch (e) { /* keep showing the last good data */ }
    }, 60000);
  }

  // The visitor counter (hit.js + collector /v1/visits) is kept for a future /stats page; the home page never shows it.

  async function load() {
    initLang();
    applyStatic();
    applySponsor();
    applyInstall();
    initCopyButtons();
    const get = (f) => fetch(f).then((r) => { if (!r.ok) throw new Error(f + " " + r.status); return r.json(); });
    const demo = new URLSearchParams(location.search).get("demo") === "1" || window.__AQW_DEMO === true;
    try {
      [state.plans, state.models, state.changes, state.community, state.resets, state.efforts] = await Promise.all([get("data/plans.json"), get("data/models.json"), get("data/changes.json"), get(demo ? "data/community.sample.json" : "data/community.json"), get("data/resets.json"), get("data/efforts.json")]);
    } catch (e) {
      document.querySelector("main").insertAdjacentHTML("afterbegin", `<p class="error">Could not load data (${esc(e.message)}). Serve the folder over HTTP, e.g. <code>python3 -m http.server</code>.</p>`);
      return;
    }
    initCalc();
    initRadar();
    initCommunity();
    initResets();
    initEffort();
    renderAll();
    // The browser jumps to #anchor before the data has rendered, when the target is still near the top.
    // Jump again once the page has its real height; scroll-margin-top keeps the heading clear of the top bar.
    const target = location.hash.length > 1 && document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (target) requestAnimationFrame(() => target.scrollIntoView({ block: "start" }));
    startAutoRefresh(demo);
  }

  load();
})();
