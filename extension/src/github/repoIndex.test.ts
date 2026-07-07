import { describe, expect, it, vi } from 'vitest';
import { syncRepoIndex, type RepoIndexStore } from './repoIndex';

function makeFakes(overrides?: {
  metas?: Array<{ path: string; sha: string }>;
  truncated?: boolean;
  texts?: Record<string, string | null>;
  knownGuids?: Record<string, string>;
  storedIndex?: { treeSha: string; guids: Record<string, string> };
}) {
  const client = {
    listMetaTree: vi.fn(async () => ({
      truncated: overrides?.truncated ?? false,
      metas: overrides?.metas ?? [{ path: 'Assets/S.cs.meta', sha: 'sha1' }],
    })),
    batchBlobTexts: vi.fn(async (_o: string, _r: string, oids: string[]) =>
      Object.fromEntries(oids.map((oid) => [oid, overrides?.texts?.[oid] ?? null])),
    ),
  };
  const guids: Record<string, Record<string, string>> = { repoKey: { ...overrides?.knownGuids } };
  const indexes: Record<string, { treeSha: string; guids: Record<string, string> }> = {};
  if (overrides?.storedIndex) indexes['repoKey'] = overrides.storedIndex;
  const store: RepoIndexStore = {
    loadGuids: vi.fn(async (repo) => guids[repo] ?? {}),
    saveGuids: vi.fn(async (repo, entries) => {
      guids[repo] = { ...guids[repo], ...entries };
    }),
    loadIndex: vi.fn(async (repo) => indexes[repo]),
    saveIndex: vi.fn(async (repo, index) => {
      indexes[repo] = index;
    }),
  };
  return { client, store };
}

describe('syncRepoIndex', () => {
  it('builds guid → asset path from meta blobs and persists both layers', async () => {
    const { client, store } = makeFakes({ texts: { sha1: 'fileFormatVersion: 2\nguid: g1\n' } });
    const res = await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H');
    expect(res).toEqual({ g1: 'Assets/S.cs' }); // .meta を剥いだパス
    expect(store.saveGuids).toHaveBeenCalledWith('repoKey', { sha1: 'g1' });
    expect(store.saveIndex).toHaveBeenCalledWith('repoKey', { treeSha: 'H', guids: { g1: 'Assets/S.cs' } });
  });

  it('returns the stored index without any api call when the tree sha is unchanged', async () => {
    // push が無ければ tree も blob も取り直さない(2 回目以降の訪問はゼロコスト)
    const stored = { treeSha: 'H', guids: { g1: 'Assets/S.cs' } };
    const { client, store } = makeFakes({ storedIndex: stored });
    const res = await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H');
    expect(res).toEqual(stored.guids);
    expect(client.listMetaTree).not.toHaveBeenCalled();
  });

  it('fetches only meta blobs missing from the persistent sha cache', async () => {
    // blobSha → guid は内容由来の永久キャッシュ: 変わった .meta だけ GraphQL に回る
    const { client, store } = makeFakes({
      metas: [
        { path: 'Assets/A.cs.meta', sha: 'known-sha' },
        { path: 'Assets/B.cs.meta', sha: 'new-sha' },
      ],
      knownGuids: { 'known-sha': 'gA' },
      texts: { 'new-sha': 'guid: gB\n' },
    });
    const res = await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H');
    expect(client.batchBlobTexts).toHaveBeenCalledTimes(1);
    expect(client.batchBlobTexts.mock.calls[0]?.[2]).toEqual(['new-sha']);
    expect(res).toEqual({ gA: 'Assets/A.cs', gB: 'Assets/B.cs' });
  });

  it('chunks graphql fetches at 100 blobs per query', async () => {
    const metas = Array.from({ length: 250 }, (_, i) => ({ path: `Assets/F${i}.cs.meta`, sha: `s${i}` }));
    const { client, store } = makeFakes({ metas });
    await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H');
    expect(client.batchBlobTexts).toHaveBeenCalledTimes(3); // 100 + 100 + 50
    expect(client.batchBlobTexts.mock.calls[0]?.[2]).toHaveLength(100);
    expect(client.batchBlobTexts.mock.calls[2]?.[2]).toHaveLength(50);
  });

  it('gives up on truncated trees', async () => {
    const { client, store } = makeFakes({ truncated: true });
    expect(await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H')).toBeNull();
    expect(client.batchBlobTexts).not.toHaveBeenCalled();
  });

  it('gives up above 50,000 metas (storage quota guard)', async () => {
    const metas = Array.from({ length: 50_001 }, (_, i) => ({ path: `m${i}.meta`, sha: `s${i}` }));
    const { client, store } = makeFakes({ metas });
    expect(await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H')).toBeNull();
    expect(store.saveIndex).not.toHaveBeenCalled();
  });

  it('skips blobs without a parsable guid', async () => {
    const { client, store } = makeFakes({
      metas: [
        { path: 'Assets/A.cs.meta', sha: 'sha1' },
        { path: 'Assets/B.cs.meta', sha: 'sha2' },
      ],
      texts: { sha1: 'guid: g1\n', sha2: 'not yaml at all' },
    });
    expect(await syncRepoIndex(client, store, 'o', 'r', 'repoKey', 'H')).toEqual({ g1: 'Assets/A.cs' });
  });
});
