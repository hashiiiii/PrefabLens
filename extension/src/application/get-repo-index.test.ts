import { describe, expect, it, vi } from "vitest";
import type { RepoIndexRepository } from "../domain/guid/repo-index-repository";
import { err, ok } from "../domain/result";
import { createDiffSession } from "./create-diff-session";
import { getRepoIndex } from "./get-repo-index";

const REPO_KEY = "repoKey";

function makeFakes(overrides?: {
  metas?: Array<{ path: string; sha: string }>;
  truncated?: boolean;
  texts?: Record<string, string | null>;
  knownGuids?: Record<string, string>;
  storedIndex?: { treeSha: string; guids: Record<string, string> };
}) {
  const client = {
    listMetaTree: vi.fn(async () =>
      ok({
        truncated: overrides?.truncated ?? false,
        metas: overrides?.metas ?? [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      }),
    ),
    batchBlobTexts: vi.fn(async (_o: string, _r: string, oids: string[]) =>
      ok(Object.fromEntries(oids.map((oid) => [oid, overrides?.texts?.[oid] ?? null]))),
    ),
  };
  const guids: Record<string, Record<string, string>> = { [REPO_KEY]: { ...overrides?.knownGuids } };
  const indexes: Record<string, { treeSha: string; guids: Record<string, string> }> = {};
  if (overrides?.storedIndex) indexes[REPO_KEY] = overrides.storedIndex;
  const store: RepoIndexRepository = {
    loadGuids: vi.fn(async (repo) => guids[repo] ?? {}),
    saveGuids: vi.fn(async (repo, entries) => {
      guids[repo] = { ...guids[repo], ...entries };
    }),
    loadIndex: vi.fn(async (repo) => indexes[repo]),
    saveIndex: vi.fn(async (repo, index) => {
      indexes[repo] = index;
    }),
  };
  return { client, store, session: createDiffSession() };
}

describe("getRepoIndex", () => {
  it("builds guid → asset path from meta blobs and persists both layers", async () => {
    const { client, store, session } = makeFakes({ texts: { sha1: "fileFormatVersion: 2\nguid: g1\n" } });
    const res = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(res).toEqual({ g1: "Assets/S.cs" }); // path with .meta stripped
    expect(store.saveGuids).toHaveBeenCalledWith(REPO_KEY, { sha1: "g1" });
    expect(store.saveIndex).toHaveBeenCalledWith(REPO_KEY, { treeSha: "H", guids: { g1: "Assets/S.cs" } });
  });

  it("returns the stored index without any api call when the tree sha is unchanged", async () => {
    // Without a push, neither the tree nor blobs are re-fetched (repeat visits are zero-cost)
    const stored = { treeSha: "H", guids: { g1: "Assets/S.cs" } };
    const { client, store, session } = makeFakes({ storedIndex: stored });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toEqual(stored.guids);
    expect(client.listMetaTree).not.toHaveBeenCalled();
  });

  it("fetches only meta blobs missing from the persistent sha cache", async () => {
    // blobSha → guid is a content-derived permanent cache: only changed .meta go through GraphQL
    const { client, store, session } = makeFakes({
      metas: [
        { path: "Assets/A.cs.meta", sha: "known-sha" },
        { path: "Assets/B.cs.meta", sha: "new-sha" },
      ],
      knownGuids: { "known-sha": "gA" },
      texts: { "new-sha": "guid: gB\n" },
    });
    const res = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(client.batchBlobTexts).toHaveBeenCalledTimes(1);
    expect(client.batchBlobTexts.mock.calls[0]?.[2]).toEqual(["new-sha"]);
    expect(res).toEqual({ gA: "Assets/A.cs", gB: "Assets/B.cs" });
  });

  it("chunks graphql fetches at 100 blobs per query", async () => {
    const metas = Array.from({ length: 250 }, (_, i) => ({ path: `Assets/F${i}.cs.meta`, sha: `s${i}` }));
    const { client, store, session } = makeFakes({ metas });
    await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(client.batchBlobTexts).toHaveBeenCalledTimes(3); // 100 + 100 + 50
    expect(client.batchBlobTexts.mock.calls[0]?.[2]).toHaveLength(100);
    expect(client.batchBlobTexts.mock.calls[2]?.[2]).toHaveLength(50);
  });

  it("gives up on truncated trees", async () => {
    const { client, store, session } = makeFakes({ truncated: true });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(client.batchBlobTexts).not.toHaveBeenCalled();
  });

  it("gives up above 50,000 metas (storage quota guard)", async () => {
    const metas = Array.from({ length: 50_001 }, (_, i) => ({ path: `m${i}.meta`, sha: `s${i}` }));
    const { client, store, session } = makeFakes({ metas });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(store.saveIndex).not.toHaveBeenCalled();
  });

  it("skips blobs without a parsable guid", async () => {
    const { client, store, session } = makeFakes({
      metas: [
        { path: "Assets/A.cs.meta", sha: "sha1" },
        { path: "Assets/B.cs.meta", sha: "sha2" },
      ],
      texts: { sha1: "guid: g1\n", sha2: "not yaml at all" },
    });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toEqual({ g1: "Assets/A.cs" });
  });

  it("memoizes the index per repoKey@ref", async () => {
    const { client, store, session } = makeFakes({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      texts: { sha1: "guid: g1\n" },
    });
    const first = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha");
    expect(first).toEqual({ g1: "Assets/S.cs" });
    await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha");
    // The second call folds on the cached promise: not even the store is consulted again.
    expect(store.loadIndex).toHaveBeenCalledTimes(1);
    expect(client.listMetaTree).toHaveBeenCalledTimes(1);
  });

  it("pins the repo to fallback for the session after a rate limit", async () => {
    const { client, store, session } = makeFakes();
    client.listMetaTree.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(client.listMetaTree).toHaveBeenCalledTimes(1); // fallback: Code Search only from here on
  });

  it("retries after a non-rate-limit failure instead of caching it", async () => {
    const { client, store, session } = makeFakes({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      texts: { sha1: "guid: g1\n" },
    });
    client.listMetaTree.mockResolvedValueOnce(err({ kind: "fetch-failed" as const }) as never);
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toEqual({
      g1: "Assets/S.cs",
    });
  });
});
