import type { DiffErrorV1, DiffV2 } from '../types';

export class DiffError extends Error {}

export type Differ = {
  diff(before: Uint8Array, after: Uint8Array): DiffV2;
  diffWithAssets(before: Uint8Array, after: Uint8Array, assets: Map<string, Uint8Array>): DiffV2;
};

type Exports = {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  free(ptr: number, len: number): void;
  diff(bp: number, bl: number, ap: number, al: number): number;
  diff_with_assets(bp: number, bl: number, ap: number, al: number, tp: number, tl: number): number;
};

/** assets TLV(LE): [u32 count] repeat{ [u32 guid_len][guid][u32 data_len][data] }。
 *  core/src/wasm.zig の parseAssets と 1:1。 */
export function encodeAssets(assets: Map<string, Uint8Array>): Uint8Array {
  const enc = new TextEncoder();
  const guids = [...assets.keys()].map((g) => enc.encode(g));
  let total = 4;
  let i = 0;
  for (const data of assets.values()) total += 8 + guids[i++]!.length + data.length;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);
  let off = 0;
  view.setUint32(off, assets.size, true);
  off += 4;
  i = 0;
  for (const data of assets.values()) {
    const guid = guids[i++]!;
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
    const bufs = assets === undefined ? [before, after] : [before, after, assets];
    const ptrs = bufs.map((b) => (b.length ? exp.alloc(b.length) : 0));
    // コピーは最後の alloc の後: memory.grow で古いビューは detach される
    bufs.forEach((b, i) => new Uint8Array(exp.memory.buffer, ptrs[i]!, b.length).set(b));
    const rp =
      assets === undefined
        ? exp.diff(ptrs[0]!, before.length, ptrs[1]!, after.length)
        : exp.diff_with_assets(ptrs[0]!, before.length, ptrs[1]!, after.length, ptrs[2]!, assets.length);
    try {
      if (rp === 0) throw new DiffError('OutOfMemory');
      const len = new DataView(exp.memory.buffer).getUint32(rp, true);
      const text = new TextDecoder().decode(new Uint8Array(exp.memory.buffer, rp + 4, len));
      exp.free(rp, 4 + len);
      const parsed = JSON.parse(text) as DiffV2 | DiffErrorV1;
      if (parsed.schema !== 'prefablens.diff.v2') throw new DiffError((parsed as DiffErrorV1).error);
      return parsed;
    } finally {
      bufs.forEach((b, i) => {
        if (b.length) exp.free(ptrs[i]!, b.length);
      });
    }
  }

  return {
    diff: (before, after) => call(before, after),
    diffWithAssets: (before, after, assets) => call(before, after, encodeAssets(assets)),
  };
}
