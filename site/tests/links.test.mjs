// Every site-internal link in the generated pages, the home page and the 404 page must point at a file that exists.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, existsSync, statSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const site = fileURLToPath(new URL("..", import.meta.url));

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out); else if (name.endsWith(".html")) out.push(p);
  }
  return out;
}

test("internal links resolve to real pages", () => {
  const out = mkdtempSync(join(tmpdir(), "aqw-links-"));
  try {
    execFileSync(process.execPath, [join(site, "scripts/build-pages.mjs"), out], { stdio: "ignore" });
    // A path exists when the generated tree or the source tree has it as a file, as <path>.html or as <path>/index.html.
    const has = (p) => [out, site].some((root) => {
      const f = join(root, p);
      return (existsSync(f) && statSync(f).isFile()) || existsSync(f + ".html") || existsSync(join(f, "index.html"));
    });
    const pages = walk(out).map((f) => [relative(out, f), readFileSync(f, "utf8")]);
    for (const name of ["index.html", "404.html"]) pages.push([name, readFileSync(join(site, name), "utf8")]);
    const broken = [];
    for (const [page, html] of pages) {
      for (const m of html.matchAll(/(?:href|src)="([^"]*)"/g)) {
        let link = m[1].split("#")[0].split("?")[0];
        if (!link || /^[a-z][a-z0-9+.-]*:/i.test(link) || link.startsWith("//")) continue;
        const target = link.startsWith("/") ? link.slice(1) : join(dirname(page), link);
        if (target === "" || target === ".") continue;            // the home page
        if (target.startsWith("..")) { broken.push(`${page} -> ${m[1]} (leaves the site)`); continue; }
        if (!has(target)) broken.push(`${page} -> ${m[1]}`);
      }
    }
    assert.deepEqual(broken, []);
    assert.ok(existsSync(join(out, "resets/index.html")) && existsSync(join(out, "zh/resets/index.html")), "/resets/ has an index in both languages");
    assert.match(readFileSync(join(out, "zh/index.html"), "utf8"), /href="\/zh\/resets\/codex"/, "the Chinese home page links the Chinese reset history");
  } finally { rmSync(out, { recursive: true, force: true }); }
});

test("the install notes link points at a heading the README has", () => {
  const cfg = readFileSync(join(site, "assets/config.js"), "utf8");
  const anchor = cfg.match(/notesUrl:\s*"https:\/\/github\.com\/dwagwd\/quotapilot#([^"]+)"/)[1];
  const slugs = readFileSync(join(site, "../README.md"), "utf8").split("\n").filter((l) => /^#{1,6} /.test(l))
    .map((l) => l.replace(/^#+ /, "").trim().toLowerCase().replace(/[^\w\- ]/g, "").replace(/ /g, "-"));
  assert.ok(slugs.includes(anchor), `README has no heading for #${anchor}`);
});
