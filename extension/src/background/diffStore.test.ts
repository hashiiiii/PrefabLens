import { describe, expect, it, vi } from 'vitest';
import { createSessionDiffStore } from './diffStore';
import type { DiffV2 } from '../types';

const DIFF: DiffV2 = { schema: 'prefablens.diff.v2', unresolvedGuids: [], roots: [], loose: [] };

// chrome.storage.session の必要部分だけを Map で模した fake。set は failWhen で溢れを再現する。
function fakeArea(failWhen?: () => boolean) {
  const data = new Map<string, unknown>();
  const area = {
    data,
    get: vi.fn(async (keys: string | string[] | null) => {
      if (keys === null) return Object.fromEntries(data);
      const list = Array.isArray(keys) ? keys : [keys];
      const out: Record<string, unknown> = {};
      for (const k of list) if (data.has(k)) out[k] = data.get(k);
      return out;
    }),
    set: vi.fn(async (items: Record<string, unknown>) => {
      if (failWhen?.()) throw new Error('QUOTA_BYTES quota exceeded');
      for (const [k, v] of Object.entries(items)) data.set(k, v);
    }),
    remove: vi.fn(async (keys: string | string[]) => {
      for (const k of Array.isArray(keys) ? keys : [keys]) data.delete(k);
    }),
  };
  return area;
}

describe('createSessionDiffStore', () => {
  it('round-trips a diff under the diff: prefix', async () => {
    const area = fakeArea();
    const store = createSessionDiffStore(area);
    await store.save('base:head:Assets/Foo.prefab', DIFF);
    expect(area.data.get('diff:base:head:Assets/Foo.prefab')).toEqual(DIFF);
    expect(await store.load('base:head:Assets/Foo.prefab')).toEqual(DIFF);
  });

  it('returns undefined for a missing key', async () => {
    const store = createSessionDiffStore(fakeArea());
    expect(await store.load('nope')).toBeUndefined();
  });

  it('skips diffs larger than the session budget without touching storage', async () => {
    // 大物はメモリキャッシュだけに任せる(session は 10MB しかない)
    const area = fakeArea();
    const store = createSessionDiffStore(area);
    const big: DiffV2 = { ...DIFF, unresolvedGuids: [' '.repeat(600 * 1024)] };
    await store.save('k', big);
    expect(area.set).not.toHaveBeenCalled();
  });

  it('flushes stale diff entries and retries once when the quota overflows', async () => {
    // 一度埋まると以後 SW 再起動のたびに全再計算になる恒久劣化を防ぐ:
    // 溢れたら溜まった diff を一掃して 1 回だけ書き直す
    const area = fakeArea(); // 既定 set は成功。1 回目だけ下で溢れさせる
    // 既存の diff エントリと、無関係なキーを 1 つ仕込む
    area.data.set('diff:old1', DIFF);
    area.data.set('diff:old2', DIFF);
    area.data.set('viewMode', 'semantic'); // diff: 以外は消さない
    const store = createSessionDiffStore(area);

    // 1 回目の set は溢れる → flush → retry(既定 set)は通す
    area.set.mockImplementationOnce(async () => {
      throw new Error('quota exceeded');
    });
    await store.save('new', DIFF);

    expect(area.remove).toHaveBeenCalledWith(['diff:old1', 'diff:old2']); // diff: だけ一掃
    expect(area.data.has('viewMode')).toBe(true); // 無関係キーは残す
    expect(area.data.get('diff:new')).toEqual(DIFF); // 再試行で書けている
    expect(area.set).toHaveBeenCalledTimes(2); // 溢れ 1 回 + retry 1 回だけ(ループ化への退行を固定)
  });

  it('gives up quietly if the retry also fails', async () => {
    // flush しても書けない(単一 diff が quota 超): メモリキャッシュで続行、例外は投げない
    const area = fakeArea(() => true); // 常に溢れる
    const store = createSessionDiffStore(area);
    await expect(store.save('k', DIFF)).resolves.toBeUndefined();
  });
});
