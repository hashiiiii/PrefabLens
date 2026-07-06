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

const GOLDEN = '{"schema":"prefablens.diff.v2","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","className":null,"status":"modified","fields":[{"path":"Volume","status":"modified","before":"0.5","after":"0.8"}]}]}';

test('wasm diff matches the native golden JSON', () => {
  assert.equal(callDiff(BEFORE, AFTER), GOLDEN);
});

test('empty before (added file) still yields a diff.v2 document', () => {
  const json = JSON.parse(callDiff('', AFTER));
  assert.equal(json.schema, 'prefablens.diff.v2');
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

// ---- diff_with_assets(ソース prefab の合成)----

// assets TLV(LE): [u32 count] repeat{ [u32 guid_len][guid][u32 data_len][data] }
function buildAssetsTlv(entries) {
  const enc = new TextEncoder();
  const parts = [];
  const push32 = (n) => {
    const b = new Uint8Array(4);
    new DataView(b.buffer).setUint32(0, n, true);
    parts.push(b);
  };
  const list = Object.entries(entries);
  push32(list.length);
  for (const [guid, data] of list) {
    for (const chunk of [enc.encode(guid), enc.encode(data)]) {
      push32(chunk.length);
      parts.push(chunk);
    }
  }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function callDiffWithAssets(before, after, assetsTlv) {
  const enc = new TextEncoder();
  const b = enc.encode(before);
  const a = enc.encode(after);
  const t = assetsTlv;
  const bp = b.length ? exports.alloc(b.length) : 0;
  const ap = a.length ? exports.alloc(a.length) : 0;
  const tp = t.length ? exports.alloc(t.length) : 0;
  // ビューは最後の alloc の後に作る: memory.grow で古い ArrayBuffer は detach される
  new Uint8Array(exports.memory.buffer, bp, b.length).set(b);
  new Uint8Array(exports.memory.buffer, ap, a.length).set(a);
  new Uint8Array(exports.memory.buffer, tp, t.length).set(t);
  const rp = exports.diff_with_assets(bp, b.length, ap, a.length, tp, t.length);
  assert.notEqual(rp, 0, 'diff_with_assets returned null (OOM)');
  const len = new DataView(exports.memory.buffer).getUint32(rp, true);
  const json = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, rp + 4, len));
  exports.free(rp, 4 + len);
  if (b.length) exports.free(bp, b.length);
  if (a.length) exports.free(ap, a.length);
  if (t.length) exports.free(tp, t.length);
  return json;
}

const VARIANT = `--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: srcguid, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}`;

const SOURCE = `--- !u!1 &10
GameObject:
  m_Name: Cyl
  m_Component:
  - component: {fileID: 40}
--- !u!4 &40
Transform:
  m_GameObject: {fileID: 10}
  m_LocalScale: {x: 1, y: 1, z: 1}`;

test('added instance without assets reports neededSources', () => {
  const json = JSON.parse(callDiff('', VARIANT));
  assert.deepEqual(json.neededSources, [{ guid: 'srcguid', side: 'after' }]);
});

test('diff_with_assets merges the source prefab', () => {
  const json = JSON.parse(callDiffWithAssets('', VARIANT, buildAssetsTlv({ srcguid: SOURCE })));
  assert.equal(json.neededSources, undefined);
  const inst = json.roots[0];
  assert.equal(inst.kind, 'prefabInstance');
  assert.deepEqual(inst.overrides, []);
  const tr = inst.components.find((c) => c.classId === 4);
  const scale = tr.fields.find((f) => f.path === 'Scale');
  assert.equal(scale.after, '(1, 2, 1)');
});

test('broken assets TLV yields a clean error.v1 payload', () => {
  const json = JSON.parse(callDiffWithAssets('', VARIANT, new Uint8Array([1, 0, 0, 0, 9])));
  assert.equal(json.schema, 'prefablens.error.v1');
  assert.equal(json.error, 'TruncatedAssets');
});
