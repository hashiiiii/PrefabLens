import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const wasmUrl = new URL('../../zig-out/bin/prefablens.wasm', import.meta.url);
const { instance } = await WebAssembly.instantiate(await readFile(wasmUrl));
const exports = instance.exports;

function callDiff(before, after) {
  const enc = new TextEncoder();
  const b = enc.encode(before);
  const a = enc.encode(after);
  const bp = b.length ? exports.alloc(b.length) : 0;
  const ap = a.length ? exports.alloc(a.length) : 0;
  // ビューは最後の alloc の後に作る: memory.grow で古い ArrayBuffer は detach される
  new Uint8Array(exports.memory.buffer, bp, b.length).set(b);
  new Uint8Array(exports.memory.buffer, ap, a.length).set(a);
  const rp = exports.diff(bp, b.length, ap, a.length);
  assert.notEqual(rp, 0, 'diff returned null (OOM)');
  const len = new DataView(exports.memory.buffer).getUint32(rp, true);
  const json = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, rp + 4, len));
  exports.free(rp, 4 + len);
  if (b.length) exports.free(bp, b.length);
  if (a.length) exports.free(ap, a.length);
  return json;
}

const BEFORE = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`;

const AFTER = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`;

const GOLDEN = '{"schema":"prefablens.diff.v1","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","status":"modified","fields":[{"path":"volume","status":"modified","before":"0.5","after":"0.8"}]}]}';

test('wasm diff matches the native golden JSON', () => {
  assert.equal(callDiff(BEFORE, AFTER), GOLDEN);
});

test('empty before (added file) still yields a diff.v1 document', () => {
  const json = JSON.parse(callDiff('', AFTER));
  assert.equal(json.schema, 'prefablens.diff.v1');
});

test('hostile nesting returns a clean error.v1 payload, not a trap', () => {
  // parser の max_nesting_depth は 128(core/src/parser.zig)。200 段で確実に超える。
  let src = '--- !u!1 &1\nGameObject:\n';
  for (let depth = 1; depth <= 200; depth++) src += '  '.repeat(depth) + 'a:\n';
  const json = JSON.parse(callDiff(src, src));
  assert.equal(json.schema, 'prefablens.error.v1');
  assert.equal(json.error, 'NestingTooDeep');
});

test('repeated calls do not leak or corrupt state (pure, re-entrant)', () => {
  for (let i = 0; i < 50; i++) assert.equal(callDiff(BEFORE, AFTER), GOLDEN);
});
