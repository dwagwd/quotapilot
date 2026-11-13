// Pure helpers shared by app.js and the tests (no DOM access). Loaded before app.js.
// Tests load this file with new Function("window", src)(fakeWindow).
(function (window) {
  "use strict";
  var HOUR = 36e5;

  // Number of community rows that passed the "3 different people" threshold. 0 = show the invite card.
  function publishedCount(c) {
    if (!c) return 0;
    var len = function (a) { return Array.isArray(a) ? a.length : 0; };
    return len(c.speed) + len(c.ratings) + len(c.quota) + len(c.tokenMix);
  }

  // Total limit/reset events across providers (the events card has its own empty state).
  function eventTotal(c) {
    var by = c && c.events && c.events.byHourUtc;
    if (!by) return 0;
    return Object.keys(by).reduce(function (sum, k) {
      return sum + (Array.isArray(by[k]) ? by[k].reduce(function (a, b) { return a + (Number(b) || 0); }, 0) : 0);
    }, 0);
  }

  // "2026-11-05T19:55:12Z" -> "2026-11-05 19:55" (UTC). Invalid input -> "".
  function fmtUtc(iso) {
    var d = new Date(iso);
    if (!iso || isNaN(d)) return "";
    return d.toISOString().slice(0, 16).replace("T", " ");
  }

  // Compiled more than `hours` (default 48) ago, or no valid date at all.
  function isStale(generated, now, hours) {
    var d = new Date(generated);
    if (!generated || isNaN(d)) return true;
    var ref = now ? new Date(now) : new Date();
    return ref - d > (hours || 48) * HOUR;
  }

  // Card footer text. o = { n, days, generated, now, perRow }.
  // n = distinct people for the whole card (only when the aggregator provides it). Without it, perRow
  // says that the n next to each row counts people. t = translate function (key -> string).
  function statMeta(o, t) {
    var parts = [];
    if (o.n != null) parts.push(t("stat.people").replace("{n}", o.n));
    else if (o.perRow) parts.push(t("stat.nNote"));
    parts.push(t("stat.window").replace("{d}", o.days));
    var date = fmtUtc(o.generated);
    var compiled = t("stat.compiled").replace("{date}", date || "—");
    var stale = isStale(o.generated, o.now);
    return { parts: parts, compiled: compiled, stale: stale, text: parts.concat([compiled]).join(" · ") };
  }

  // How far the community is from its first published row: people sharing now and how many more are needed.
  // `need` people must report the same model or plan, so this is the best case, not a promise.
  function inviteProgress(c, need) {
    var have = Math.max(0, Math.floor(Number(c && c.totals && c.totals.reporters) || 0));
    var n = Math.max(1, Math.floor(Number(need) || 3));
    return { have: have, need: n, missing: Math.max(0, n - have) };
  }

  // Only https:// links from config are used; anything else hides the sponsor elements.
  function safeHttps(url) {
    if (typeof url !== "string" || !url.trim()) return "";
    try {
      var u = new URL(url.trim());
      return u.protocol === "https:" ? u.href : "";
    } catch (e) { return ""; }
  }
  function sponsorHref(cfg) {
    return safeHttps(cfg && cfg.sponsor && cfg.sponsor.url);
  }

  // Multi-line commands -> one line joined with " && ", so a paste never runs line 1 before the user reads line 2.
  function joinCommands(text) {
    return String(text || "").split(/\r?\n/).map(function (l) { return l.trim(); }).filter(Boolean).join(" && ");
  }

  // Both a root-hosted site and a project under /repo/ load data relative to app.js.
  async function readDataset(file, options) {
    if (options.embedded) {
      if (!Object.prototype.hasOwnProperty.call(options.embedded, file)) throw new Error("Missing embedded dataset: " + file);
      return options.embedded[file];
    }
    var fetcher = options.fetcher; // Native browser fetch must be called without an options-object receiver.
    var response = await fetcher(new URL(file, options.base).href, options.refresh ? { cache: "no-cache" } : undefined);
    if (!response.ok) throw new Error(file + " " + response.status);
    return response.json();
  }

  window.AQW_STATE = {
    readDataset: readDataset,
    publishedCount: publishedCount,
    inviteProgress: inviteProgress,
    eventTotal: eventTotal,
    fmtUtc: fmtUtc,
    isStale: isStale,
    statMeta: statMeta,
    safeHttps: safeHttps,
    sponsorHref: sponsorHref,
    joinCommands: joinCommands
  };
})(window);
