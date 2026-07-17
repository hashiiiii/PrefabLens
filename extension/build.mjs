import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { build } from "esbuild";

mkdirSync("dist", { recursive: true });

const e2e = process.argv.includes("--e2e");

// --demo: build only the site demo bundle (see src/demo.ts). Kept out of the
// default build so the extension's shipped dist stays lean.
if (process.argv.includes("--demo")) {
  await build({
    entryPoints: { demo: "src/demo.ts" },
    bundle: true,
    format: "iife",
    target: "chrome120",
    minify: true,
    outdir: "dist",
  });
  process.exit(0);
}

await build({
  entryPoints: {
    content: "src/content/index.ts",
    background: "src/background/index.ts",
    options: "src/options/options.ts",
  },
  bundle: true,
  format: "iife",
  target: "chrome120",
  minify: true,
  outdir: "dist",
});

const manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
if (e2e) {
  // --e2e: grant and statically inject into the fake-GitHub server from full.spec.ts. The API
  // base needs no wiring — the runtime resolves it from the page origin (GHES shape for loopback).
  manifest.host_permissions.push("http://127.0.0.1/*");
  manifest.content_scripts.push({ matches: ["http://127.0.0.1/*"], js: ["content.js"], run_at: "document_idle" });
}
writeFileSync("dist/manifest.json", JSON.stringify(manifest, null, 2));

cpSync("src/options/options.html", "dist/options.html");
cpSync("../zig-out/bin/prefablens.wasm", "dist/prefablens.wasm");
mkdirSync("dist/images", { recursive: true });
for (const size of [16, 32, 48, 128]) cpSync(`images/icon${size}.png`, `dist/images/icon${size}.png`);
