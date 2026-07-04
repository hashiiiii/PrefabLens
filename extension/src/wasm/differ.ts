import type { DiffErrorV1, DiffV2 } from '../types';

export class DiffError extends Error {}

export type Differ = { diff(before: Uint8Array, after: Uint8Array): DiffV2 };

type Exports = {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  free(ptr: number, len: number): void;
  diff(bp: number, bl: number, ap: number, al: number): number;
};

export async function createDiffer(wasmBytes: BufferSource): Promise<Differ> {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const exp = instance.exports as unknown as Exports;

  return {
    diff(before, after) {
      const bp = before.length ? exp.alloc(before.length) : 0;
      const ap = after.length ? exp.alloc(after.length) : 0;
      // コピーは最後の alloc の後: memory.grow で古いビューは detach される
      new Uint8Array(exp.memory.buffer, bp, before.length).set(before);
      new Uint8Array(exp.memory.buffer, ap, after.length).set(after);
      const rp = exp.diff(bp, before.length, ap, after.length);
      try {
        if (rp === 0) throw new DiffError('OutOfMemory');
        const len = new DataView(exp.memory.buffer).getUint32(rp, true);
        const text = new TextDecoder().decode(new Uint8Array(exp.memory.buffer, rp + 4, len));
        exp.free(rp, 4 + len);
        const parsed = JSON.parse(text) as DiffV2 | DiffErrorV1;
        if (parsed.schema !== 'prefablens.diff.v2') throw new DiffError((parsed as DiffErrorV1).error);
        return parsed;
      } finally {
        if (before.length) exp.free(bp, before.length);
        if (after.length) exp.free(ap, after.length);
      }
    },
  };
}
