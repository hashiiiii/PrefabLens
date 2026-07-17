import { describe, expect, it, vi } from "vitest";
import { RateLimitError } from "../github/client";
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest } from "../types";
import { must } from "../util/must";
import type { Differ } from "../wasm/differ";
import { createResolution, type DiffContext, type SearchClient } from "./resolution";

const REPO_KEY = "https://api.github.com/o/r";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };

const CTX: DiffContext = {
  refs: { baseSha: "base-sha", headSha: "head-sha" },
  files: [],
  guidIndex: new Map(),
  baseShas: null,
};

const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  origin: "https://github.com",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

function makeResolution(overrides?: {
  cached?: Record<string, string>; // initial contents of guidCache
  search?: Record<string, string | null>; // guid → asset path (null = no hit)
  blobs?: Record<string, string>; // `${path}@${sha}` → text served by the injected fetchBlob
  diffWithAssets?: Differ["diffWithAssets"];
  isUnityYaml?: Differ["isUnityYaml"];
  metas?: Array<{ path: string; sha: string }>; // whole-repo .meta listing (repo index)
  metaTexts?: Record<string, string | null>; // blob sha → .meta text (repo index)
}) {
  const cacheData: Record<string, Record<string, string>> = {};
  if (overrides?.cached) cacheData[REPO_KEY] = { ...overrides.cached };
  const guidCache = {
    data: cacheData,
    load: vi.fn(async (repo: string) => cacheData[repo] ?? {}),
    save: vi.fn(async (repo: string, entries: Record<string, string>) => {
      cacheData[repo] = { ...cacheData[repo], ...entries };
    }),
  };
  // Mirrors the RepoIndexStore interface. Starts empty per test.
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
  const client = {
    searchMetaByGuid: vi.fn(async (_o: string, _r: string, guid: string) => overrides?.search?.[guid] ?? null),
    listMetaTree: vi.fn(async () => ({ truncated: false, metas: overrides?.metas ?? [] })),
    batchBlobTexts: vi.fn(async () => overrides?.metaTexts ?? {}),
  };
  const differ: Differ = {
    diff: vi.fn(() => DIFF),
    diffWithAssets: overrides?.diffWithAssets ?? vi.fn(() => DIFF),
    // Fixture contents are shorthand strings, not real UnityYAML: accept by default.
    isUnityYaml: overrides?.isUnityYaml ?? (() => true),
  };
  // The handler injects its blob-cache-backed fetchers; the pipeline only sees these seams.
  const fetchBlob = vi.fn(
    async (_client: SearchClient, _o: string, _r: string, path: string, sha: string, _blobSha?: string) => {
      const text = overrides?.blobs?.[`${path}@${sha}`];
      return text === undefined ? null : new TextEncoder().encode(text);
    },
  );
  const fetchPair = vi.fn(
    async (): Promise<[Uint8Array, Uint8Array]> => [new TextEncoder().encode("b"), new TextEncoder().encode("a")],
  );
  const resolution = createResolution({
    guidCache,
    repoIndexStore,
    getDiffer: async () => differ,
    fetchBlob,
    fetchPair,
  });
  return { resolution, client, guidCache, repoIndexStore, differ, fetchBlob, fetchPair };
}

describe("searchGuids", () => {
  it("serves cached guids and searches only the unknown ones, persisting hits", async () => {
    const { resolution, client, guidCache } = makeResolution({
      cached: { g1: "Assets/Cached.cs" },
      search: { g2: "Assets/Found.cs" },
    });
    const result = await resolution.searchGuids(["g1", "g2"], client, "o", "r", REPO_KEY);
    expect(result).toEqual({ resolved: { g1: "Assets/Cached.cs", g2: "Assets/Found.cs" }, rateLimited: false });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "g2");
    expect(guidCache.save).toHaveBeenCalledWith(REPO_KEY, { g2: "Assets/Found.cs" });
  });

  it("caps code searches at 10 per call", async () => {
    const { resolution, client } = makeResolution();
    const guids = Array.from({ length: 12 }, (_, i) => `g${i}`);
    await resolution.searchGuids(guids, client, "o", "r", REPO_KEY);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
  });

  it("does not re-search misses but still emits their cached names later", async () => {
    // misses gates the search, not the name: an index resolution can land in guidCache afterwards.
    const { resolution, client, guidCache } = makeResolution(); // search misses
    expect((await resolution.searchGuids(["g1"], client, "o", "r", REPO_KEY)).resolved).toEqual({});
    guidCache.data[REPO_KEY] = { g1: "Assets/Later.cs" }; // as if the repo index wrote it later
    expect((await resolution.searchGuids(["g1"], client, "o", "r", REPO_KEY)).resolved).toEqual({
      g1: "Assets/Later.cs",
    });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it("returns partial results and reports the rate limit that interrupted the search loop", async () => {
    const { resolution, client } = makeResolution();
    client.searchMetaByGuid.mockResolvedValueOnce("Assets/First.cs").mockRejectedValueOnce(new RateLimitError("x"));
    const result = await resolution.searchGuids(["g1", "g2", "g3"], client, "o", "r", REPO_KEY);
    // g1 survives, g2 aborts the loop, g3 is never attempted (the budget is already gone).
    expect(result).toEqual({ resolved: { g1: "Assets/First.cs" }, rateLimited: true });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(2);
  });

  it("folds concurrent searches for the same guid into one request", async () => {
    const { resolution, client } = makeResolution();
    let release!: (v: string) => void;
    client.searchMetaByGuid.mockImplementation(
      () =>
        new Promise((r) => {
          release = r;
        }),
    );
    const [a, b] = [
      resolution.searchGuids(["g1"], client, "o", "r", REPO_KEY),
      resolution.searchGuids(["g1"], client, "o", "r", REPO_KEY),
    ];
    await vi.waitFor(() => expect(client.searchMetaByGuid).toHaveBeenCalled());
    release("Assets/S.cs");
    expect(await Promise.all([a, b])).toEqual([
      { resolved: { g1: "Assets/S.cs" }, rateLimited: false },
      { resolved: { g1: "Assets/S.cs" }, rateLimited: false },
    ]);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it("does not treat Object.prototype members as cache hits (hostile guid)", async () => {
    const { resolution, client } = makeResolution({ cached: { g9: "Assets/X.cs" } });
    const result = await resolution.searchGuids(["constructor"], client, "o", "r", REPO_KEY);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "constructor");
    expect(result.resolved).toEqual({});
  });
});

describe("getRepoIndex", () => {
  it("memoizes the index per repoKey@ref", async () => {
    const { resolution, client, repoIndexStore } = makeResolution({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      metaTexts: { sha1: "guid: g1\n" },
    });
    const first = await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha");
    expect(first).toEqual({ g1: "Assets/S.cs" });
    await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha");
    // The second call folds on the cached promise: not even the store is consulted again.
    expect(repoIndexStore.loadIndex).toHaveBeenCalledTimes(1);
    expect(client.listMetaTree).toHaveBeenCalledTimes(1);
  });

  it("pins the repo to fallback for the session after a rate limit", async () => {
    const { resolution, client } = makeResolution();
    client.listMetaTree.mockRejectedValue(new RateLimitError("x"));
    expect(await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(client.listMetaTree).toHaveBeenCalledTimes(1); // fallback: Code Search only from here on
  });

  it("retries after a non-rate-limit failure instead of caching it", async () => {
    const { resolution, client } = makeResolution({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      metaTexts: { sha1: "guid: g1\n" },
    });
    client.listMetaTree.mockRejectedValueOnce(new Error("socket"));
    expect(await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha")).toBeNull();
    expect(await resolution.getRepoIndex(client, "o", "r", REPO_KEY, "head-sha")).toEqual({ g1: "Assets/S.cs" });
  });
});

describe("mergeSources", () => {
  const BYTES: [Uint8Array, Uint8Array] = [new TextEncoder().encode("b"), new TextEncoder().encode("a")];
  const NEEDS: DiffV2 = {
    ...DIFF,
    unresolvedGuids: ["src1"],
    resolved: { src1: "Assets/Cyl.prefab" },
    neededSources: [{ guid: "src1", side: "after" }],
  };
  const MERGED: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };

  it("fetches an after-side source at head and re-diffs with assets", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client, fetchBlob } = makeResolution({
      diffWithAssets,
      blobs: { "Assets/Cyl.prefab@head-sha": "SRC" },
    });
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const result = await resolution.mergeSources(NEEDS, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    expect(fetchBlob).toHaveBeenCalledWith(client, "o", "r", "Assets/Cyl.prefab", "head-sha", undefined);
    const assets = must(diffWithAssets.mock.calls[0]?.[2]);
    expect(new TextDecoder().decode(must(assets.get("src1")))).toBe("SRC");
    expect(result.json).toMatchObject({ unresolvedGuids: [] });
    expect(result.status).toBe("complete");
  });

  it("fetches a before-side source at base, riding the base-tree blob sha", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client, fetchBlob } = makeResolution({
      diffWithAssets,
      blobs: { "Assets/Cyl.prefab@base-sha": "OLD" },
    });
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const ctx: DiffContext = { ...CTX, baseShas: new Map([["Assets/Cyl.prefab", "cyl-base"]]) };
    const before: DiffV2 = { ...NEEDS, neededSources: [{ guid: "src1", side: "before" }] };
    await resolution.mergeSources(before, differ, ...BYTES, ctx, client, "o", "r", REPO_KEY);
    expect(fetchBlob).toHaveBeenCalledWith(client, "o", "r", "Assets/Cyl.prefab", "base-sha", "cyl-base");
  });

  it("returns the first-pass diff when the source path is unresolved", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client } = makeResolution({ diffWithAssets });
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const unresolved: DiffV2 = { ...NEEDS, resolved: {} };
    const result = await resolution.mergeSources(unresolved, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    expect(diffWithAssets).not.toHaveBeenCalled();
    expect(result).toEqual({ json: unresolved, status: "complete" });
  });

  it("skips binary-serialized sources without counting them as progress", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client } = makeResolution({
      diffWithAssets,
      isUnityYaml: () => false,
      blobs: { "Assets/Cyl.prefab@head-sha": "\x00binary" },
    });
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => false };
    const result = await resolution.mergeSources(NEEDS, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    // Merging a binary source would be a no-op re-diff: give up and keep the first pass.
    expect(diffWithAssets).not.toHaveBeenCalled();
    expect(result).toEqual({ json: NEEDS, status: "complete" });
  });

  it("degrades to the current diff and reports rateLimited when the source fetch hits the limit", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client, fetchBlob } = makeResolution({ diffWithAssets });
    fetchBlob.mockRejectedValue(new RateLimitError("x"));
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const result = await resolution.mergeSources(NEEDS, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    expect(result).toEqual({ json: NEEDS, status: "rateLimited" });
  });

  it("degrades to the current diff and reports failed on a non-rate-limit fetch error", async () => {
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
    const { resolution, client, fetchBlob } = makeResolution({ diffWithAssets });
    fetchBlob.mockRejectedValue(new Error("socket"));
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const result = await resolution.mergeSources(NEEDS, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    expect(result).toEqual({ json: NEEDS, status: "failed" });
  });

  it("caps source re-diff rounds at 3 even while progressing", async () => {
    // Each merge output requests the next source, which always resolves: without the cap
    // a deep source chain would keep re-diffing forever.
    let round = 0;
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>((): DiffV2 => {
      round += 1;
      return { ...DIFF, unresolvedGuids: [`s${round}`], neededSources: [{ guid: `s${round}`, side: "after" }] };
    });
    const { resolution, client } = makeResolution({
      diffWithAssets,
      cached: { s1: "Assets/S1.prefab", s2: "Assets/S2.prefab", s3: "Assets/S3.prefab" },
      blobs: {
        "Assets/S0.prefab@head-sha": "S0",
        "Assets/S1.prefab@head-sha": "S1",
        "Assets/S2.prefab@head-sha": "S2",
      },
    });
    const differ = { diff: vi.fn(() => DIFF), diffWithAssets, isUnityYaml: () => true };
    const first: DiffV2 = {
      ...DIFF,
      unresolvedGuids: [],
      resolved: { s0: "Assets/S0.prefab" },
      neededSources: [{ guid: "s0", side: "after" }],
    };
    const result = await resolution.mergeSources(first, differ, ...BYTES, CTX, client, "o", "r", REPO_KEY);
    expect(diffWithAssets).toHaveBeenCalledTimes(3);
    expect(result.json.neededSources).toEqual([{ guid: "s3", side: "after" }]); // degraded at the cap
  });
});

describe("resolveRemaining", () => {
  async function run(
    resolution: ReturnType<typeof makeResolution>["resolution"],
    client: SearchClient,
    first: DiffV2,
    remaining: string[],
    ctx: DiffContext = CTX,
  ): Promise<GuidResolvedPush[]> {
    const pushes: GuidResolvedPush[] = [];
    await resolution.resolveRemaining(first, remaining, client, REQ, "https://api.github.com", ctx, (m) =>
      pushes.push(m),
    );
    return pushes;
  }

  it("resolves via the repo index first and searches only the leftover", async () => {
    const { resolution, client, guidCache } = makeResolution({
      metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }],
      metaTexts: { sha1: "guid: g1\n" },
      search: { g2: "Assets/Other.cs" },
    });
    const first: DiffV2 = { ...DIFF, unresolvedGuids: ["g1", "g2"] };
    const pushes = await run(resolution, client, first, ["g1", "g2"]);
    // Index names arrive in an intermediate push; the final push carries the full json.
    expect(pushes[0]).toMatchObject({ resolved: { g1: "Assets/S.cs" }, done: false });
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "complete" });
    expect(must(pushes.at(-1)).json?.resolved).toEqual({ g1: "Assets/S.cs", g2: "Assets/Other.cs" });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "g2");
    // Index results land in guidCache so a later source re-merge can restore them.
    expect(guidCache.save).toHaveBeenCalledWith(REPO_KEY, { g1: "Assets/S.cs" });
  });

  it("skips the index when only a source re-merge is pending", async () => {
    // The first index build can take tens of seconds and cannot help: no guid names are missing.
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: [] };
    const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => merged);
    const { resolution, client } = makeResolution({
      diffWithAssets,
      cached: { src1: "Assets/Src.prefab" },
      blobs: { "Assets/Src.prefab@head-sha": "SRC" },
    });
    const first: DiffV2 = {
      ...DIFF,
      unresolvedGuids: ["src1"],
      resolved: { src1: "Assets/Src.prefab" },
      neededSources: [{ guid: "src1", side: "after" }],
    };
    const pushes = await run(resolution, client, first, []);
    expect(client.listMetaTree).not.toHaveBeenCalled();
    expect(diffWithAssets).toHaveBeenCalledTimes(1);
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "complete" });
    expect(must(pushes.at(-1)).json).toMatchObject({ unresolvedGuids: [] });
  });

  it("marks the final push rateLimited when Code Search hits the limit", async () => {
    // Rate-limited runs must be distinguishable from completed ones (issue #194).
    const { resolution, client } = makeResolution();
    client.searchMetaByGuid.mockRejectedValue(new RateLimitError("x"));
    const first: DiffV2 = { ...DIFF, unresolvedGuids: ["g1"] };
    const pushes = await run(resolution, client, first, ["g1"]);
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("still emits the done push, marked failed, when the pipeline crashes", async () => {
    // Waiters key off done: a crash that swallowed it would leave the indicator spinning forever.
    const { resolution, client, fetchPair } = makeResolution();
    fetchPair.mockRejectedValue(new Error("socket"));
    const first: DiffV2 = { ...DIFF, unresolvedGuids: [], neededSources: [{ guid: "src1", side: "after" }] };
    const pushes = await run(resolution, client, first, []);
    expect(pushes).toEqual([
      {
        type: "guidResolved",
        owner: "o",
        repo: "r",
        target: REQ.target,
        path: REQ.path,
        resolved: {},
        done: true,
        status: "failed",
      },
    ]);
  });
});
