import type { DiffErrorV1, DiffV2 } from "../types";

export class DiffError extends Error {}

export type Differ = {
  diff(before: Uint8Array, after: Uint8Array): DiffV2;
  diffWithAssets(before: Uint8Array, after: Uint8Array, assets: Map<string, Uint8Array>): DiffV2;
  isUnityYaml(bytes: Uint8Array): boolean;
};

type Exports = {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  free(ptr: number, len: number): void;
  diff(bp: number, bl: number, ap: number, al: number): number;
  diff_with_assets(bp: number, bl: number, ap: number, al: number, tp: number, tl: number): number;
  is_unity_yaml(p: number, l: number): number;
};

/** assets TLV (LE): [u32 count] repeat{ [u32 guid_len][guid][u32 data_len][data] }.
 *  1:1 with parseAssets in core/src/wasm.zig. */
export function encodeAssets(assets: Map<string, Uint8Array>): Uint8Array {
  const enc = new TextEncoder();
  const entries = [...assets].map(([guid, data]) => ({ guid: enc.encode(guid), data }));
  let total = 4;
  for (const { guid, data } of entries) total += 8 + guid.length + data.length;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);
  let off = 0;
  view.setUint32(off, assets.size, true);
  off += 4;
  for (const { guid, data } of entries) {
    view.setUint32(off, guid.length, true);
    out.set(guid, off + 4);
    off += 4 + guid.length;
    view.setUint32(off, data.length, true);
    out.set(data, off + 4);
    off += 4 + data.length;
  }
  return out;
}

export async function createDiffer(wasmBytes: BufferSource): Promise<Differ> {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const exp = instance.exports as unknown as Exports;

  function call(before: Uint8Array, after: Uint8Array, assets?: Uint8Array): DiffV2 {
    const alloc = (b: Uint8Array): number => (b.length ? exp.alloc(b.length) : 0);
    const bp = alloc(before);
    const ap = alloc(after);
    const tp = assets === undefined ? 0 : alloc(assets);
    // Copy after the last alloc: memory.grow detaches older views
    const copy = (ptr: number, b: Uint8Array): void => {
      new Uint8Array(exp.memory.buffer, ptr, b.length).set(b);
    };
    copy(bp, before);
    copy(ap, after);
    if (assets !== undefined) copy(tp, assets);
    const rp =
      assets === undefined
        ? exp.diff(bp, before.length, ap, after.length)
        : exp.diff_with_assets(bp, before.length, ap, after.length, tp, assets.length);
    try {
      if (rp === 0) throw new DiffError("OutOfMemory");
      const len = new DataView(exp.memory.buffer).getUint32(rp, true);
      const text = new TextDecoder().decode(new Uint8Array(exp.memory.buffer, rp + 4, len));
      exp.free(rp, 4 + len);
      const parsed = JSON.parse(text) as DiffV2 | DiffErrorV1;
      if (parsed.schema !== "prefablens.diff.v2") throw new DiffError((parsed as DiffErrorV1).error);
      return parsed;
    } finally {
      if (before.length) exp.free(bp, before.length);
      if (after.length) exp.free(ap, after.length);
      if (assets?.length) exp.free(tp, assets.length);
    }
  }

  function isUnityYaml(bytes: Uint8Array): boolean {
    // The Zig sniff reads at most 512 bytes: never marshal a whole blob
    // (wasm memory only grows) just to inspect its head.
    const head = bytes.subarray(0, 512);
    const ptr = head.length ? exp.alloc(head.length) : 0;
    new Uint8Array(exp.memory.buffer, ptr, head.length).set(head);
    try {
      return exp.is_unity_yaml(ptr, head.length) !== 0;
    } finally {
      if (head.length) exp.free(ptr, head.length);
    }
  }

  return {
    diff: (before, after) => call(before, after),
    diffWithAssets: (before, after, assets) => call(before, after, encodeAssets(assets)),
    isUnityYaml,
  };
}
