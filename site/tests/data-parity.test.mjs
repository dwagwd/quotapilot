import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const read = (f) => JSON.parse(fs.readFileSync(new URL("../data/" + f, import.meta.url), "utf8"));
const models = read("models.json").models;
const efforts = read("efforts.json").models;

// The calculator and the effort ladder come from the same benchmark. When a calculator row matches an effort row
// (same intelligence and cost per task), their output speed must be the same number, or the page contradicts itself.
test("calculator speed equals the effort-ladder speed for the same benchmark row", () => {
  for (const m of models) {
    const fam = efforts.find((f) => f.model === m.id);
    if (!fam || m.speed == null) continue;
    const row = fam.efforts.find((e) => e.intelligence === m.intelligence && e.costPerTask === m.costPerTask);
    if (!row) continue;
    assert.equal(m.speed, row.speed, `${m.id}: models.json says ${m.speed} tok/s, efforts.json (${row.effort}) says ${row.speed}`);
  }
});
