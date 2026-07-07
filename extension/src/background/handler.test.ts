import { describe, expect, it, vi } from 'vitest';
import { createHandler, type Deps, type Handler } from './handler';
import { AuthError, RateLimitError, type PrFile } from '../github/client';
import { DiffError, type Differ } from '../wasm/differ';
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest } from '../types';

const REQ: SemanticDiffRequest = { type: 'semanticDiff', owner: 'o', repo: 'r', prNumber: 1, path: 'Assets/Foo.prefab' };

const DIFF: DiffV2 = { schema: 'prefablens.diff.v2', unresolvedGuids: ['g1'], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: PrFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  diff?: Differ['diff'];
  diffWithAssets?: Differ['diffWithAssets'];
  pat?: string | undefined;
  search?: Record<string, string | null>; // guid → asset path(null = 未ヒット)
  cached?: Record<string, string>; // guidCache の初期内容
}) {
  const files = overrides?.files ?? [{ path: 'Assets/Foo.prefab', status: 'modified' }];
  const contents = overrides?.contents ?? { 'Assets/Foo.prefab@base-sha': 'b', 'Assets/Foo.prefab@head-sha': 'a' };
  const getFileAtRef = vi.fn(async (_o: string, _r: string, path: string, ref: string) => {
    const text = contents[`${path}@${ref}`];
    return text === undefined ? null : new TextEncoder().encode(text);
  });
  const client = {
    getPrRefs: vi.fn(async () => ({ baseSha: 'base-sha', headSha: 'head-sha' })),
    listPrFiles: vi.fn(async () => files),
    getFileAtRef,
    searchMetaByGuid: vi.fn(async (_o: string, _r: string, guid: string) => overrides?.search?.[guid] ?? null),
    listMetaTree: vi.fn(async (): Promise<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }> => ({
      truncated: false,
      metas: [],
    })),
    batchBlobTexts: vi.fn(async (): Promise<Record<string, string | null>> => ({})),
  };
  const differ: Differ = {
    diff: overrides?.diff ?? vi.fn(() => DIFF),
    diffWithAssets: overrides?.diffWithAssets ?? vi.fn(() => DIFF),
  };
  const cacheData: Record<string, Record<string, string>> = {};
  if (overrides?.cached) cacheData['https://api.github.com/o/r'] = { ...overrides.cached };
  const guidCache = {
    data: cacheData,
    load: vi.fn(async (repo: string) => cacheData[repo] ?? {}),
    save: vi.fn(async (repo: string, entries: Record<string, string>) => {
      cacheData[repo] = { ...cacheData[repo], ...entries };
    }),
  };
  const diffStoreData: Record<string, DiffV2> = {};
  const diffStore = {
    data: diffStoreData,
    load: vi.fn(async (key: string) => diffStoreData[key]),
    save: vi.fn(async (key: string, json: DiffV2) => {
      diffStoreData[key] = json;
    }),
  };
  // Task 11 の makeFakes と同型(loadGuids/saveGuids/loadIndex/saveIndex)。テストごとに空で始まる。
  const guidsData: Record<string, Record<string, string>> = {};
  const indexData: Record<string, { treeSha: string; guids: Record<string, string> }> = {};
  const repoIndexStore = {
    loadGuids: vi.fn(async (repo: string) => guidsData[repo] ?? {}),
    saveGuids: vi.fn(async (repo: string, entries: Record<string, string>) => {
      guidsData[repo] = { ...guidsData[repo], ...entries };
    }),
    loadIndex: vi.fn(async (repo: string) => indexData[repo]),
    saveIndex: vi.fn(async (repo: string, index: { treeSha: string; guids: Record<string, string> }) => {
      indexData[repo] = index;
    }),
  };
  const deps: Deps = {
    getSettings: async () => ({ pat: Object.hasOwn(overrides ?? {}, 'pat') ? overrides!.pat : 'tok', baseUrl: undefined }),
    makeClient: (_base: string, _token: string, _lane: 'user' | 'prefetch') => client,
    getDiffer: async () => differ,
    guidCache,
    diffStore,
    repoIndexStore,
  };
  return { deps, client, differ, guidCache, diffStore, repoIndexStore };
}

/** pending 応答の後始末: done push が来るまで待ってから検証する。 */
async function serveAndResolve(
  handler: Handler,
  req: SemanticDiffRequest,
): Promise<{ res: Awaited<ReturnType<Handler['semanticDiff']>>; pushes: GuidResolvedPush[] }> {
  const pushes: GuidResolvedPush[] = [];
  const res = await handler.semanticDiff(req, (m) => pushes.push(m));
  if (res.ok && res.pending) await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  return { res, pushes };
}

describe('createHandler', () => {
  it('returns pat-missing without touching the network', async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: false, error: 'pat-missing' });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });

  it('diffs base/head blobs and attaches resolved guids', async () => {
    const { deps } = makeDeps({
      files: [
        { path: 'Assets/Foo.prefab', status: 'modified' },
        { path: 'Assets/S.cs.meta', status: 'modified' },
      ],
      contents: {
        'Assets/Foo.prefab@base-sha': 'b',
        'Assets/Foo.prefab@head-sha': 'a',
        'Assets/S.cs.meta@head-sha': 'guid: g1\n',
      },
    });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
  });

  it('uses an empty before for added files without fetching the base side', async () => {
    const diff = vi.fn<Differ['diff']>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'added' }], diff });
    await createHandler(deps).semanticDiff(REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'base-sha',
    );
    expect(baseFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[0]).toHaveLength(0); // before は空
  });

  it('uses an empty after for removed files without fetching the head side', async () => {
    const diff = vi.fn<Differ['diff']>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'removed' }], diff });
    await createHandler(deps).semanticDiff(REQ);
    const headFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'head-sha',
    );
    expect(headFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[1]).toHaveLength(0); // after は空
  });

  it('diffs a file missing from the PR list as modified (files API caps at 3000)', async () => {
    // 3000 ファイル超の PR では一覧 API が打ち切られ、UI にあるファイルが一覧に無いことがある
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Other.prefab', status: 'modified' }] });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Foo.prefab', 'base-sha');
    expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Foo.prefab', 'head-sha');
  });

  it('fetches the base and head blobs in parallel', async () => {
    // 初回トグルのレイテンシは blob フェッチ 2 本が支配的なので、直列化への退行を固定する
    let inFlight = 0;
    let maxInFlight = 0;
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockImplementation(async () => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 0));
      inFlight--;
      return new TextEncoder().encode('x');
    });
    await createHandler(deps).semanticDiff(REQ);
    expect(maxInFlight).toBe(2);
  });

  it('reads renamed files from previousPath on the base side', async () => {
    const { deps, client } = makeDeps({
      files: [{ path: 'Assets/Foo.prefab', status: 'renamed', previousPath: 'Assets/Old.prefab' }],
      contents: { 'Assets/Old.prefab@base-sha': 'b', 'Assets/Foo.prefab@head-sha': 'a' },
    });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Old.prefab', 'base-sha');
  });

  it('caches PR context across calls (refs/files/guid index fetched once)', async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await handle.semanticDiff(REQ);
    await handle.semanticDiff({ ...REQ, path: 'Assets/Foo.prefab' });
    expect(client.getPrRefs).toHaveBeenCalledTimes(1);
    expect(client.listPrFiles).toHaveBeenCalledTimes(1);
  });

  it('refreshes PR context after 60s so new pushes are picked up', async () => {
    vi.useFakeTimers();
    try {
      const { deps, client } = makeDeps();
      const handle = createHandler(deps);
      await handle.semanticDiff(REQ);
      vi.setSystemTime(Date.now() + 59_000);
      await handle.semanticDiff(REQ);
      expect(client.getPrRefs).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 2_000); // 計 61 秒
      await handle.semanticDiff(REQ);
      expect(client.getPrRefs).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it('retries the PR context after a failed load instead of caching the failure', async () => {
    // 一時的なネットワーク失敗が 60 秒キャッシュに乗ると、再トグルしても直らなくなる
    const { deps, client } = makeDeps();
    client.listPrFiles.mockRejectedValueOnce(new Error('socket'));
    const handle = createHandler(deps);
    expect(await handle.semanticDiff(REQ)).toEqual({ ok: false, error: 'fetch-failed' });
    expect((await handle.semanticDiff(REQ)).ok).toBe(true);
  });

  it('fetches each sha+path blob only once (immutable content)', async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await handle.semanticDiff(REQ);
    await handle.semanticDiff(REQ);
    const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === 'Assets/Foo.prefab');
    expect(fooFetches).toHaveLength(2); // base + head の 2 回だけ(2 回目の handle では再フェッチしない)
  });

  it('resolves remaining guids via code search and persists them', async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: 'Assets/Scripts/S.cs' } });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/Scripts/S.cs' } } });
    expect(guidCache.save).toHaveBeenCalledWith('https://api.github.com/o/r', { g1: 'Assets/Scripts/S.cs' });
  });

  it('prefers the in-PR meta index over code search', async () => {
    const { deps, client } = makeDeps({
      files: [
        { path: 'Assets/Foo.prefab', status: 'modified' },
        { path: 'Assets/S.cs.meta', status: 'modified' },
      ],
      contents: {
        'Assets/Foo.prefab@base-sha': 'b',
        'Assets/Foo.prefab@head-sha': 'a',
        'Assets/S.cs.meta@head-sha': 'guid: g1\n',
      },
      search: { g1: 'Assets/Elsewhere.cs' },
    });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it('serves cached guids without searching', async () => {
    const { deps, client } = makeDeps({ cached: { g1: 'Assets/Cached.cs' } });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/Cached.cs' } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it('does not re-search a missed guid within the worker lifetime', async () => {
    const { deps, client } = makeDeps(); // search 未ヒット
    const handle = createHandler(deps);
    await handle.semanticDiff(REQ);
    await handle.semanticDiff(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it('serves cached names even for guids that once missed in code search', async () => {
    // 索引解決が guidCache に入る設計になったため、miss 記録済み guid がキャッシュに現れるケースが実在する。
    // misses は「再検索しない」の門番であって「名前を出さない」の門番ではない
    const { deps, client, guidCache } = makeDeps(); // search 未ヒット → g1 が misses に入る
    const handler = createHandler(deps);
    await handler.semanticDiff(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    guidCache.data['https://api.github.com/o/r'] = { g1: 'Assets/Later.cs' }; // 索引解決が後から書いた体
    const res = await handler.semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/Later.cs' } } });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1); // 再検索はしない
  });

  it('dedupes concurrent code searches for the same guid', async () => {
    // semantic 既定では複数ファイルが同時に解決を走らせる: 同一 guid の検索は 1 回に畳む
    const { deps, client } = makeDeps({ search: { g1: 'Assets/S.cs' } });
    let release!: (v: string) => void;
    client.searchMetaByGuid.mockImplementation(() => new Promise((r) => { release = r; }));
    const handler = createHandler(deps);
    const [a, b] = [handler.semanticDiff(REQ), handler.semanticDiff(REQ)];
    await vi.waitFor(() => expect(client.searchMetaByGuid).toHaveBeenCalled());
    release('Assets/S.cs');
    const [ra, rb] = await Promise.all([a, b]);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(ra).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
    expect(rb).toEqual(ra);
  });

  it('keeps the diff usable when code search hits the rate limit', async () => {
    const twoGuids: DiffV2 = { ...DIFF, unresolvedGuids: ['g1', 'g2'] };
    const { deps, client } = makeDeps({ diff: () => twoGuids });
    client.searchMetaByGuid
      .mockResolvedValueOnce('Assets/First.cs')
      .mockRejectedValueOnce(new RateLimitError('x'));
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res).toEqual({ ok: true, json: { ...twoGuids, resolved: { g1: 'Assets/First.cs' } } });
  });

  it('does not treat Object.prototype members as cache hits (hostile guid)', async () => {
    const proto: DiffV2 = { ...DIFF, unresolvedGuids: ['constructor'] };
    const { deps, client } = makeDeps({ diff: () => proto, cached: { g9: 'Assets/X.cs' } });
    const res = await createHandler(deps).semanticDiff(REQ);
    // 'constructor' はキャッシュヒットではなく検索に回り、未ヒットで未解決のまま
    expect(client.searchMetaByGuid).toHaveBeenCalledWith('o', 'r', 'constructor');
    expect(res).toEqual({ ok: true, json: { ...proto, resolved: {} } });
  });

  it('caps code searches at 10 per request', async () => {
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many });
    await createHandler(deps).semanticDiff(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
  });

  it('does not count cached guids against the search cap', async () => {
    // 12 guid 中 2 つがキャッシュ済みなら、検索枠 10 は未知の 10 guid にまるごと使える
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many, cached: { g0: 'Assets/A.cs', g1: 'Assets/B.cs' } });
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
    expect(res).toEqual({ ok: true, json: { ...many, resolved: { g0: 'Assets/A.cs', g1: 'Assets/B.cs' } } });
  });

  it('maps AuthError / DiffError / other failures to stable error codes', async () => {
    const auth = makeDeps();
    auth.client.getPrRefs.mockRejectedValue(new AuthError('x'));
    expect(await createHandler(auth.deps).semanticDiff(REQ)).toEqual({ ok: false, error: 'auth-failed' });

    const bad = makeDeps({
      diff: () => {
        throw new DiffError('NestingTooDeep');
      },
    });
    expect(await createHandler(bad.deps).semanticDiff(REQ)).toEqual({ ok: false, error: 'diff-failed' });

    const net = makeDeps();
    net.client.listPrFiles.mockRejectedValue(new Error('socket'));
    expect(await createHandler(net.deps).semanticDiff(REQ)).toEqual({ ok: false, error: 'fetch-failed' });
  });

  it('returns too-large above 25MB unless forced', async () => {
    const big = new Uint8Array(13 * 1024 * 1024); // base+head で 26MB
    const diff = vi.fn(() => DIFF);
    const { deps, client } = makeDeps({ diff });
    client.getFileAtRef.mockResolvedValue(big);
    const handle = createHandler(deps);
    expect(await handle.semanticDiff(REQ)).toEqual({ ok: false, error: 'too-large', bytes: big.length * 2 });
    expect(diff).not.toHaveBeenCalled();
    // force で描画に進む。blob は sha キャッシュに乗っており再フェッチもない
    const fetches = client.getFileAtRef.mock.calls.length;
    expect((await handle.semanticDiff({ ...REQ, force: true })).ok).toBe(true);
    expect(diff).toHaveBeenCalledTimes(1);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetches);
  });

  it('renders exactly 25MB without the gate', async () => {
    const half = new Uint8Array((25 * 1024 * 1024) / 2);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(half);
    expect((await createHandler(deps).semanticDiff(REQ)).ok).toBe(true);
  });

  it('maps RateLimitError to rate-limited', async () => {
    const limited = makeDeps();
    limited.client.getPrRefs.mockRejectedValue(new RateLimitError('x'));
    expect(await createHandler(limited.deps).semanticDiff(REQ)).toEqual({ ok: false, error: 'rate-limited' });
  });

  describe('source prefab merging', () => {
    // phase 1 がソース供給を要求する diff。src1 のパスは Code Search で解決される。
    const NEEDS: DiffV2 = {
      ...DIFF,
      unresolvedGuids: ['src1'],
      neededSources: [{ guid: 'src1', side: 'after' }],
    };
    const MERGED: DiffV2 = { schema: 'prefablens.diff.v2', unresolvedGuids: ['src1'], roots: [], loose: [] };

    it('fetches the resolved source at head and re-diffs with assets', async () => {
      const diffWithAssets = vi.fn<Differ['diffWithAssets']>(() => MERGED);
      const { deps, client } = makeDeps({
        diff: () => NEEDS,
        diffWithAssets,
        search: { src1: 'Assets/Cyl.prefab' },
        contents: {
          'Assets/Foo.prefab@base-sha': 'b',
          'Assets/Foo.prefab@head-sha': 'a',
          'Assets/Cyl.prefab@head-sha': 'SRC',
        },
      });
      const res = await createHandler(deps).semanticDiff(REQ);
      // side=after なので head からソースを取り、その bytes が assets に載る。
      expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Cyl.prefab', 'head-sha');
      const assets = diffWithAssets.mock.calls[0]![2];
      expect(new TextDecoder().decode(assets.get('src1')!)).toBe('SRC');
      // 再 diff 後も resolved は guidCache から復元されて残る。
      expect(res).toEqual({ ok: true, json: { ...MERGED, resolved: { src1: 'Assets/Cyl.prefab' } } });
    });

    it('fetches removed-instance sources from the base side', async () => {
      const diffWithAssets = vi.fn<Differ['diffWithAssets']>(() => MERGED);
      const { deps, client } = makeDeps({
        diff: () => ({ ...NEEDS, neededSources: [{ guid: 'src1', side: 'before' }] }),
        diffWithAssets,
        search: { src1: 'Assets/Cyl.prefab' },
        contents: {
          'Assets/Foo.prefab@base-sha': 'b',
          'Assets/Foo.prefab@head-sha': 'a',
          'Assets/Cyl.prefab@base-sha': 'OLD',
        },
      });
      await createHandler(deps).semanticDiff(REQ);
      expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Cyl.prefab', 'base-sha');
    });

    it('keeps the phase-1 diff when the source path cannot be resolved', async () => {
      const diffWithAssets = vi.fn<Differ['diffWithAssets']>(() => MERGED);
      const { deps } = makeDeps({ diff: () => NEEDS, diffWithAssets }); // search 未ヒット
      const res = await createHandler(deps).semanticDiff(REQ);
      // パス不明のソースは諦め、縮退表示(phase 1 の json)のまま返す。
      expect(diffWithAssets).not.toHaveBeenCalled();
      expect(res).toEqual({ ok: true, json: { ...NEEDS, resolved: {} } });
    });

    it('does not loop when the merged output still needs the same source', async () => {
      // 供給しても縮退したまま(壊れたソース等)の場合、同じ guid で無限に回らない。
      const diffWithAssets = vi.fn<Differ['diffWithAssets']>(() => NEEDS);
      const { deps } = makeDeps({
        diff: () => NEEDS,
        diffWithAssets,
        search: { src1: 'Assets/Cyl.prefab' },
        contents: {
          'Assets/Foo.prefab@base-sha': 'b',
          'Assets/Foo.prefab@head-sha': 'a',
          'Assets/Cyl.prefab@head-sha': 'SRC',
        },
      });
      const res = await createHandler(deps).semanticDiff(REQ);
      expect(diffWithAssets).toHaveBeenCalledTimes(1);
      expect(res.ok).toBe(true);
    });

    it('still merges sources when serving a prefetched diff', async () => {
      // raw diff だけをキャッシュする設計の要: 後段(resolve → mergeSources)はキャッシュヒットでも毎回走る
      const withSource: DiffV2 = { ...DIFF, unresolvedGuids: ['src1'], neededSources: [{ guid: 'src1', side: 'after' }] };
      const merged: DiffV2 = { ...DIFF, unresolvedGuids: ['src1'] };
      const diffWithAssets = vi.fn(() => merged);
      const { deps, client } = makeDeps({
        files: [
          { path: 'Assets/Foo.prefab', status: 'modified' },
          { path: 'Assets/Src.prefab.meta', status: 'modified' },
        ],
        contents: {
          'Assets/Foo.prefab@base-sha': 'b',
          'Assets/Foo.prefab@head-sha': 'a',
          'Assets/Src.prefab.meta@head-sha': 'guid: src1\n',
          'Assets/Src.prefab@head-sha': 'source prefab',
        },
        diff: () => withSource,
        diffWithAssets,
      });
      const handler = createHandler(deps);
      await handler.prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
      expect(diffWithAssets).not.toHaveBeenCalled(); // プリフェッチは raw まで
      const res = await handler.semanticDiff(REQ);
      expect(res.ok).toBe(true);
      expect(diffWithAssets).toHaveBeenCalledTimes(1); // serve 時に合成が走る
    });
  });
});

describe('prefetch', () => {
  it('precomputes diffs so a later toggle serves without new blob fetches', async () => {
    const { deps, client } = makeDeps();
    const handler = createHandler(deps);
    await handler.prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled(); // prefetch は 10 req/min の Code Search に触れない
    const fetchesAfterPrefetch = client.getFileAtRef.mock.calls.length;
    const res = await handler.semanticDiff(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetchesAfterPrefetch); // blob 再フェッチなし
  });

  it('persists prefetched diffs to the diff store (sw restart survival)', async () => {
    const { deps } = makeDeps();
    await createHandler(deps).prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    expect(deps.diffStore.save).toHaveBeenCalledWith('base-sha:head-sha:Assets/Foo.prefab', DIFF);
  });

  it('serves a diff persisted by a previous worker from the store', async () => {
    // SW は 30 秒で死ぬ: 前世でプリフェッチした結果を storage.session 経由で拾えること
    const { deps, client, diffStore } = makeDeps();
    diffStore.data['base-sha:head-sha:Assets/Foo.prefab'] = DIFF; // 前世の SW が保存した体でシード
    const res = await createHandler(deps).semanticDiff(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).not.toHaveBeenCalledWith('o', 'r', 'Assets/Foo.prefab', 'base-sha');
  });

  it('prefetches only unity files and caps at 100', async () => {
    const files: PrFile[] = Array.from({ length: 120 }, (_, i) => ({ path: `Assets/F${i}.prefab`, status: 'modified' }));
    files.push({ path: 'README.md', status: 'modified' });
    const { deps, client } = makeDeps({ files });
    await createHandler(deps).prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    const paths = new Set(client.getFileAtRef.mock.calls.map((c) => c[2]));
    expect(paths.has('README.md')).toBe(false);
    expect(paths.size).toBe(100); // 上限で打ち切り
  });

  it('skips oversized files without caching them', async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(big);
    const handler = createHandler(deps);
    await handler.prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    expect(deps.diffStore.save).not.toHaveBeenCalled();
    // 後からの手動トグルでは従来通り too-large ゲートが出る
    expect(await handler.semanticDiff(REQ)).toEqual({ ok: false, error: 'too-large', bytes: big.length * 2 });
  });

  it('aborts silently on rate limit instead of surfacing an error', async () => {
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockRejectedValue(new RateLimitError('x'));
    await expect(createHandler(deps).prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 })).resolves.toBeUndefined();
  });

  it('returns without network when the pat is missing', async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    await createHandler(deps).prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });
});

it('dedupes a concurrent user toggle against an in-flight prefetch compute', async () => {
  // プリフェッチ中にユーザーがクリックしても diff 計算・blob フェッチが二重にならない
  const { deps, client } = makeDeps();
  const handler = createHandler(deps);
  const [, res] = await Promise.all([
    handler.prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 }),
    handler.semanticDiff(REQ),
  ]);
  expect(res.ok).toBe(true);
  const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === 'Assets/Foo.prefab');
  expect(fooFetches).toHaveLength(2); // base + head の 2 回だけ
});

describe('semanticDiff with push (two-stage)', () => {
  it('responds immediately with pending and pushes code-search results in the final json', async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: 'Assets/Scripts/S.cs' } });
    const { res, pushes } = await serveAndResolve(createHandler(deps), REQ);
    // 応答は即返り、resolved は空 + pending。名前は push で届く(B4 の核心)
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} }, pending: true });
    const last = pushes.at(-1)!;
    expect(last.done).toBe(true);
    expect(last.json?.resolved).toEqual({ g1: 'Assets/Scripts/S.cs' });
    expect(guidCache.save).toHaveBeenCalledWith('https://api.github.com/o/r', { g1: 'Assets/Scripts/S.cs' });
  });

  it('does not set pending when the pr meta index resolves everything', async () => {
    const { deps } = makeDeps({
      files: [
        { path: 'Assets/Foo.prefab', status: 'modified' },
        { path: 'Assets/S.cs.meta', status: 'modified' },
      ],
      contents: {
        'Assets/Foo.prefab@base-sha': 'b',
        'Assets/Foo.prefab@head-sha': 'a',
        'Assets/S.cs.meta@head-sha': 'guid: g1\n',
      },
    });
    const { res, pushes } = await serveAndResolve(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
    expect(pushes).toEqual([]); // 全部解決済み・ソース合成も不要なら push は無い
  });

  it('resolves via the repo index and only searches the leftover', async () => {
    const { deps, client } = makeDeps({ diff: () => ({ ...DIFF, unresolvedGuids: ['g1', 'g2'] }), search: { g2: 'Assets/Other.cs' } });
    client.listMetaTree.mockResolvedValue({ truncated: false, metas: [{ path: 'Assets/S.cs.meta', sha: 'sha1' }] });
    client.batchBlobTexts.mockResolvedValue({ sha1: 'guid: g1\n' });
    const { pushes } = await serveAndResolve(createHandler(deps), REQ);
    // 索引で g1 が先に届き(中間 push)、索引に無い g2 だけが Code Search に回る(3 段解決)
    expect(pushes[0]).toMatchObject({ resolved: { g1: 'Assets/S.cs' }, done: false });
    expect(pushes.at(-1)!.json?.resolved).toEqual({ g1: 'Assets/S.cs', g2: 'Assets/Other.cs' });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith('o', 'r', 'g2');
  });

  it('falls back to code search when the tree is truncated', async () => {
    const { deps, client } = makeDeps({ search: { g1: 'Assets/S.cs' } });
    client.listMetaTree.mockResolvedValue({ truncated: true, metas: [] });
    const { pushes } = await serveAndResolve(createHandler(deps), REQ);
    expect(pushes.at(-1)!.json?.resolved).toEqual({ g1: 'Assets/S.cs' });
  });

  it('stops retrying the index for the session after an index rate limit', async () => {
    const { deps, client } = makeDeps();
    client.listMetaTree.mockRejectedValue(new RateLimitError('x'));
    const handler = createHandler(deps);
    await serveAndResolve(handler, REQ);
    await serveAndResolve(handler, REQ);
    expect(client.listMetaTree).toHaveBeenCalledTimes(1); // SW 生存期間はフォールバック固定
  });

  it('re-merges sources in the async stage once the source guid resolves', async () => {
    // mergeSources 整合の核心: stage 1 は未合成のまま即応答し、
    // repo index でソース guid が解けたら合成し直した json が最終 push で届く
    const withSource: DiffV2 = { ...DIFF, unresolvedGuids: ['src1'], neededSources: [{ guid: 'src1', side: 'after' }] };
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: ['src1'], resolved: { src1: 'Assets/Src.prefab' } };
    const diffWithAssets = vi.fn(() => merged);
    const { deps, client } = makeDeps({
      contents: {
        'Assets/Foo.prefab@base-sha': 'b',
        'Assets/Foo.prefab@head-sha': 'a',
        'Assets/Src.prefab@head-sha': 'source prefab',
      },
      diff: () => withSource,
      diffWithAssets,
    });
    client.listMetaTree.mockResolvedValue({ truncated: false, metas: [{ path: 'Assets/Src.prefab.meta', sha: 'sha1' }] });
    client.batchBlobTexts.mockResolvedValue({ sha1: 'guid: src1\n' });
    // 注: serveAndResolve は done push を待つため、その後段では diffWithAssets が必ず既に呼ばれている
    // (done:true は mergeSources 完了後にしか出ない)。「まだ呼ばれていない」の検証は
    // 即応答の直後(push 完了を待つ前)に行う必要があるため、ここだけ手動で組み立てる。
    const pushes: GuidResolvedPush[] = [];
    const res = await createHandler(deps).semanticDiff(REQ, (m) => pushes.push(m));
    expect(res.ok && res.pending).toBe(true);
    expect(diffWithAssets).not.toHaveBeenCalled(); // stage 1 では合成しない(即応答優先)
    await vi.waitFor(() => expect(diffWithAssets).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
    expect(pushes.at(-1)!.json).toMatchObject({ resolved: { src1: 'Assets/Src.prefab' } });
  });

  it('kicks the repo index sync from prefetch', async () => {
    const { deps, client } = makeDeps();
    await createHandler(deps).prefetch({ type: 'prefetch', owner: 'o', repo: 'r', prNumber: 1 });
    await vi.waitFor(() => expect(client.listMetaTree).toHaveBeenCalledWith('o', 'r', 'head-sha'));
  });
});
