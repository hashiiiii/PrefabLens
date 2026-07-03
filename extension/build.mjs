import { build } from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';

mkdirSync('dist', { recursive: true });

await build({
  entryPoints: {
    content: 'src/content/index.ts',
    background: 'src/background/index.ts',
    options: 'src/options/options.ts',
  },
  bundle: true,
  format: 'iife',
  target: 'chrome120',
  minify: true,
  outdir: 'dist',
});

cpSync('manifest.json', 'dist/manifest.json');
cpSync('src/options/options.html', 'dist/options.html');
cpSync('../zig-out/bin/prefablens.wasm', 'dist/prefablens.wasm');
