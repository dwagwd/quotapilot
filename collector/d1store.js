// A key-value store on Cloudflare D1 with the same four calls the collector used on Workers KV
// (get, put with expirationTtl, delete, list by prefix), so the collector's logic is unchanged.
// D1's free plan allows 100,000 row writes a day; KV's allows 1,000, which capped how many people could share.
//
// One table: kv(key, value, expires). `expires` is a Unix time in seconds or NULL. Expired rows are never
// returned, and a small batch of them is deleted now and then on writes (D1 has no built-in expiry).
// The table is created on first use, so a new database needs no setup step and no extra API permission.

// What the collector may write per day on this store. Worst case: 2,000 x 6 (new reporters) + 6,000 x 3 (known)
// + 200 x 96 (forget) + 10,000 (visits) = 59,200 row writes, inside D1's free 100,000.
export const D1_BUDGET = { newBatchesPerDay: 2000, knownBatchesPerDay: 6000, forgetsPerDay: 200, visitWriteCap: 10000 };

const SWEEP_EVERY = 50;      // about one write in 50 also clears expired rows
const SWEEP_ROWS = 500;

export function d1Store(db, { random = Math.random, now = () => Date.now() } = {}) {
  let ready;
  const init = () => (ready ??= db.batch([
    db.prepare("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires INTEGER) WITHOUT ROWID"),
    db.prepare("CREATE INDEX IF NOT EXISTS kv_expires ON kv (expires) WHERE expires IS NOT NULL")
  ]).catch((e) => { ready = undefined; throw e; }));
  const seconds = () => Math.floor(now() / 1000);

  return {
    budget: D1_BUDGET,
    async get(key) {
      await init();
      const row = await db.prepare("SELECT value FROM kv WHERE key = ?1 AND (expires IS NULL OR expires > ?2)").bind(key, seconds()).first();
      return row ? row.value : null;
    },
    async put(key, value, options) {
      await init();
      const ttl = Number(options?.expirationTtl);
      const expires = Number.isFinite(ttl) && ttl > 0 ? seconds() + Math.floor(ttl) : null;
      await db.prepare("INSERT INTO kv (key, value, expires) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET value = excluded.value, expires = excluded.expires")
        .bind(key, String(value), expires).run();
      if (random() < 1 / SWEEP_EVERY) {
        await db.prepare("DELETE FROM kv WHERE key IN (SELECT key FROM kv WHERE expires IS NOT NULL AND expires <= ?1 LIMIT ?2)").bind(seconds(), SWEEP_ROWS).run().catch(() => {});
      }
    },
    async delete(key) {
      await init();
      await db.prepare("DELETE FROM kv WHERE key = ?1").bind(key).run();
    },
    // Keys that start with `prefix`, in order, `limit` at a time. The cursor is the last key of the previous page.
    async list({ prefix = "", cursor, limit = 1000 } = {}) {
      await init();
      const size = Math.max(1, Math.min(1000, Math.floor(limit) || 1000));
      // Every key that starts with the prefix sorts between the prefix and the prefix followed by the highest character.
      const rows = await db.prepare("SELECT key FROM kv WHERE key >= ?1 AND key < ?2 AND key > ?3 AND (expires IS NULL OR expires > ?4) ORDER BY key LIMIT ?5")
        .bind(prefix, prefix + "￿", cursor || "", seconds(), size + 1).all();
      const names = (rows.results || []).map((r) => r.key);
      const complete = names.length <= size;
      const keys = names.slice(0, size).map((name) => ({ name }));
      return { keys, list_complete: complete, cursor: complete ? undefined : keys[keys.length - 1].name };
    }
  };
}

// Reads fall back to the store used before the move (Workers KV), so reports sent before it still count and can still
// be deleted, and old visit totals stay readable. Writes go only to the new store; deletes go to both. The old store's
// entries expire on their own (reports after 31 days), after which it can be unbound.
export function layered(primary, legacy) {
  if (!legacy) return primary;
  return {
    budget: primary.budget,
    async get(key) { return (await primary.get(key)) ?? (await legacy.get(key)); },
    put: (key, value, options) => primary.put(key, value, options),
    async delete(key) { await primary.delete(key); await legacy.delete(key); },
    // The new store's pages first, then the old store's. The cursor says which store it belongs to.
    async list({ prefix = "", cursor, limit = 1000 } = {}) {
      const from = typeof cursor === "string" && cursor.startsWith("old:") ? "old" : "new";
      if (from === "new") {
        const page = await primary.list({ prefix, cursor: cursor ? cursor.slice(4) : undefined, limit });
        if (!page.list_complete) return { keys: page.keys, list_complete: false, cursor: "new:" + page.cursor };
        const rest = await legacy.list({ prefix, limit: 1 });
        return rest.keys.length ? { keys: page.keys, list_complete: false, cursor: "old:" } : { keys: page.keys, list_complete: true, cursor: undefined };
      }
      const page = await legacy.list({ prefix, cursor: cursor.slice(4) || undefined, limit });
      return { keys: page.keys, list_complete: page.list_complete, cursor: page.list_complete ? undefined : "old:" + page.cursor };
    }
  };
}

// The store the collector uses: D1 when the DB binding exists (with KV behind it for older data), otherwise KV alone.
const stores = new WeakMap();   // one store per database binding, so the tables are checked once per instance, not per request
export function storeFor(env) {
  if (!env.DB) return env.REPORTS;
  let store = stores.get(env.DB);
  if (!store) { store = d1Store(env.DB); stores.set(env.DB, store); }
  return layered(store, env.REPORTS);
}
