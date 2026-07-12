import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { build } from "esbuild";

mkdirSync("dist", { recursive: true });

const e2e = process.argv.includes("--e2e");

// --viewer: build only the embeddable viewer artifact (see src/viewer.ts).
// Kept out of the default build so the extension's shipped dist stays lean.
if (process.argv.includes("--viewer")) {
  await build({
    entryPoints: { viewer: "src/viewer.ts" },
    bundle: true,
    format: "iife",
    globalName: "PrefabLensViewer",
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
  define: { __API_BASE__: JSON.stringify(e2e ? "http://127.0.0.1:8471" : "https://api.github.com") },
});

const manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
if (e2e) {
  // --e2e: grant and target the fixed port the fake-GitHub server in full.spec.ts listens on
  manifest.host_permissions.push("http://127.0.0.1/*");
  manifest.content_scripts.push({ matches: ["http://127.0.0.1/*"], js: ["content.js"], run_at: "document_idle" });
}
writeFileSync("dist/manifest.json", JSON.stringify(manifest, null, 2));

cpSync("src/options/options.html", "dist/options.html");
cpSync("../zig-out/bin/prefablens.wasm", "dist/prefablens.wasm");
mkdirSync("dist/icons", { recursive: true });
for (const size of [16, 32, 48, 128]) cpSync(`icons/icon${size}.png`, `dist/icons/icon${size}.png`);
