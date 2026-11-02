// Checks that every number on the site carries a source and a date.
// Run: node scripts/validate-data.mjs
import { readFileSync } from "node:fs";
const load = (f) => JSON.parse(readFileSync(new URL("../data/" + f, import.meta.url)));
const plans = load("plans.json"), models = load("models.json"), changes = load("changes.json"), resets = load("resets.json"), efforts = load("efforts.json");
const errors = [];
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || "");
const isUrl = (u) => /^https:\/\//.test(u || "");
const providers = new Set(plans.providers.map((p) => p.id));

for (const p of plans.providers) for (const pl of [...p.plans, ...(p.subproducts || []).flatMap((s) => s.plans)]) {
  const id = `${p.id}/${pl.name}`;
  if (!isUrl(pl.source)) errors.push(`${id}: missing source URL`);
  if (!isDate(pl.checked)) errors.push(`${id}: missing checked date`);
  if (!["official", "reported"].includes(pl.confidence)) errors.push(`${id}: bad confidence`);
  if (!pl.summary?.en || !pl.summary?.zh) errors.push(`${id}: summary needs en + zh`);
}
for (const [k, s] of Object.entries(models.sources)) {
  if (!isUrl(s.url) || !isDate(s.checked)) errors.push(`source ${k}: needs url + checked date`);
}
for (const m of models.models) {
  if (!providers.has(m.provider)) errors.push(`${m.id}: unknown provider`);
  const hasMetric = m.intelligence != null || m.speed != null || m.costPerTask != null;
  if (hasMetric && !models.sources[m.metricSrc]) errors.push(`${m.id}: metrics without metricSrc`);
  if ((m.input != null || m.output != null) && !models.sources[m.priceSrc]) errors.push(`${m.id}: price without priceSrc`);
  if (m.priceNote && (!m.priceNote.en || !m.priceNote.zh)) errors.push(`${m.id}: priceNote needs en + zh`);
}
for (const c of changes.changes) {
  const id = `change ${c.date} ${c.provider}`;
  if (!isDate(c.date) || !isUrl(c.source)) errors.push(`${id}: needs date + source`);
  if (!providers.has(c.provider)) errors.push(`${id}: unknown provider`);
  if (!c.text?.en || !c.text?.zh) errors.push(`${id}: text needs en + zh`);
}
for (const r of resets.resets) {
  const id = `reset ${r.at}`;
  if (isNaN(new Date(r.at)) || !isUrl(r.source)) errors.push(`${id}: needs time + source`);
  if (!["full", "banked"].includes(r.kind)) errors.push(`${id}: bad kind`);
  if (!["official", "tracker"].includes(r.confidence)) errors.push(`${id}: bad confidence`);
  if (!r.text?.en || !r.text?.zh) errors.push(`${id}: text needs en + zh`);
}
if (!isUrl(efforts.source?.url) || !isDate(efforts.source?.checked)) errors.push("efforts: needs source url + checked date");
for (const f of efforts.models) {
  if (!providers.has(f.provider)) errors.push(`efforts ${f.model}: unknown provider`);
  for (const e of f.efforts) if (!efforts.effortOrder.includes(e.effort) || !Number.isFinite(e.intelligence)) errors.push(`efforts ${f.model}/${e.effort}: bad row`);
}
if (errors.length) { console.error(errors.join("\n")); process.exit(1); }
console.log(`OK: ${plans.providers.reduce((n, p) => n + p.plans.length, 0)} plans, ${models.models.length} models, ${changes.changes.length} changes, ${resets.resets.length} resets, all sourced and dated.`);
