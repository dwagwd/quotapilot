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
  // Cloudflare Web Analytics: cookie-free page view counts (and where visitors came from), on the published site only.
  // Empty token = off. The token is public by design: it is part of every page that uses the beacon.
  var cfToken = "6e04347cf4754bf197f44a3d9d73da64";
  if (cfToken && !document.querySelector("script[data-cf-beacon]")) {
    var s = document.createElement("script");
    s.defer = true;
    s.src = "https://static.cloudflareinsights.com/beacon.min.js";
    s.setAttribute("data-cf-beacon", JSON.stringify({ token: cfToken }));
    document.body.appendChild(s);
  }
})();
