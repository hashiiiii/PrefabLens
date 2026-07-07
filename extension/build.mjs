import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { build } from "esbuild";

mkdirSync("dist", { recursive: true });

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

// --e2e: full-stack E2E がローカル HTTP サーバを「GHES」として使えるよう 127.0.0.1 を事前許可する
// (permissions.request は許可済みオリジンならプロンプトなしで true を返す)
const manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
if (process.argv.includes("--e2e")) manifest.host_permissions.push("http://127.0.0.1/*");
writeFileSync("dist/manifest.json", JSON.stringify(manifest, null, 2));

cpSync("src/options/options.html", "dist/options.html");
cpSync("../zig-out/bin/prefablens.wasm", "dist/prefablens.wasm");
