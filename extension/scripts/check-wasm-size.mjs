import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";

const TARGET_KB = 80; // target from parent spec §5.7
const LIMIT_KB = 150; // CI fails if exceeded

const wasmUrl = new URL("../../zig-out/bin/prefablens.wasm", import.meta.url);
const gz = gzipSync(readFileSync(wasmUrl), { level: 9 }).length;
const kb = (gz / 1024).toFixed(1);

if (gz > LIMIT_KB * 1024) {
  console.error(`WASM gzip size ${kb} KB exceeds the ${LIMIT_KB} KB hard limit`);
  process.exit(1);
}
const verdict = gz > TARGET_KB * 1024 ? `over the ${TARGET_KB} KB target` : `within the ${TARGET_KB} KB target`;
console.log(`WASM gzip size: ${kb} KB (${verdict}, hard limit ${LIMIT_KB} KB)`);
