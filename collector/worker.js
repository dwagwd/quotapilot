// AI Quota Watch anonymous collector (Cloudflare Worker).
// POST /v1/report  {install, reports[]}  -> stores sanitized reports under an anonymous reporter id.
// GET  /v1/export  (Bearer EXPORT_TOKEN) -> every stored report, for the GitHub Action that builds the stats.
// No IP address, GitHub account or install id is stored: the reporter id is HMAC(SALT, install id), and
// rate limits use HMAC(SALT, ip + day) counters that expire after a day.

const FIELDS = {
  type: "string", model: "string", provider: "string", plan: "string", window: "string", kind: "string", effort: "string",
  client: "string", task: "string", via: "string", date: "string",
  outputTokens: "number", reasoningTokens: "number", seconds: "number", calls: "number", score: "number",
  percentUsed: "number", tokensUsed: "number", inputShare: "number", degraded: "boolean"
};
const TYPES = ["speed", "rating", "quota", "event"];
export const LIMITS = { bodyBytes: 20000, reports: 30, perInstallPerDay: 3, perIpPerDay: 20, keepDays: 35 };
const ALLOWED_ORIGINS = ["https://aiquotawatch.pages.dev", "https://dwagwd.github.io", "http://127.0.0.1:8765", "http://localhost:8765"];

export function sanitize(report) {
  if (!report || typeof report !== "object" || Array.isArray(report)) return null;
  const out = {};
  for (const [key, kind] of Object.entries(FIELDS)) {
    const v = report[key];
    if (typeof v !== kind) continue;
    if (kind === "number" && !Number.isFinite(v)) continue;
    out[key] = kind === "string" ? v.replace(/[\u0000-\u001f\u007f<>"'`]/g, "").slice(0, 60) : v;
  }
  return TYPES.includes(out.type) ? out : null;
}

async function hmac(secret, text) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function cors(request) {
  const origin = request.headers.get("Origin");
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    Object.assign(headers, { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type", "Vary": "Origin" });
  }
  return headers;
}
const json = (request, status, body) => new Response(JSON.stringify(body), { status, headers: cors(request) });

async function bump(kv, key, limit) {
  const n = Number(await kv.get(key)) || 0;
  if (n >= limit) return false;
  await kv.put(key, String(n + 1), { expirationTtl: 86400 });
  return true;
}

async function report(request, env) {
  const length = Number(request.headers.get("Content-Length") || 0);
  if (length > LIMITS.bodyBytes) return json(request, 413, { error: "too large" });
  const text = await request.text();
  if (text.length > LIMITS.bodyBytes) return json(request, 413, { error: "too large" });
  let body;
  try { body = JSON.parse(text); } catch { return json(request, 400, { error: "invalid JSON" }); }
  const install = typeof body?.install === "string" && /^[A-Za-z0-9-]{16,64}$/.test(body.install) ? body.install : null;
  if (!install) return json(request, 400, { error: "missing install id" });
  const reports = (Array.isArray(body.reports) ? body.reports : []).slice(0, LIMITS.reports).map(sanitize).filter(Boolean);
  if (!reports.length) return json(request, 400, { error: "no valid reports" });

  const day = new Date().toISOString().slice(0, 10);
  const reporter = "anon-" + (await hmac(env.SALT, "install:" + install)).slice(0, 16);
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const ipKey = "rl:ip:" + (await hmac(env.SALT, "ip:" + ip + ":" + day)).slice(0, 32);
  const installKey = "rl:in:" + day + ":" + reporter;
  if (!(await bump(env.REPORTS, ipKey, LIMITS.perIpPerDay)) || !(await bump(env.REPORTS, installKey, LIMITS.perInstallPerDay))) {
    return json(request, 429, { error: "daily limit reached" });
  }
  const now = new Date().toISOString();
  const stored = reports.map((r) => ({ ...r, date: typeof r.date === "string" && !isNaN(Date.parse(r.date)) ? r.date : now, reporter }));
  await env.REPORTS.put("r:" + day + ":" + crypto.randomUUID(), JSON.stringify(stored), { expirationTtl: LIMITS.keepDays * 86400 });
  return json(request, 200, { ok: true, accepted: stored.length });
}

async function exportAll(request, env) {
  const auth = request.headers.get("Authorization") || "";
  if (!env.EXPORT_TOKEN || auth !== "Bearer " + env.EXPORT_TOKEN) return json(request, 401, { error: "unauthorized" });
  const out = [];
  let cursor;
  do {
    const page = await env.REPORTS.list({ prefix: "r:", cursor, limit: 1000 });
    for (const k of page.keys) {
      const v = await env.REPORTS.get(k.name);
      if (v) out.push(...JSON.parse(v));
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor && out.length < 50000);
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Served both as a Worker (/v1/...) and as a Pages Function under the site (/api/v1/...).
    url.pathname = url.pathname.replace(/^\/api(?=\/)/, "");
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(request) });
    if (url.pathname === "/v1/report" && request.method === "POST") return report(request, env);
    if (url.pathname === "/v1/export" && request.method === "GET") return exportAll(request, env);
    if (url.pathname === "/" || url.pathname === "/api") return json(request, 200, { service: "AI Quota Watch collector", docs: "https://github.com/dwagwd/quotapilot/tree/main/collector" });
    return json(request, 404, { error: "not found" });
  }
};
