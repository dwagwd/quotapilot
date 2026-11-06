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

  window.AQW_STATE = {
    publishedCount: publishedCount,
    eventTotal: eventTotal,
    fmtUtc: fmtUtc,
    isStale: isStale,
    statMeta: statMeta,
    safeHttps: safeHttps,
    sponsorHref: sponsorHref,
    joinCommands: joinCommands
  };
})(window);
