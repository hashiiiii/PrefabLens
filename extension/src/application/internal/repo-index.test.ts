import { describe, expect, it } from "vitest";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { err, ok } from "../../domain/result";
import { createDiffSession } from "../diff/create-diff-session";
import type { GithubGateway } from "../gateway/github";
import { getRepoIndex } from "./repo-index";

const REPO_KEY = "repoKey";

type Client = Pick<GithubGateway, "listMetaTree" | "batchBlobTexts">;

function makeFakes(overrides?: {
  metas?: Array<{ path: string; sha: string }>;
  truncated?: boolean;
  texts?: Record<string, string | null>;
  knownGuids?: Record<string, string>;
  storedIndex?: { treeSha: string; guids: Record<string, string> };
}) {
  const calls = {
    listMetaTree: [] as Array<Parameters<Client["listMetaTree"]>>,
    batchBlobTexts: [] as Array<Parameters<Client["batchBlobTexts"]>>,
    loadIndex: [] as string[],
  };
  // Canned listMetaTree answers, consulted before the state-derived default. An array is a
  // once-queue: each call shifts one entry, and a drained array falls through. A single
  // value answers every call.
  const results: {
    listMetaTree?: Awaited<ReturnType<Client["listMetaTree"]>> | Array<Awaited<ReturnType<Client["listMetaTree"]>>>;
  } = {};
  const client: Client = {
    listMetaTree: async (...args) => {
      calls.listMetaTree.push(args);
      const queued = results.listMetaTree;
      if (Array.isArray(queued)) {
        const next = queued.shift();
        if (next !== undefined) return next;
      } else if (queued !== undefined) {
        return queued;
      }
      return ok({
        truncated: overrides?.truncated ?? false,
        metas: overrides?.metas ?? [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      });
    },
    batchBlobTexts: async (...args) => {
      calls.batchBlobTexts.push(args);
      const oids = args[2];
      return ok(Object.fromEntries(oids.map((oid) => [oid, overrides?.texts?.[oid] ?? null])));
    },
  };
  const guids: Record<string, Record<string, string>> = { [REPO_KEY]: { ...overrides?.knownGuids } };
  const indexes: Record<string, { treeSha: string; guids: Record<string, string> }> = {};
  if (overrides?.storedIndex) indexes[REPO_KEY] = overrides.storedIndex;
  const savedGuids: Array<[string, Record<string, string>]> = [];
  const savedIndexes: Array<[string, { treeSha: string; guids: Record<string, string> }]> = [];
  const store: RepoIndexRepository & { savedGuids: typeof savedGuids; savedIndexes: typeof savedIndexes } = {
    savedGuids,
    savedIndexes,
    loadGuids: async (repo) => guids[repo] ?? {},
    saveGuids: async (repo, entries) => {
      savedGuids.push([repo, entries]);
      guids[repo] = { ...guids[repo], ...entries };
    },
    loadIndex: async (repo) => {
      calls.loadIndex.push(repo);
      return indexes[repo];
    },
    saveIndex: async (repo, index) => {
      savedIndexes.push([repo, index]);
      indexes[repo] = index;
    },
  };
  return { client, store, calls, results, session: createDiffSession() };
}

describe("getRepoIndex", () => {
  it("builds guid → asset path from meta blobs and persists both layers", async () => {
    const { client, store, session } = makeFakes({ texts: { sha1: "fileFormatVersion: 2\nguid: g1\n" } });
    const res = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(res).toEqual({ g1: "Assets/S.cs" }); // path with .meta stripped
    expect(store.savedGuids).toContainEqual([REPO_KEY, { sha1: "g1" }]);
    expect(store.savedIndexes).toContainEqual([REPO_KEY, { treeSha: "H", guids: { g1: "Assets/S.cs" } }]);
  });

  it("returns the stored index without any api call when the tree sha is unchanged", async () => {
    // Without a push, neither the tree nor blobs are re-fetched (repeat visits are zero-cost)
    const stored = { treeSha: "H", guids: { g1: "Assets/S.cs" } };
    const { client, store, calls, session } = makeFakes({ storedIndex: stored });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toEqual(stored.guids);
    expect(calls.listMetaTree).toEqual([]);
  });

  it("fetches only meta blobs missing from the persistent sha cache", async () => {
    // blobSha → guid is a content-derived permanent cache: only changed .meta go through GraphQL
    const { client, store, calls, session } = makeFakes({
      metas: [
        { path: "Assets/A.cs.meta", sha: "known-sha" },
        { path: "Assets/B.cs.meta", sha: "new-sha" },
      ],
      knownGuids: { "known-sha": "gA" },
      texts: { "new-sha": "guid: gB\n" },
    });
    const res = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(calls.batchBlobTexts).toHaveLength(1);
    expect(calls.batchBlobTexts[0]?.[2]).toEqual(["new-sha"]);
    expect(res).toEqual({ gA: "Assets/A.cs", gB: "Assets/B.cs" });
  });

  it("chunks graphql fetches at 100 blobs per query", async () => {
    const metas = Array.from({ length: 250 }, (_, i) => ({ path: `Assets/F${i}.cs.meta`, sha: `s${i}` }));
    const { client, store, calls, session } = makeFakes({ metas });
    await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H");
    expect(calls.batchBlobTexts).toHaveLength(3); // 100 + 100 + 50
    expect(calls.batchBlobTexts[0]?.[2]).toHaveLength(100);
    expect(calls.batchBlobTexts[2]?.[2]).toHaveLength(50);
  });

  it("gives up on truncated trees", async () => {
    const { client, store, calls, session } = makeFakes({ truncated: true });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(calls.batchBlobTexts).toEqual([]);
  });

  it("gives up above 50,000 metas (storage quota guard)", async () => {
    const metas = Array.from({ length: 50_001 }, (_, i) => ({ path: `m${i}.meta`, sha: `s${i}` }));
    const { client, store, session } = makeFakes({ metas });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(store.savedIndexes).toEqual([]);
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
    const { client, store, calls, session } = makeFakes({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      texts: { sha1: "guid: g1\n" },
    });
    const first = await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha");
    expect(first).toEqual({ g1: "Assets/S.cs" });
    await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha");
    // The second call folds on the cached promise: not even the store is consulted again.
    expect(calls.loadIndex).toHaveLength(1);
    expect(calls.listMetaTree).toHaveLength(1);
  });

  it("pins the repo to fallback for the session after a rate limit", async () => {
    const { client, store, calls, results, session } = makeFakes();
    results.listMetaTree = err({ kind: "rate-limited" as const });
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(calls.listMetaTree).toHaveLength(1); // fallback: Code Search only from here on
  });

  it("retries after a non-rate-limit failure instead of caching it", async () => {
    const { client, store, results, session } = makeFakes({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      texts: { sha1: "guid: g1\n" },
    });
    results.listMetaTree = [err({ kind: "fetch-failed" as const })];
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await getRepoIndex(store, session, client, "o", "r", REPO_KEY, "head-sha")).toEqual({
      g1: "Assets/S.cs",
    });
  });
});
