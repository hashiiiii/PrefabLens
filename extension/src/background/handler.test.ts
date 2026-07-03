import { describe, expect, it, vi } from 'vitest';
import { createHandler, type Deps } from './handler';
import { AuthError, RateLimitError, type PrFile } from '../github/client';
import { DiffError, type Differ } from '../wasm/differ';
import type { DiffV1, SemanticDiffRequest } from '../types';

const REQ: SemanticDiffRequest = { type: 'semanticDiff', owner: 'o', repo: 'r', prNumber: 1, path: 'Assets/Foo.prefab' };

const DIFF: DiffV1 = { schema: 'prefablens.diff.v1', unresolvedGuids: ['g1'], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: PrFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  diff?: Differ['diff'];
  pat?: string | undefined;
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
  };
  const differ: Differ = { diff: overrides?.diff ?? vi.fn(() => DIFF) };
  const deps: Deps = {
    getSettings: async () => ({ pat: 'pat' in (overrides ?? {}) ? overrides!.pat : 'tok', baseUrl: undefined }),
    makeClient: () => client,
    getDiffer: async () => differ,
  };
  return { deps, client, differ };
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
    const diff = vi.fn(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'added' }], diff });
    await createHandler(deps)(REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'base-sha',
    );
    expect(baseFetches).toHaveLength(0);
    expect((diff.mock.calls[0] as any[])?.[0]).toHaveLength(0); // before は空
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

  it('maps RateLimitError to rate-limited', async () => {
    const limited = makeDeps();
    limited.client.getPrRefs.mockRejectedValue(new RateLimitError('x'));
    expect(await createHandler(limited.deps)(REQ)).toEqual({ ok: false, error: 'rate-limited' });
  });
});
