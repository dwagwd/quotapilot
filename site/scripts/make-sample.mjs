// Builds data/community.sample.json from generated reports so the community
// section can be previewed with ?demo=1. These are NOT real measurements.
import { readFileSync, writeFileSync } from "node:fs";
import { aggregate } from "./aggregate.mjs";

const root = new URL("..", import.meta.url);
const models = JSON.parse(readFileSync(new URL("data/models.json", root))).models;
const now = new Date("2026-11-02T12:00:00Z");
let seed = 42;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const jitter = (v, pct) => v * (1 + (rnd() * 2 - 1) * pct);
const when = (days) => new Date(now.getTime() - rnd() * days * 864e5).toISOString();
const raw = [];
const rated = ["claude-opus-5-5", "gpt-6-1-sol", "gemini-4-carbon", "claude-sonnet-5-5", "gpt-6-astra", "grok-4-7"];
rated.forEach((id, k) => {
  const m = models.find((x) => x.id === id);
  for (let i = 0; i < 6 + k; i++) {
    raw.push({ type: "speed", model: id, outputTokens: 1500, seconds: 1500 / jitter(m.speed * 0.7, 0.25), client: ["CLI", "Desktop", "API"][i % 3], date: when(7), reporter: `demo${i}` });
    raw.push({ type: "rating", model: id, score: Math.round(jitter(m.intelligence / 7, 0.15)), degraded: id === "gpt-6-astra" ? i % 2 === 0 : i === 0, date: when(7), reporter: `demo${i}` });
  }
});
const efforts = JSON.parse(readFileSync(new URL("data/efforts.json", root))).models;
const perCallBase = { low: 250, medium: 420, high: 650, xhigh: 980, max: 1500 };
const reasonBase = { low: 0.2, medium: 0.4, high: 0.55, xhigh: 0.68, max: 0.78 };
for (const fam of efforts.filter((f) => ["claude-opus-5-5", "gpt-6-1-sol", "gpt-6-astra", "claude-sonnet-5-5"].includes(f.model))) {
  for (const e of fam.efforts) {
    for (let i = 0; i < 4; i++) {
      const calls = 40 + Math.round(rnd() * 200), per = jitter(perCallBase[e.effort], 0.2), tps = jitter((e.speed || 80) * 0.75, 0.2);
      const out = Math.round(per * calls), prompt = out * jitter(40, 0.4), hit = Math.min(0.97, jitter(0.88, 0.06)), write = 0.04;
      raw.push({ type: "speed", model: fam.model, effort: e.effort, calls, outputTokens: out, reasoningTokens: Math.round(per * calls * jitter(reasonBase[e.effort], 0.1)), seconds: per * calls / tps, client: "Codex", date: when(7), reporter: `eff${i}`,
        inputTokens: Math.round(prompt * (1 - hit - write)), cacheReadTokens: Math.round(prompt * hit), cacheWriteTokens: Math.round(prompt * write) });
    }
  }
}
const quotas = [["claude-opus-5-5", "Max", "5h", 3e6], ["claude-opus-5-5", "Pro", "5h", 6e5], ["gpt-6-1-sol", "Plus", "5h", 9e5], ["gpt-6-1-sol", "Pro (200)", "weekly", 2.4e8], ["gemini-4-argon", "AI Pro", "5h", 1.2e6]];
quotas.forEach(([model, plan, window, full]) => {
  for (let i = 0; i < 4; i++) { const pct = 5 + rnd() * 20; raw.push({ type: "quota", model, plan, window, percentUsed: pct, tokensUsed: jitter(full, 0.2) * pct / 100, date: when(7), reporter: `demo${i}` }); }
});
for (let i = 0; i < 40; i++) {
  const provider = ["claude", "chatgpt", "gemini", "grok"][i % 4];
  const h = Math.floor(Math.abs(Math.sin(i * 1.7)) * 24) % 24;
  const d = new Date(now.getTime() - (1 + (i % 25)) * 864e5); d.setUTCHours(h);
  raw.push({ type: "event", provider, model: null, kind: i % 3 ? "hit_limit" : "reset", plan: "", date: d.toISOString(), reporter: `demo${i}` });
}
const out = { sample: true, ...aggregate(raw, models, now) };
writeFileSync(new URL("data/community.sample.json", root), JSON.stringify(out, null, 2) + "\n");
console.log("wrote data/community.sample.json (example data, not real)");
