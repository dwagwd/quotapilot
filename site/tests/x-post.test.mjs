import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { xLength, resetPost, changePost, pinnedPost, pending, resetId, oauthHeader } from "../scripts/x-post.mjs";

const load = (f) => JSON.parse(readFileSync(new URL("../data/" + f, import.meta.url)));
const resets = load("resets.json"), changes = load("changes.json");

test("links count 23 and wide characters count 2", () => {
  assert.equal(xLength("ab https://example.com/very/long/path"), 3 + 23);
  assert.equal(xLength("中文"), 4);
});

test("every generated post fits in 280 and links back to the site", () => {
  for (const t of [...resets.resets.map(resetPost), ...changes.changes.map(changePost), pinnedPost()]) {
    assert.ok(xLength(t) <= 280, t);
    assert.match(t, /aiquotawatch\.pages\.dev/);
  }
});

test("only fresh, unseen items are posted, oldest first, at most 3", () => {
  const latest = resets.resets.map((r) => r.at).sort().at(-1);
  const now = new Date(new Date(latest).getTime() + 3600e3);
  const { post, stale } = pending(resets, { changes: [] }, new Set(), now);
  assert.ok(post.length >= 1 && post.length <= 3);
  assert.ok(post.every((i, k) => k === 0 || post[k - 1].at <= i.at));
  assert.ok(stale.length > 0);
  const seen = new Set(resets.resets.map(resetId));
  assert.equal(pending(resets, { changes: [] }, seen, now).post.length, 0);
});

test("OAuth 1.0a signature matches X's documented example", () => {
  const h = oauthHeader("POST", "https://api.twitter.com/1.1/statuses/update.json",
    { key: "xvz1evFS4wEEPTGEFPHBog", secret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw", token: "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb", tokenSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE" },
    "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg", 1318622958, { include_entities: "true", status: "Hello Ladies + Gentlemen, a signed OAuth request!" });
  assert.match(h, /oauth_signature="hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D"/);
});
