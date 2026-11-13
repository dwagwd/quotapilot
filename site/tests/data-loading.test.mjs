import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const w = {};
new Function("window", readFileSync(new URL("../assets/community-state.js", import.meta.url), "utf8"))(w);

test("datasets stay inside root and project-prefix deployments, including Chinese pages", async () => {
  for (const origin of ["https://example.test/", "https://example.test/quotapilot/"]) {
    for (const page of ["", "zh/"]) {
      const script = new URL("../assets/app.js", origin + "zh/");
      const base = new URL("../", script);
      let requested;
      const data = await w.AQW_STATE.readDataset("data/plans.json", {
        base, refresh: true,
        fetcher: async function (url, options) {
          assert.equal(this, undefined);
          requested = url;
          assert.equal(options.cache, "no-cache");
          return { ok: true, json: async () => ({ plans: [page] }) };
        }
      });
      assert.equal(requested, origin + "data/plans.json");
      assert.deepEqual(data, { plans: [page] });
    }
  }
});

test("standalone data is read without a network request and missing data rejects", async () => {
  const options = { embedded: { "data/plans.json": { providers: [] } }, fetcher: () => assert.fail("network used") };
  assert.deepEqual(await w.AQW_STATE.readDataset("data/plans.json", options), { providers: [] });
  await assert.rejects(w.AQW_STATE.readDataset("data/missing.json", options), /Missing embedded dataset/);
});

test("failed HTTP responses remain retryable", async () => {
  await assert.rejects(w.AQW_STATE.readDataset("data/plans.json", {
    base: "https://example.test/", fetcher: async () => ({ ok: false, status: 503 })
  }), /503/);
});

test("preview generator bundles scripts and data without external script dependencies", () => {
  const dir = mkdtempSync(join(tmpdir(), "aqw-preview-"));
  try {
    const out = join(dir, "preview.html");
    execFileSync("python3", [fileURLToPath(new URL("../scripts/build-preview.py", import.meta.url)), out, "--demo"]);
    const html = readFileSync(out, "utf8");
    assert.match(html, /<!doctype html>/i);
    assert.match(html, /window\.__AQW_DATA = /);
    assert.match(html, /window\.__AQW_DEMO = true/);
    assert.doesNotMatch(html, /<script src=/);
    assert.doesNotMatch(html, /http-equiv="Content-Security-Policy"/);
    assert.match(html, /state\[k\] = await getData/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
