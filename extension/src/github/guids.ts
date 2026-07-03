import type { DiffV1 } from '../types';
import { RateLimitError, type PrFile } from './client';

/** cli/src/resolve.zig の parseGuid と同じ規則: 行頭(trim 後)の "guid:" を拾う。 */
export function parseGuidFromMeta(meta: string): string | undefined {
  for (const line of meta.split('\n')) {
    const t = line.trim();
    if (t.startsWith('guid:')) return t.slice('guid:'.length).trim();
  }
  return undefined;
}

export type MetaFetcher = (path: string, side: 'base' | 'head') => Promise<string | null>;

const MAX_CONCURRENT_META_FETCHES = 8;

/** PR 内で変更された .meta のみから guid → asset path 索引を作る(設計スコープ)。removed は base 側から読む。
 *  同時フェッチ数を上限 8 に抑える(大量 .meta 変更での GitHub secondary rate limit 回避)。 */
export async function buildGuidIndex(files: PrFile[], fetchMeta: MetaFetcher): Promise<Map<string, string>> {
  const index = new Map<string, string>();
  const metas = files.filter((f) => f.path.endsWith('.meta'));

  const indexOne = async (f: PrFile): Promise<void> => {
    const side = f.status === 'removed' ? 'base' : 'head';
    // rate limit だけは伝播させる: 握りつぶすと劣化インデックスが SW 生存期間キャッシュされる
    const text = await fetchMeta(f.path, side).catch((err) => {
      if (err instanceof RateLimitError) throw err;
      return null;
    });
    if (!text) return;
    const guid = parseGuidFromMeta(text);
    if (guid) index.set(guid, f.path.slice(0, -'.meta'.length));
  };

  for (let i = 0; i < metas.length; i += MAX_CONCURRENT_META_FETCHES) {
    const chunk = metas.slice(i, i + MAX_CONCURRENT_META_FETCHES);
    await Promise.all(chunk.map(indexOne));
  }

  return index;
}

/** ホスト側解決の seam(親仕様 §4.3)。core の "resolved" と同じスコープ規則で付与する。 */
export function applyResolved(diff: DiffV1, index: Map<string, string>): DiffV1 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
