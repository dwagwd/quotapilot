import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const run = (file) => { const w = {}; new Function("window", read("../assets/" + file))(w); return w; };
const cfg = run("config.js").SITE_CONFIG;
const S = run("community-state.js").AQW_STATE;
const html = read("../index.html");

test("sponsor url is empty or https, and the page would use it as-is", () => {
  assert.equal(typeof cfg.sponsor, "object");
  const url = cfg.sponsor.url;
  assert.ok(url === "" || url.startsWith("https://"), url);
  if (url) assert.equal(S.sponsorHref(cfg), new URL(url).href);
  assert.equal(typeof cfg.sponsor.label, "string");
});

test("ads have no placeholder switch and are off unless explicitly enabled", () => {
  assert.equal("showPlaceholders" in cfg.ads, false);
  assert.equal(typeof cfg.ads.enabled, "boolean");
});

test("install box commands come from config and match the static fallback in index.html", () => {
  const cmds = cfg.install.commands;
  assert.ok(Array.isArray(cmds) && cmds.length >= 1);
  for (const c of cmds) assert.match(c, /^brew /);
  const pre = html.match(/<pre id="installCmd"[^>]*><code>([\s\S]*?)<\/code><\/pre>/);
  assert.ok(pre, "installCmd block present");
  assert.equal(pre[1].trim(), cmds.join("\n"));
  for (const k of ["notesUrl", "sourceUrl"]) assert.ok(S.safeHttps(cfg.install[k]), k);
});

test("direct download links point at this repo's GitHub releases", () => {
  const links = [...html.matchAll(/href="([^"]+)"[^>]*data-dl/g)].map((m) => m[1]);
  assert.equal(links.length, 4);
  for (const l of links) assert.match(l, /^https:\/\/github\.com\/dwagwd\/quotapilot\/releases\/latest\/download\/quotapilot-(linux|windows)-(x64|arm64)\.(tar\.gz|zip)$/);
});

test("affiliate links stay empty or https", () => {
  for (const [k, v] of Object.entries(cfg.affiliates)) assert.ok(v === "" || v.startsWith("https://"), k);
});
