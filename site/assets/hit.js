// Counts one visit per browser session for the 7-day visitor stats. No cookies; the collector stores one key
// per visit with a hashed, daily-salted visitor id that expires after 8 days, and keeps only daily totals
// (views, visitors) after that, for up to 400 days.
(function () {
  var base = "https://aiquotawatch.pages.dev/api";
  // Only the published site counts. Local previews, test builds and automated browsers would inflate the stats.
  var h = location.hostname;
  if (h !== "aiquotawatch.pages.dev" && h !== "dwagwd.github.io") return;
  if (navigator.webdriver) return;
  try {
    if (sessionStorage.getItem("aqw-hit")) return;
    sessionStorage.setItem("aqw-hit", "1");
  } catch (e) { /* storage blocked: count anyway */ }
  try { fetch(base + "/v1/hit", { method: "POST", keepalive: true }).catch(function () {}); } catch (e) { /* ignore */ }
})();
