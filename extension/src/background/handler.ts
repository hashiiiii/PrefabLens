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
const MAX_SOURCE_ROUNDS = 3; // 入れ子ソースの再 diff 上限(core 側の深さ上限 8 とは独立)
const CONTEXT_TTL_MS = 60_000; // push で headSha が変わるため PR コンテキストは短命
const BLOB_CACHE_MAX = 32;
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // 親仕様 §5.7: 25MB 超はクリックで描画

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
    // hasOwn: guid は任意文字列なので 'constructor' 等が Object.prototype に誤ヒットしない(cached も同様)
    const pending = json.unresolvedGuids.filter((g) => !Object.hasOwn(resolved, g) && !misses.has(`${repoKey}:${g}`));
    if (!pending.length) return { ...json, resolved };
    const cached = await deps.guidCache.load(repoKey);
    const unknown: string[] = [];
    for (const g of pending) {
      if (Object.hasOwn(cached, g)) resolved[g] = cached[g]!;
      else unknown.push(g);
    }
    const found: Record<string, string> = {};
    for (const g of unknown.slice(0, MAX_SEARCHES)) {
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

  /** neededSources(added/removed instance のソース prefab)を resolved パス経由で
   *  取得し、assets を添えて再 diff する。ソース guid は m_SourcePrefab 参照として
   *  unresolvedGuids に載るため、パス解決は searchUnresolved が済ませている。
   *  解決・取得・合成の失敗はその時点の diff で縮退する(全体は落とさない)。 */
  async function mergeSources(
    first: DiffV2,
    differ: Differ,
    before: Uint8Array,
    after: Uint8Array,
    ctx: PrContext,
    client: ClientLike,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<DiffV2> {
    const assets = new Map<string, Uint8Array>();
    let current = first;
    for (let round = 0; round < MAX_SOURCE_ROUNDS; round++) {
      const needed = (current.neededSources ?? []).filter((s) => !assets.has(s.guid));
      if (!needed.length) break;
      let progressed = false;
      for (const s of needed) {
        const path = current.resolved?.[s.guid];
        if (path === undefined) continue;
        const sha = s.side === 'before' ? ctx.refs.baseSha : ctx.refs.headSha;
        let bytes: Uint8Array | null = null;
        try {
          bytes = await fetchBlob(client, owner, repo, path, sha);
        } catch {
          return current; // rate limit 等: phase 1 の結果で縮退表示
        }
        if (!bytes) continue;
        assets.set(s.guid, bytes);
        progressed = true;
      }
      if (!progressed) break;
      let merged: DiffV2;
      try {
        merged = differ.diffWithAssets(before, after, assets);
      } catch {
        return current; // 合成失敗はその時点の結果で縮退
      }
      // 合成でソース内の外部参照(script/material)が新たに現れるので解決し直す。
      current = await searchUnresolved(applyResolved(merged, ctx.guidIndex), client, owner, repo, repoKey);
    }
    return current;
  }

  function loadContext(client: ClientLike, owner: string, repo: string, prNumber: number): Promise<PrContext> {
    const key = `${owner}/${repo}#${prNumber}`;
    const entry = contexts.get(key);
    if (entry && Date.now() - entry.at < CONTEXT_TTL_MS) return entry.ctx;
    const ctx = (async () => {
      const [refs, files] = await Promise.all([
        client.getPrRefs(owner, repo, prNumber),
        client.listPrFiles(owner, repo, prNumber),
      ]);
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
      // 一覧に無い場合(files API は 3000 件で打ち切り)は modified 扱い: 無い側は 404 → EMPTY に落ちるだけ
      const status = file?.status ?? 'modified';
      const beforePath = file?.previousPath ?? req.path;

      const fetchSide = (path: string, sha: string) =>
        fetchBlob(client, req.owner, req.repo, path, sha).then((bytes) => bytes ?? EMPTY);
      const [before, after] = await Promise.all([
        status === 'added' ? EMPTY : fetchSide(beforePath, refs.baseSha),
        status === 'removed' ? EMPTY : fetchSide(req.path, refs.headSha),
      ]);

      if (!req.force && before.length + after.length > TOO_LARGE_BYTES) {
        return { ok: false, error: 'too-large', bytes: before.length + after.length };
      }

      const differ = await deps.getDiffer();
      const repoKey = `${base}/${req.owner}/${req.repo}`;
      const json = differ.diff(before, after);
      const withPr = applyResolved(json, guidIndex);
      const first = await searchUnresolved(withPr, client, req.owner, req.repo, repoKey);
      const ctx = { refs, files, guidIndex };
      return { ok: true, json: await mergeSources(first, differ, before, after, ctx, client, req.owner, req.repo, repoKey) };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: 'rate-limited' };
      if (err instanceof AuthError) return { ok: false, error: 'auth-failed' };
      if (err instanceof DiffError) return { ok: false, error: 'diff-failed' };
      return { ok: false, error: 'fetch-failed' }; // raw エラーは応答に載せない
    }
  };
}
