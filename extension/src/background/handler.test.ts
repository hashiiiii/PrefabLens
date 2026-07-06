import { describe, expect, it, vi } from 'vitest';
import { createHandler, type Deps } from './handler';
import { AuthError, RateLimitError, type PrFile } from '../github/client';
import { DiffError, type Differ } from '../wasm/differ';
import type { DiffV2, SemanticDiffRequest } from '../types';

const REQ: SemanticDiffRequest = { type: 'semanticDiff', owner: 'o', repo: 'r', prNumber: 1, path: 'Assets/Foo.prefab' };

const DIFF: DiffV2 = { schema: 'prefablens.diff.v2', unresolvedGuids: ['g1'], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: PrFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  diff?: Differ['diff'];
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
  };
  const differ: Differ = { diff: overrides?.diff ?? vi.fn(() => DIFF) };
  const cacheData: Record<string, Record<string, string>> = {};
  if (overrides?.cached) cacheData['https://api.github.com/o/r'] = { ...overrides.cached };
  const guidCache = {
    data: cacheData,
    load: vi.fn(async (repo: string) => cacheData[repo] ?? {}),
    save: vi.fn(async (repo: string, entries: Record<string, string>) => {
      cacheData[repo] = { ...cacheData[repo], ...entries };
    }),
  };
  const deps: Deps = {
    getSettings: async () => ({ pat: Object.hasOwn(overrides ?? {}, 'pat') ? overrides!.pat : 'tok', baseUrl: undefined }),
    makeClient: () => client,
    getDiffer: async () => differ,
    guidCache,
  };
  return { deps, client, differ, guidCache };
}

describe('createHandler', () => {
  it('returns pat-missing without touching the network', async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    const res = await createHandler(deps)(REQ);
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
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
  });

  it('uses an empty before for added files without fetching the base side', async () => {
    const diff = vi.fn<Differ['diff']>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'added' }], diff });
    await createHandler(deps)(REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'base-sha',
    );
    expect(baseFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[0]).toHaveLength(0); // before は空
  });

  it('uses an empty after for removed files without fetching the head side', async () => {
    const diff = vi.fn<Differ['diff']>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'removed' }], diff });
    await createHandler(deps)(REQ);
    const headFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'head-sha',
    );
    expect(headFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[1]).toHaveLength(0); // after は空
  });

  it('diffs a file missing from the PR list as modified (files API caps at 3000)', async () => {
    // 3000 ファイル超の PR では一覧 API が打ち切られ、UI にあるファイルが一覧に無いことがある
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Other.prefab', status: 'modified' }] });
    const res = await createHandler(deps)(REQ);
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
    await createHandler(deps)(REQ);
    expect(maxInFlight).toBe(2);
  });

  it('reads renamed files from previousPath on the base side', async () => {
    const { deps, client } = makeDeps({
      files: [{ path: 'Assets/Foo.prefab', status: 'renamed', previousPath: 'Assets/Old.prefab' }],
      contents: { 'Assets/Old.prefab@base-sha': 'b', 'Assets/Foo.prefab@head-sha': 'a' },
    });
    const res = await createHandler(deps)(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Old.prefab', 'base-sha');
  });

  it('caches PR context across calls (refs/files/guid index fetched once)', async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await handle(REQ);
    await handle({ ...REQ, path: 'Assets/Foo.prefab' });
    expect(client.getPrRefs).toHaveBeenCalledTimes(1);
    expect(client.listPrFiles).toHaveBeenCalledTimes(1);
  });

  it('refreshes PR context after 60s so new pushes are picked up', async () => {
    vi.useFakeTimers();
    try {
      const { deps, client } = makeDeps();
      const handle = createHandler(deps);
      await handle(REQ);
      vi.setSystemTime(Date.now() + 59_000);
      await handle(REQ);
      expect(client.getPrRefs).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 2_000); // 計 61 秒
      await handle(REQ);
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
    expect(await handle(REQ)).toEqual({ ok: false, error: 'fetch-failed' });
    expect((await handle(REQ)).ok).toBe(true);
  });

  it('fetches each sha+path blob only once (immutable content)', async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await handle(REQ);
    await handle(REQ);
    const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === 'Assets/Foo.prefab');
    expect(fooFetches).toHaveLength(2); // base + head の 2 回だけ(2 回目の handle では再フェッチしない)
  });

  it('resolves remaining guids via code search and persists them', async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: 'Assets/Scripts/S.cs' } });
    const res = await createHandler(deps)(REQ);
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
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it('serves cached guids without searching', async () => {
    const { deps, client } = makeDeps({ cached: { g1: 'Assets/Cached.cs' } });
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/Cached.cs' } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it('does not re-search a missed guid within the worker lifetime', async () => {
    const { deps, client } = makeDeps(); // search 未ヒット
    const handle = createHandler(deps);
    await handle(REQ);
    await handle(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it('keeps the diff usable when code search hits the rate limit', async () => {
    const twoGuids: DiffV2 = { ...DIFF, unresolvedGuids: ['g1', 'g2'] };
    const { deps, client } = makeDeps({ diff: () => twoGuids });
    client.searchMetaByGuid
      .mockResolvedValueOnce('Assets/First.cs')
      .mockRejectedValueOnce(new RateLimitError('x'));
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: true, json: { ...twoGuids, resolved: { g1: 'Assets/First.cs' } } });
  });

  it('does not treat Object.prototype members as cache hits (hostile guid)', async () => {
    const proto: DiffV2 = { ...DIFF, unresolvedGuids: ['constructor'] };
    const { deps, client } = makeDeps({ diff: () => proto, cached: { g9: 'Assets/X.cs' } });
    const res = await createHandler(deps)(REQ);
    // 'constructor' はキャッシュヒットではなく検索に回り、未ヒットで未解決のまま
    expect(client.searchMetaByGuid).toHaveBeenCalledWith('o', 'r', 'constructor');
    expect(res).toEqual({ ok: true, json: { ...proto, resolved: {} } });
  });

  it('caps code searches at 10 per request', async () => {
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many });
    await createHandler(deps)(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
  });

  it('does not count cached guids against the search cap', async () => {
    // 12 guid 中 2 つがキャッシュ済みなら、検索枠 10 は未知の 10 guid にまるごと使える
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many, cached: { g0: 'Assets/A.cs', g1: 'Assets/B.cs' } });
    const res = await createHandler(deps)(REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
    expect(res).toEqual({ ok: true, json: { ...many, resolved: { g0: 'Assets/A.cs', g1: 'Assets/B.cs' } } });
  });

  it('maps AuthError / DiffError / other failures to stable error codes', async () => {
    const auth = makeDeps();
    auth.client.getPrRefs.mockRejectedValue(new AuthError('x'));
    expect(await createHandler(auth.deps)(REQ)).toEqual({ ok: false, error: 'auth-failed' });

    const bad = makeDeps({
      diff: () => {
        throw new DiffError('NestingTooDeep');
      },
    });
    expect(await createHandler(bad.deps)(REQ)).toEqual({ ok: false, error: 'diff-failed' });

    const net = makeDeps();
    net.client.listPrFiles.mockRejectedValue(new Error('socket'));
    expect(await createHandler(net.deps)(REQ)).toEqual({ ok: false, error: 'fetch-failed' });
  });

  it('returns too-large above 25MB unless forced', async () => {
    const big = new Uint8Array(13 * 1024 * 1024); // base+head で 26MB
    const diff = vi.fn(() => DIFF);
    const { deps, client } = makeDeps({ diff });
    client.getFileAtRef.mockResolvedValue(big);
    const handle = createHandler(deps);
    expect(await handle(REQ)).toEqual({ ok: false, error: 'too-large', bytes: big.length * 2 });
    expect(diff).not.toHaveBeenCalled();
    // force で描画に進む。blob は sha キャッシュに乗っており再フェッチもない
    const fetches = client.getFileAtRef.mock.calls.length;
    expect((await handle({ ...REQ, force: true })).ok).toBe(true);
    expect(diff).toHaveBeenCalledTimes(1);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetches);
  });

  it('renders exactly 25MB without the gate', async () => {
    const half = new Uint8Array((25 * 1024 * 1024) / 2);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(half);
    expect((await createHandler(deps)(REQ)).ok).toBe(true);
  });

  it('maps RateLimitError to rate-limited', async () => {
    const limited = makeDeps();
    limited.client.getPrRefs.mockRejectedValue(new RateLimitError('x'));
    expect(await createHandler(limited.deps)(REQ)).toEqual({ ok: false, error: 'rate-limited' });
  });
});
