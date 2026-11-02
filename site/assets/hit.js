// Counts one visit per browser session for the 7-day visitor stats. No cookies; the collector keeps
// only daily totals and a hashed visitor key that expires after two days.
(function () {
  var base = "https://aiquotawatch.pages.dev/api";
  try {
    if (sessionStorage.getItem("aqw-hit")) return;
    sessionStorage.setItem("aqw-hit", "1");
  } catch (e) { /* storage blocked: count anyway */ }
  try { fetch(base + "/v1/hit", { method: "POST", keepalive: true }).catch(function () {}); } catch (e) { /* ignore */ }
})();
