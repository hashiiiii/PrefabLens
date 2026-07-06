import { AuthError, RateLimitError, apiBase, type GithubClient, type PrFile, type PrRefs } from '../github/client';
import { applyResolved, buildGuidIndex, type GuidCache } from '../github/guids';
import { syncRepoIndex, type RepoIndexStore } from '../github/repoIndex';
import { DiffError, type Differ } from '../wasm/differ';
import { isUnityPath } from '../unity';
import type { DiffV2, GuidResolvedPush, PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from '../types';

type ClientLike = Pick<
  GithubClient,
  'getPrRefs' | 'listPrFiles' | 'getFileAtRef' | 'searchMetaByGuid' | 'listMetaTree' | 'batchBlobTexts'
>;

export type Deps = {
  getSettings(): Promise<{ pat?: string; baseUrl?: string }>;
  makeClient(base: string, token: string, lane: 'user' | 'prefetch'): ClientLike;
  getDiffer(): Promise<Differ>;
  guidCache: GuidCache;
  diffStore: { load(key: string): Promise<DiffV2 | undefined>; save(key: string, json: DiffV2): Promise<void> };
  repoIndexStore: RepoIndexStore;
};

export type Handler = {
  semanticDiff(req: SemanticDiffRequest, push?: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};

type PrContext = { refs: PrRefs; files: PrFile[]; guidIndex: Map<string, string> };

const EMPTY = new Uint8Array(0);
const MAX_SEARCHES = 10; // Code Search は認証済み 10 req/min — 1 応答で使い切らない
const MAX_SOURCE_ROUNDS = 3; // 入れ子ソースの再 diff 上限(core 側の深さ上限 8 とは独立)
const CONTEXT_TTL_MS = 60_000; // push で headSha が変わるため PR コンテキストは短命
const BLOB_CACHE_MAX = 32;
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // 親仕様 §5.7: 25MB 超はクリックで描画
const PREFETCH_MAX = 100; // spec B2: 1 PR あたりの先読み上限
const PREFETCH_CONCURRENCY = 4;

type DiffOutcome = { ok: true; json: DiffV2 } | { ok: false; error: 'too-large'; bytes: number };

export function createHandler(deps: Deps): Handler {
  // PR 単位のコンテキストキャッシュ。SW はいつ殺されてもよく、その場合は再取得するだけ。
  const contexts = new Map<string, { at: number; ctx: Promise<PrContext> }>();
  // sha+path → bytes の Promise。格納が Promise なので prefetch と手動トグルの同時要求が 1 フェッチに畳まれる。
  const blobs = new Map<string, Promise<Uint8Array | null>>();
  // Code Search の未ヒット guid。索引遅延があるため永続化せず SW 生存期間のみ
  const misses = new Set<string>();
  // baseSha:headSha:path → raw diff 計算の Promise。成功のみ保持(too-large/失敗は再計算を許す)
  const diffs = new Map<string, Promise<DiffOutcome>>();
  // repoKey@ref → repo 全体索引の Promise(Task 11)。null は索引不可(truncated/上限超/失敗)
  const indexes = new Map<string, Promise<Record<string, string> | null>>();
  // レート制限を踏んだ repo は SW 生存期間フォールバック(索引を諦めて Code Search のみに委ねる)
  const indexFallback = new Set<string>();

  /** guid[] をキャッシュ → Code Search の順で解決する(searchUnresolved の中身そのもの)。
   *  検索の失敗(レート制限含む)で diff は落とさない: 解決できた分だけ返す。 */
  async function searchGuids(guids: string[], client: ClientLike, owner: string, repo: string, repoKey: string): Promise<Record<string, string>> {
    // hasOwn: guid は任意文字列なので 'constructor' 等が Object.prototype に誤ヒットしない(cached も同様)
    const pending = guids.filter((g) => !misses.has(`${repoKey}:${g}`));
    if (!pending.length) return {};
    const cached = await deps.guidCache.load(repoKey);
    const resolved: Record<string, string> = {};
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
    return resolved;
  }

  /** PR 内 .meta で解決できなかった guid を キャッシュ → Code Search の順で解決する薄いラッパ。
   *  mergeSources が内部で呼ぶため、シグネチャと挙動を変えない。 */
  async function searchUnresolved(json: DiffV2, client: ClientLike, owner: string, repo: string, repoKey: string): Promise<DiffV2> {
    const resolved = { ...json.resolved };
    const pending = json.unresolvedGuids.filter((g) => !Object.hasOwn(resolved, g));
    const found = await searchGuids(pending, client, owner, repo, repoKey);
    return { ...json, resolved: { ...resolved, ...found } };
  }

  /** repo 全体の guid 索引を取得・メモ化する。レート制限を踏んだ repo は SW 生存期間フォールバック固定。 */
  function getRepoIndex(client: ClientLike, owner: string, repo: string, repoKey: string, ref: string): Promise<Record<string, string> | null> {
    if (indexFallback.has(repoKey)) return Promise.resolve(null);
    const key = `${repoKey}@${ref}`;
    const hit = indexes.get(key);
    if (hit) return hit;
    const p = syncRepoIndex(client, deps.repoIndexStore, owner, repo, repoKey, ref).catch((err: unknown) => {
      indexes.delete(key); // 失敗はキャッシュしない: 次回訪問で再試行
      if (err instanceof RateLimitError) indexFallback.add(repoKey);
      return null;
    });
    indexes.set(key, p);
    return p;
  }

  async function fetchBlob(client: ClientLike, owner: string, repo: string, path: string, sha: string): Promise<Uint8Array | null> {
    const key = `${sha}:${path}`;
    const hit = blobs.get(key); // 格納値は Promise<Uint8Array | null> なので undefined = 未キャッシュ
    if (hit !== undefined) return hit;
    const p = client.getFileAtRef(owner, repo, path, sha);
    p.catch(() => blobs.delete(key)); // 失敗は残さない: 次回呼び出しで再フェッチできる
    blobs.set(key, p);
    if (blobs.size > BLOB_CACHE_MAX) blobs.delete(blobs.keys().next().value!);
    return p;
  }

  /** before/after の blob を取り出す(status/previousPath の規則は files API 準拠)。 */
  async function fetchPair(client: ClientLike, ctx: PrContext, owner: string, repo: string, path: string): Promise<[Uint8Array, Uint8Array]> {
    const file = ctx.files.find((f) => f.path === path);
    const status = file?.status ?? 'modified';
    const beforePath = file?.previousPath ?? path;
    const fetchSide = (p: string, sha: string): Promise<Uint8Array> =>
      fetchBlob(client, owner, repo, p, sha).then((bytes) => bytes ?? EMPTY);
    return Promise.all([
      status === 'added' ? Promise.resolve(EMPTY) : fetchSide(beforePath, ctx.refs.baseSha),
      status === 'removed' ? Promise.resolve(EMPTY) : fetchSide(path, ctx.refs.headSha),
    ]);
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

  /** blob 取得 → 25MB ガード → 素の diff まで。解決や mergeSources はここに入れない
   *  (resolved は Code Search で後から良くなるため、sha だけで決まる raw diff がキャッシュ単位)。 */
  async function computeDiff(client: ClientLike, ctx: PrContext, owner: string, repo: string, path: string, force: boolean): Promise<DiffOutcome> {
    // 一覧に無い場合(files API は 3000 件で打ち切り)は modified 扱い: 無い側は 404 → EMPTY に落ちるだけ(fetchPair 側の規則)
    const [before, after] = await fetchPair(client, ctx, owner, repo, path);
    if (!force && before.length + after.length > TOO_LARGE_BYTES) {
      return { ok: false, error: 'too-large', bytes: before.length + after.length };
    }
    const differ = await deps.getDiffer();
    return { ok: true, json: differ.diff(before, after) };
  }

  /** sha キーなので push されたら自然に別キーになる(無効化不要)。 */
  function getDiff(client: ClientLike, ctx: PrContext, owner: string, repo: string, path: string, force: boolean): Promise<DiffOutcome> {
    const key = `${ctx.refs.baseSha}:${ctx.refs.headSha}:${path}`;
    const hit = diffs.get(key);
    if (hit) return hit;
    const p = (async (): Promise<DiffOutcome> => {
      const stored = await deps.diffStore.load(key); // 前世の SW が残した結果
      if (stored) return { ok: true, json: stored };
      const outcome = await computeDiff(client, ctx, owner, repo, path, force);
      if (outcome.ok) void deps.diffStore.save(key, outcome.json);
      return outcome;
    })();
    diffs.set(key, p);
    p.then((o) => {
      if (!o.ok) diffs.delete(key); // too-large は force 再計算を許す
    }, () => diffs.delete(key));
    return p;
  }

  /** 3 段解決の続き(索引 → Code Search)とソース再合成を裏で走らせ、push で結果を届ける。
   *  push 無しの互換経路とは異なり、失敗しても catch で done push を出して待ち手を解放する。 */
  async function resolveRemaining(
    first: DiffV2,
    remaining: string[],
    client: ClientLike,
    req: SemanticDiffRequest,
    base: string,
    ctx: PrContext,
    push: (msg: GuidResolvedPush) => void,
  ): Promise<void> {
    const repoKey = `${base}/${req.owner}/${req.repo}`;
    const at = { owner: req.owner, repo: req.repo, prNumber: req.prNumber, path: req.path };
    try {
      const index = await getRepoIndex(client, req.owner, req.repo, repoKey, ctx.refs.headSha);
      const fromIndex: Record<string, string> = {};
      let leftover = remaining;
      if (index) {
        for (const g of remaining) if (Object.hasOwn(index, g)) fromIndex[g] = index[g]!;
        leftover = remaining.filter((g) => !Object.hasOwn(fromIndex, g));
        if (Object.keys(fromIndex).length) {
          // guidCache にも載せる: mergeSources 内部の searchUnresolved は applyResolved で
          // resolved を ctx.guidIndex ベースに作り直すため、guidCache 経由でないと索引由来の
          // 解決がソース再合成後に消える(Code Search 由来が既にこの経路で復元されるのと同じ理屈)。
          await deps.guidCache.save(repoKey, fromIndex);
          // 名前が既に出せる分は先に届ける(構造は後続の最終 push で確定)
          push({ type: 'guidResolved', ...at, resolved: fromIndex, done: false });
        }
      }
      // 索引不可、または索引に無い guid だけが Code Search に回る(spec B3 の 3 段目)
      const fromSearch = leftover.length ? await searchGuids(leftover, client, req.owner, req.repo, repoKey) : {};
      let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...fromSearch } };
      if (json.neededSources?.length) {
        // 解決が進んだのでソース合成をやり直す(ソース guid が今回解けたケースを拾う)
        const differ = await deps.getDiffer();
        const [before, after] = await fetchPair(client, ctx, req.owner, req.repo, req.path);
        json = await mergeSources(json, differ, before, after, ctx, client, req.owner, req.repo, repoKey);
      }
      push({ type: 'guidResolved', ...at, resolved: {}, json, done: true }); // 最終 push は json 置換
    } catch (err) {
      console.debug('prefablens: guid resolution aborted', err);
      push({ type: 'guidResolved', ...at, resolved: {}, done: true });
    }
  }

  async function semanticDiff(req: SemanticDiffRequest, push?: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse> {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return { ok: false, error: 'pat-missing' };
      const base = apiBase(settings.baseUrl);
      const client = deps.makeClient(base, settings.pat, 'user');
      const ctx = await loadContext(client, req.owner, req.repo, req.prNumber);
      const outcome = await getDiff(client, ctx, req.owner, req.repo, req.path, req.force === true);
      if (!outcome.ok) return outcome;
      const repoKey = `${base}/${req.owner}/${req.repo}`;
      const withPr = applyResolved(outcome.json, ctx.guidIndex);

      if (!push) {
        // 互換経路: 従来の同期フルパイプライン(既存テスト・呼び出しの挙動を変えない)
        const first = await searchUnresolved(withPr, client, req.owner, req.repo, repoKey);
        if (!first.neededSources?.length) return { ok: true, json: first };
        const differ = await deps.getDiffer();
        const [before, after] = await fetchPair(client, ctx, req.owner, req.repo, req.path);
        return { ok: true, json: await mergeSources(first, differ, before, after, ctx, client, req.owner, req.repo, repoKey) };
      }

      // 2 段階経路: diff は即返し、解決とソース合成は裏で続けて push で届ける(B4)
      const remaining = withPr.unresolvedGuids.filter((g) => !Object.hasOwn(withPr.resolved ?? {}, g));
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolveRemaining(withPr, remaining, client, req, base, ctx, push);
      return { ok: true, json: withPr, pending: true };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: 'rate-limited' };
      if (err instanceof AuthError) return { ok: false, error: 'auth-failed' };
      if (err instanceof DiffError) return { ok: false, error: 'diff-failed' };
      return { ok: false, error: 'fetch-failed' }; // raw エラーは応答に載せない
    }
  }

  /** raw diff のプリコンピュートのみ。resolve/search/mergeSources は行わない
   *  — Code Search は 10 req/min の希少資源で、mergeSources は解決結果依存のため serve 時に任せる。 */
  async function prefetch(req: PrefetchRequest): Promise<void> {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return;
      const base = apiBase(settings.baseUrl);
      const client = deps.makeClient(base, settings.pat, 'prefetch');
      const ctx = await loadContext(client, req.owner, req.repo, req.prNumber);
      // raw diff の先読みとは独立に走らせる(索引 sync は serve 時の 3 段解決を高速化する)
      void getRepoIndex(client, req.owner, req.repo, `${base}/${req.owner}/${req.repo}`, ctx.refs.headSha);
      const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
      for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map((f) =>
            getDiff(client, ctx, req.owner, req.repo, f.path, false).catch((err) => {
              if (err instanceof RateLimitError) throw err; // レート制限だけは全体を止める
              // ファイル単位の失敗は握りつぶす: 手動トグル時に改めてエラー表示される
            }),
          ),
        );
      }
    } catch (err) {
      // プリフェッチは静かに諦める。エラー UI はユーザー操作経路だけが出す
      console.debug('prefablens: prefetch aborted', err);
    }
  }

  return { semanticDiff, prefetch };
}
