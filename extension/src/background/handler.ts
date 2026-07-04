import { AuthError, RateLimitError, apiBase, type GithubClient, type PrFile, type PrRefs } from '../github/client';
import { applyResolved, buildGuidIndex, type GuidCache } from '../github/guids';
import { DiffError, type Differ } from '../wasm/differ';
import type { DiffV2, SemanticDiffRequest, SemanticDiffResponse } from '../types';

type ClientLike = Pick<GithubClient, 'getPrRefs' | 'listPrFiles' | 'getFileAtRef' | 'searchMetaByGuid'>;

export type Deps = {
  getSettings(): Promise<{ pat?: string; baseUrl?: string }>;
  makeClient(base: string, token: string): ClientLike;
  getDiffer(): Promise<Differ>;
  guidCache: GuidCache;
};

type PrContext = { refs: PrRefs; files: PrFile[]; guidIndex: Map<string, string> };

const EMPTY = new Uint8Array(0);
const MAX_SEARCHES = 10; // Code Search は認証済み 10 req/min — 1 応答で使い切らない
const CONTEXT_TTL_MS = 60_000; // push で headSha が変わるため PR コンテキストは短命
const BLOB_CACHE_MAX = 32;

export function createHandler(deps: Deps): (req: SemanticDiffRequest) => Promise<SemanticDiffResponse> {
  // PR 単位のコンテキストキャッシュ。SW はいつ殺されてもよく、その場合は再取得するだけ。
  const contexts = new Map<string, { at: number; ctx: Promise<PrContext> }>();
  // sha+path → bytes。内容は不変なので TTL 不要。25MB ガードの force 再要求もここに当たる
  const blobs = new Map<string, Uint8Array | null>();
  // Code Search の未ヒット guid。索引遅延があるため永続化せず SW 生存期間のみ
  const misses = new Set<string>();

  /** PR 内 .meta で解決できなかった guid を キャッシュ → Code Search の順で解決する。
   *  検索の失敗(レート制限含む)で diff は落とさない: 解決できた分だけ載せる。 */
  async function searchUnresolved(json: DiffV2, client: ClientLike, owner: string, repo: string, repoKey: string): Promise<DiffV2> {
    const resolved = { ...json.resolved };
    const pending = json.unresolvedGuids.filter((g) => !(g in resolved) && !misses.has(`${repoKey}:${g}`));
    if (!pending.length) return { ...json, resolved };
    const cached = await deps.guidCache.load(repoKey);
    const found: Record<string, string> = {};
    let searches = 0;
    for (const g of pending) {
      if (cached[g] !== undefined) {
        resolved[g] = cached[g];
        continue;
      }
      if (searches++ >= MAX_SEARCHES) continue;
      try {
        const path = await client.searchMetaByGuid(owner, repo, g);
        if (path) resolved[g] = found[g] = path;
        else misses.add(`${repoKey}:${g}`);
      } catch (err) {
        if (err instanceof RateLimitError) break;
        misses.add(`${repoKey}:${g}`);
      }
    }
    if (Object.keys(found).length) await deps.guidCache.save(repoKey, found);
    return { ...json, resolved };
  }

  async function fetchBlob(client: ClientLike, owner: string, repo: string, path: string, sha: string): Promise<Uint8Array | null> {
    const key = `${sha}:${path}`;
    const hit = blobs.get(key); // 格納値は Uint8Array | null なので undefined = 未キャッシュ
    if (hit !== undefined) return hit;
    const bytes = await client.getFileAtRef(owner, repo, path, sha);
    blobs.set(key, bytes);
    if (blobs.size > BLOB_CACHE_MAX) blobs.delete(blobs.keys().next().value!);
    return bytes;
  }

  function loadContext(client: ClientLike, owner: string, repo: string, prNumber: number): Promise<PrContext> {
    const key = `${owner}/${repo}#${prNumber}`;
    const entry = contexts.get(key);
    if (entry && Date.now() - entry.at < CONTEXT_TTL_MS) return entry.ctx;
    const ctx = (async () => {
      const refs = await client.getPrRefs(owner, repo, prNumber);
      const files = await client.listPrFiles(owner, repo, prNumber);
      const guidIndex = await buildGuidIndex(files, async (path, side) => {
        const bytes = await fetchBlob(client, owner, repo, path, side === 'base' ? refs.baseSha : refs.headSha);
        return bytes ? new TextDecoder().decode(bytes) : null;
      });
      return { refs, files, guidIndex };
    })();
    contexts.set(key, { at: Date.now(), ctx });
    ctx.catch(() => contexts.delete(key)); // 失敗はキャッシュしない
    return ctx;
  }

  return async function handle(req) {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return { ok: false, error: 'pat-missing' };
      const base = apiBase(settings.baseUrl);
      const client = deps.makeClient(base, settings.pat);
      const { refs, files, guidIndex } = await loadContext(client, req.owner, req.repo, req.prNumber);

      const file = files.find((f) => f.path === req.path);
      const status = file?.status ?? 'modified';
      const beforePath = file?.previousPath ?? req.path;

      const before =
        status === 'added' ? EMPTY : ((await fetchBlob(client, req.owner, req.repo, beforePath, refs.baseSha)) ?? EMPTY);
      const after =
        status === 'removed' ? EMPTY : ((await fetchBlob(client, req.owner, req.repo, req.path, refs.headSha)) ?? EMPTY);

      const differ = await deps.getDiffer();
      const json = differ.diff(before, after);
      const withPr = applyResolved(json, guidIndex);
      return { ok: true, json: await searchUnresolved(withPr, client, req.owner, req.repo, `${base}/${req.owner}/${req.repo}`) };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: 'rate-limited' };
      if (err instanceof AuthError) return { ok: false, error: 'auth-failed' };
      if (err instanceof DiffError) return { ok: false, error: 'diff-failed' };
      return { ok: false, error: 'fetch-failed' }; // raw エラーは応答に載せない
    }
  };
}
