import type { DiffV2 } from "../types";

const PREFIX = "diff:";
const MAX_BYTES = 512 * 1024; // storage.session は 10MB: 大物はメモリキャッシュだけに任せる(SW が死んだら再計算)

// chrome.storage.session の必要部分だけを受ける(テストで fake に差し替え可能にするため)
type Area = {
  get(keys: string | string[] | null): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
};

export type DiffStore = {
  load(key: string): Promise<DiffV2 | undefined>;
  save(key: string, json: DiffV2): Promise<void>;
};

/** raw diff を sha キーで storage.session に載せ、SW 再起動をまたいで再利用する。
 *  quota が溢れたら溜まった diff を一掃して 1 回だけ書き直す: これをしないと一度埋まると
 *  以後 SW 再起動のたびに全再計算になり、無言で恒久劣化する(内容は sha キーで再計算可能)。 */
export function createSessionDiffStore(area: Area): DiffStore {
  return {
    async load(key) {
      const stored = await area.get(PREFIX + key);
      return stored[PREFIX + key] as DiffV2 | undefined;
    },
    async save(key, json) {
      if (JSON.stringify(json).length > MAX_BYTES) return;
      try {
        await area.set({ [PREFIX + key]: json });
      } catch {
        await flushDiffs(area);
        await area.set({ [PREFIX + key]: json }).catch(() => {
          // flush しても書けない(単一 diff が quota 超など): メモリキャッシュで続行する
        });
      }
    },
  };
}

/** diff: 付きのキーだけを一掃する(viewMode など無関係な session キーは残す)。 */
async function flushDiffs(area: Area): Promise<void> {
  const all = await area.get(null).catch(() => ({}));
  const keys = Object.keys(all).filter((k) => k.startsWith(PREFIX));
  if (keys.length) await area.remove(keys).catch(() => {});
}
