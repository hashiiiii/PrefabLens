import { copyFileSync, cpSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { build } from "esbuild";

mkdirSync("dist", { recursive: true });

const e2e = process.argv.includes("--e2e");

// --demo: build only the site demo bundle (see presentation/demo). Kept out of the
// default build so the extension's shipped dist stays lean.
if (process.argv.includes("--demo")) {
  await build({
    entryPoints: { demo: "src/presentation/demo/index.ts" },
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
    content: "src/presentation/content/index.ts",
    background: "src/presentation/background/index.ts",
  },
  bundle: true,
  format: "iife",
  target: "chrome120",
  minify: true,
  outdir: "dist",
  define: {
    __API_BASE__: JSON.stringify(e2e ? "http://127.0.0.1:8471" : "https://api.github.com"),
    __GITHUB_ORIGIN__: JSON.stringify(e2e ? "http://127.0.0.1:8471" : "https://github.com"),
  },
});

const manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
if (e2e) {
  // --e2e: grant and target the fixed port the fake-GitHub server in full.spec.ts listens on
  manifest.host_permissions.push("http://127.0.0.1/*");
  manifest.content_scripts.push({ matches: ["http://127.0.0.1/*"], js: ["content.js"], run_at: "document_idle" });
}
writeFileSync("dist/manifest.json", JSON.stringify(manifest, null, 2));

// realpath so a worktree symlink to the main checkout wasm still copies a real file
copyFileSync(realpathSync("../zig-out/bin/prefablens.wasm"), "dist/prefablens.wasm");
mkdirSync("dist/images", { recursive: true });
for (const size of [16, 32, 48, 128]) cpSync(`images/icon${size}.png`, `dist/images/icon${size}.png`);
