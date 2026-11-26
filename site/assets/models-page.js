// Interactive part of /models/: filters, sortable columns and the calculators. The page works without it (the table is static HTML);
// this adds behaviour on top, using the same functions that built the table (assets/models-core.js). Nothing is sent anywhere:
// the data files are read from this site, and what you type or paste stays in this page (and, if the browser allows, in its local storage).
(function () {
  "use strict";
  var M = window.AQW_MODELS;
  var body = document.getElementById("rankBody");
  if (!M || !body) return;
  var lang = /^zh/i.test(document.documentElement.lang) ? "zh" : "en";
  var t = M.T(lang);
  var locale = (navigator.language || (lang === "zh" ? "zh-TW" : "en-US"));
  var $ = function (id) { return document.getElementById(id); };
  var KEY = "aqw-models-inputs";

  var scriptUrl = document.currentScript && document.currentScript.src;
  var dataBase = scriptUrl ? new URL("../data/", scriptUrl).href : "data/";
  function get(name) {
    return fetch(dataBase + name, { cache: "no-cache" }).then(function (r) { if (!r.ok) throw new Error(name); return r.json(); });
  }

  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { saved = {}; }
  function persist() {
    var keep = {};
    ["inTok", "outTok", "cachedPct", "cur", "rate", "kwh", "watts", "hoursDay", "elSpeed"].forEach(function (id) { keep[id] = $(id).value; });
    try { localStorage.setItem(KEY, JSON.stringify(keep)); } catch (e) { /* storage may be unavailable: the page works without it */ }
  }
  var number = function (id) {
    var raw = String($(id).value || "").trim().replace(",", ".");
    if (raw === "") return null;
    var n = Number(raw);
    return isFinite(n) && n >= 0 ? n : null;
  };
  function currency() {
    var c = String($("cur").value || "").trim().toUpperCase();
    return /^[A-Z]{3}$/.test(c) ? c : "USD";
  }

  var state = { sort: null, dir: "asc", rows: [], cloud: [] };

  function filters() {
    var budget = number("fBudget");
    return { type: $("fType").value, provider: $("fProvider").value, chip: $("fChip").value, mem: $("fMem").value, maxBlended: budget };
  }
  function elecText(row) {
    if (row.kind !== "local") return null;
    var price = number("kwh");
    var v = M.electricityPerMillionOutput(row, number("watts") || 0, price == null ? NaN : price);
    return v == null ? null : M.money(v, currency(), locale);
  }
  function viewFor() {
    return { elecValue: function (r) { var price = number("kwh"); return r.kind === "local" && price != null ? M.electricityPerMillionOutput(r, number("watts") || 0, price) : null; } };
  }

  function visibleRows() {
    var list = M.filterRows(state.rows, filters());
    return state.sort ? M.sortRows(list, state.sort, state.dir, viewFor()) : M.defaultOrder(list);
  }

  function renderTable() {
    var list = visibleRows();
    body.innerHTML = list.map(function (r) { return M.rowHtml(r, lang, { elec: elecText(r) }); }).join("");
    $("rowCount").textContent = M.fill(t.showing, { n: list.length, m: state.rows.length });
    document.querySelectorAll("#rankTable th[data-col]").forEach(function (th) {
      var on = th.getAttribute("data-col") === state.sort;
      th.setAttribute("aria-sort", on ? (state.dir === "asc" ? "ascending" : "descending") : "none");
      th.classList.toggle("sorted", on);
      if (on) th.setAttribute("data-dir", state.dir); else th.removeAttribute("data-dir");
    });
  }

  function usage() {
    var cached = number("cachedPct");
    return { inputM: number("inTok") || 0, outputM: number("outTok") || 0, cachedShare: Math.min(Math.max((cached || 0) / 100, 0), 1) };
  }
  function renderCalc() {
    var u = usage(), cur = currency(), res = $("resBody"), note = [];
    if (!(u.inputM + u.outputM > 0)) { res.innerHTML = ""; $("resNote").textContent = ""; return; }
    var priced = M.priceRows(M.filterRows(state.rows, filters()), u, { currency: cur, rate: number("rate") || 0, watts: number("watts") || 0, price: number("kwh") || 0 });
    res.innerHTML = priced.map(function (p) {
      var cost = p.cost == null ? "<span class=\"muted\">" + M.esc(p.needsPrice ? t.resNoElec.split(".")[0] : t.none) + "</span>" : M.esc(M.money(p.cost, p.currency, locale));
      var speed = p.row.speed ? (p.row.speed.prelim ? "≈" + Math.round(p.row.speed.value) : p.row.speed.value) : t.none;
      var time = p.seconds == null ? t.none : M.fill(t.hoursUnit, { v: (p.seconds / 3600).toFixed(p.seconds < 36000 ? 1 : 0) });
      return "<tr><td><strong>" + M.esc(p.row.name) + "</strong><div class=\"note\">" + M.esc(p.row.kind === "cloud" ? (M.PROVIDERS[p.row.provider] || p.row.provider) : (M.ENGINES[p.row.engine] || p.row.engine) + " · " + p.row.chip) + "</div></td><td class=\"num\">" + cost + "</td><td class=\"num\">" + M.esc(String(speed)) + "</td><td class=\"num\">" + M.esc(time) + "</td></tr>";
    }).join("");
    if (priced.some(function (p) { return p.usdFallback; })) note.push(t.resNoRate);
    if (priced.some(function (p) { return p.needsPrice; })) note.push(t.resNoElec);
    if (priced.some(function (p) { return p.row.kind === "local"; })) note.push(t.resOutputOnly);
    $("resNote").textContent = note.join(" ");
  }

  function renderElec() {
    var out = $("elOut"), cur = currency();
    var scenario = M.electricityScenario({ watts: number("watts"), hoursPerDay: number("hoursDay"), price: number("kwh"), tokensPerSecond: number("elSpeed") });
    if (!scenario) { out.innerHTML = "<dt></dt><dd>" + M.esc(t.elecNeed) + "</dd>"; return; }
    var rows = [[t.elecKwh, scenario.kwh.toFixed(1) + " kWh"], [t.elecMonth, M.money(scenario.cost, cur, locale)]];
    if (scenario.tokens) {
      rows.push([t.elecTokens, (scenario.tokens / 1e6).toFixed(scenario.tokens / 1e6 < 10 ? 2 : 0) + "M"]);
      rows.push([t.elecPerM, M.money(scenario.perMillion, cur, locale)]);
      var model = state.cloud.filter(function (r) { return r.id === $("elCompare").value; })[0];
      var rate = cur === "USD" ? 1 : (number("rate") || 0);
      if (model && model.output != null) {
        var cloudOut = model.output * (rate > 0 ? rate : 1), shown = rate > 0 ? cur : "USD";
        rows.push([M.fill(t.elecCloudPerM, { name: model.name }), M.money(cloudOut, shown, locale)]);
        if (rate > 0 && scenario.perMillion > 0 && cloudOut > 0) {
          var ratio = cloudOut / scenario.perMillion, less = ratio >= 1, x = less ? ratio : 1 / ratio;
          rows.push(["", M.fill(t.elecVerdict, { x: x.toFixed(x < 10 ? 1 : 0), dir: less ? t.dirLess : t.dirMore })]);
        }
      }
    }
    out.innerHTML = rows.map(function (r) { return "<dt>" + M.esc(r[0]) + "</dt><dd>" + M.esc(r[1]) + "</dd>"; }).join("");
  }

  function renderAll() { renderTable(); renderCalc(); renderElec(); }

  function init(models, community) {
    state.rows = M.cloudRows(models, community).concat(M.localRows(community));
    state.cloud = state.rows.filter(function (r) { return r.kind === "cloud"; });
    var chips = [], mems = [];
    state.rows.forEach(function (r) {
      if (r.kind !== "local") return;
      if (chips.indexOf(r.chip) < 0) chips.push(r.chip);
      if (mems.indexOf(r.memGB) < 0) mems.push(r.memGB);
    });
    chips.sort(); mems.sort(function (a, b) { return a - b; });
    var any = function (sel, values, label) { sel.insertAdjacentHTML("beforeend", values.map(function (v) { return "<option value=\"" + M.esc(v) + "\">" + M.esc(label(v)) + "</option>"; }).join("")); };
    any($("fChip"), chips, String); any($("fMem"), mems, function (v) { return v + " GB"; });
    // Inputs: what was typed here before, else defaults from the browser's region.
    $("cur").value = saved.cur || M.currencyForLocale(locale);
    ["inTok", "outTok", "cachedPct", "rate", "kwh", "watts", "hoursDay", "elSpeed"].forEach(function (id) { if (saved[id] != null) $(id).value = saved[id]; });
    $("elCompare").value = (state.cloud.filter(function (r) { return r.output != null; })[0] || {}).id || "";
    ["modelsTools", "calc", "elec"].forEach(function (id) { $(id).hidden = false; });

    ["fType", "fProvider", "fBudget", "fChip", "fMem"].forEach(function (id) { $(id).addEventListener("input", renderAll); });
    ["inTok", "outTok", "cachedPct", "cur", "rate", "kwh", "watts", "hoursDay", "elSpeed", "elCompare"].forEach(function (id) {
      $(id).addEventListener("input", function () { persist(); renderAll(); });
    });
    $("fReset").addEventListener("click", function () {
      $("fType").value = "all"; $("fProvider").value = "all"; $("fChip").value = "all"; $("fMem").value = "all"; $("fBudget").value = "";
      state.sort = null; renderAll();
    });
    document.querySelectorAll("#rankTable .sort-btn").forEach(function (button) {
      button.addEventListener("click", function () {
        var key = button.getAttribute("data-sort");
        if (state.sort === key) state.dir = state.dir === "asc" ? "desc" : "asc";
        else { state.sort = key; state.dir = key === "name" || key === "provider" || key === "type" || key === "input" || key === "output" || key === "cache" || key === "blended" || key === "elec" ? "asc" : "desc"; }
        renderTable();
      });
    });
    $("pasteBtn").addEventListener("click", function () {
      var parsed = M.parseStats($("pasteBox").value);
      if (!parsed) { $("pasteMsg").textContent = t.pasteBad; return; }
      var round = function (v) { return v >= 10 ? String(Math.round(v)) : String(Math.round(v * 100) / 100); };
      $("inTok").value = round(parsed.inputM); $("outTok").value = round(parsed.outputM); $("cachedPct").value = String(Math.round(parsed.cachedShare * 100));
      $("pasteMsg").textContent = M.fill(t.pasteOk, { hours: Math.round(parsed.hours), inM: round(parsed.inputM), outM: round(parsed.outputM) });
      persist(); renderAll();
    });
    // A local row's speed is a sensible default for the electricity calculator.
    var firstLocal = state.rows.filter(function (r) { return r.kind === "local" && r.speed; })[0];
    if (!$("elSpeed").value && firstLocal) $("elSpeed").value = String(Math.round(firstLocal.speed.value));
    renderAll();
  }

  Promise.all([get("models.json"), get("community.json")]).then(function (data) { init(data[0], data[1]); }).catch(function () {
    // Data files not reachable: the static table stays as it is, without filters and calculators.
  });
})();
