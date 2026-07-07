import type { GithubClient } from "./client";
import { parseGuidFromMeta } from "./guids";

type ClientLike = Pick<GithubClient, "listMetaTree" | "batchBlobTexts">;

export type RepoIndexStore = {
  loadGuids(repo: string): Promise<Record<string, string>>;
  saveGuids(repo: string, entries: Record<string, string>): Promise<void>;
  loadIndex(repo: string): Promise<{ treeSha: string; guids: Record<string, string> } | undefined>;
  saveIndex(repo: string, index: { treeSha: string; guids: Record<string, string> }): Promise<void>;
};

const INDEX_MAX_METAS = 50_000; // spec B3: これ超は storage quota 保護で索引を諦める
const GRAPHQL_BATCH = 100;

/** repo 全体の guid → asset path 索引。索引不可(truncated / 上限超)は null で Code Search に委ねる。
 *  blobSha → guid は内容由来なので永久キャッシュでき、push 後は変わった .meta だけ取得する。 */
export async function syncRepoIndex(
  client: ClientLike,
  store: RepoIndexStore,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Record<string, string> | null> {
  const existing = await store.loadIndex(repoKey);
  if (existing?.treeSha === ref) return existing.guids;
  const tree = await client.listMetaTree(owner, repo, ref);
  if (tree.truncated || tree.metas.length > INDEX_MAX_METAS) return null;
  const known = await store.loadGuids(repoKey);
  // hasOwn: guid キャッシュ同様、プロトタイプ誤ヒットを避ける
  const missing = tree.metas.filter((m) => !Object.hasOwn(known, m.sha));
  const fetched: Record<string, string> = {};
  for (let i = 0; i < missing.length; i += GRAPHQL_BATCH) {
    const chunk = missing.slice(i, i + GRAPHQL_BATCH);
    const texts = await client.batchBlobTexts(
      owner,
      repo,
      chunk.map((m) => m.sha),
    );
    for (const m of chunk) {
      const text = texts[m.sha];
      if (!text) continue; // バイナリ・取得不可はスキップ
      const guid = parseGuidFromMeta(text);
      if (guid) fetched[m.sha] = guid;
    }
  }
  if (Object.keys(fetched).length) await store.saveGuids(repoKey, fetched);
  const merged = { ...known, ...fetched };
  const guids: Record<string, string> = {};
  for (const m of tree.metas) {
    const guid = merged[m.sha];
    if (guid) guids[guid] = m.path.slice(0, -".meta".length);
  }
  await store.saveIndex(repoKey, { treeSha: ref, guids });
  return guids;
}
