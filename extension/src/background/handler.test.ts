import { describe, expect, it, vi } from "vitest";
import { AuthError, type PrFile, RateLimitError } from "../github/client";
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest } from "../types";
import { DiffError, type Differ } from "../wasm/differ";
import { createHandler, type Deps, type Handler } from "./handler";

const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: "o",
  repo: "r",
  prNumber: 1,
  path: "Assets/Foo.prefab",
};

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: PrFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  diff?: Differ["diff"];
  diffWithAssets?: Differ["diffWithAssets"];
  pat?: string | undefined;
  search?: Record<string, string | null>; // guid → asset path (null = no hit)
  cached?: Record<string, string>; // initial contents of guidCache
}) {
  const files = overrides?.files ?? [{ path: "Assets/Foo.prefab", status: "modified" }];
  const contents = overrides?.contents ?? { "Assets/Foo.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" };
  const getFileAtRef = vi.fn(async (_o: string, _r: string, path: string, ref: string) => {
    const text = contents[`${path}@${ref}`];
    return text === undefined ? null : new TextEncoder().encode(text);
  });
  const client = {
    getPrRefs: vi.fn(async () => ({ baseSha: "base-sha", headSha: "head-sha" })),
    listPrFiles: vi.fn(async () => files),
    getFileAtRef,
    searchMetaByGuid: vi.fn(async (_o: string, _r: string, guid: string) => overrides?.search?.[guid] ?? null),
    listMetaTree: vi.fn(
      async (): Promise<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }> => ({
        truncated: false,
        metas: [],
      }),
    ),
    batchBlobTexts: vi.fn(async (): Promise<Record<string, string | null>> => ({})),
  };
  const differ: Differ = {
    diff: overrides?.diff ?? vi.fn(() => DIFF),
    diffWithAssets: overrides?.diffWithAssets ?? vi.fn(() => DIFF),
  };
  const cacheData: Record<string, Record<string, string>> = {};
  if (overrides?.cached) cacheData["https://api.github.com/o/r"] = { ...overrides.cached };
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
  // Mirrors the RepoIndexStore interface (loadGuids/saveGuids/loadIndex/saveIndex). Starts empty per test.
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
    getSettings: async () => ({
      pat: Object.hasOwn(overrides ?? {}, "pat") ? overrides?.pat : "tok",
    }),
    makeClient: (_base: string, _token: string, _lane: "user" | "prefetch") => client,
    getDiffer: async () => differ,
    guidCache,
    diffStore,
    repoIndexStore,
  };
  return { deps, client, differ, guidCache, diffStore, repoIndexStore };
}

/** Cleanup for a pending response: wait until the done push arrives before asserting. */
async function serveAndResolve(
  handler: Handler,
  req: SemanticDiffRequest,
): Promise<{ res: Awaited<ReturnType<Handler["semanticDiff"]>>; pushes: GuidResolvedPush[] }> {
  const pushes: GuidResolvedPush[] = [];
  const res = await handler.semanticDiff(req, (m) => pushes.push(m));
  if (res.ok && res.pending) await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  return { res, pushes };
}

/** Drives semanticDiff to completion — the immediate response plus every push — and returns the
 *  fully-resolved response. Errors and fully-in-PR-resolved diffs pass through unchanged; a pending
 *  diff resolves to the final push's json, i.e. what the pipeline ultimately produces. */
async function resolveFully(
  handler: Handler,
  req: SemanticDiffRequest,
): Promise<Awaited<ReturnType<Handler["semanticDiff"]>>> {
  const pushes: GuidResolvedPush[] = [];
  const res = await handler.semanticDiff(req, (m) => pushes.push(m));
  if (!res.ok || !res.pending) return res;
  await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  const final = pushes.at(-1);
  return final?.json ? { ok: true, json: final.json } : res;
}

describe("createHandler", () => {
  it("returns pat-missing without touching the network", async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: false, error: "pat-missing" });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });

  it("diffs base/head blobs and attaches resolved guids", async () => {
    const { deps } = makeDeps({
      files: [
        { path: "Assets/Foo.prefab", status: "modified" },
        { path: "Assets/S.cs.meta", status: "modified" },
      ],
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/S.cs.meta@head-sha": "guid: g1\n",
      },
    });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
  });

  it("uses an empty before for added files without fetching the base side", async () => {
    const diff = vi.fn<Differ["diff"]>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Foo.prefab", status: "added" }], diff });
    await resolveFully(createHandler(deps), REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === "Assets/Foo.prefab" && c[3] === "base-sha",
    );
    expect(baseFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[0]).toHaveLength(0); // before is empty
  });

  it("uses an empty after for removed files without fetching the head side", async () => {
    const diff = vi.fn<Differ["diff"]>(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Foo.prefab", status: "removed" }], diff });
    await resolveFully(createHandler(deps), REQ);
    const headFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === "Assets/Foo.prefab" && c[3] === "head-sha",
    );
    expect(headFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[1]).toHaveLength(0); // after is empty
  });

  it("diffs a file missing from the PR list as modified (files API caps at 3000)", async () => {
    // In a PR with over 3000 files, the listing API is truncated, so a file present in the UI may be absent from the listing
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Other.prefab", status: "modified" }] });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
    expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "head-sha");
  });

  it("fetches the base and head blobs in parallel", async () => {
    // First-toggle latency is dominated by the two blob fetches, so pin against a regression to serialization
    let inFlight = 0;
    let maxInFlight = 0;
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockImplementation(async () => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 0));
      inFlight--;
      return new TextEncoder().encode("x");
    });
    await resolveFully(createHandler(deps), REQ);
    expect(maxInFlight).toBe(2);
  });

  it("reads renamed files from previousPath on the base side", async () => {
    const { deps, client } = makeDeps({
      files: [{ path: "Assets/Foo.prefab", status: "renamed", previousPath: "Assets/Old.prefab" }],
      contents: { "Assets/Old.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" },
    });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Old.prefab", "base-sha");
  });

  it("caches PR context across calls (refs/files/guid index fetched once)", async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await resolveFully(handle, REQ);
    await resolveFully(handle, { ...REQ, path: "Assets/Foo.prefab" });
    expect(client.getPrRefs).toHaveBeenCalledTimes(1);
    expect(client.listPrFiles).toHaveBeenCalledTimes(1);
  });

  it("refreshes PR context after 60s so new pushes are picked up", async () => {
    vi.useFakeTimers();
    try {
      const { deps, client } = makeDeps();
      const handle = createHandler(deps);
      // Fake timers make resolveFully's vi.waitFor hang; this test only needs the immediate response.
      await handle.semanticDiff(REQ, () => {});
      vi.setSystemTime(Date.now() + 59_000);
      await handle.semanticDiff(REQ, () => {});
      expect(client.getPrRefs).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 2_000); // 61 seconds total
      await handle.semanticDiff(REQ, () => {});
      expect(client.getPrRefs).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("retries the PR context after a failed load instead of caching the failure", async () => {
    // If a transient network failure lands in the 60s cache, re-toggling would no longer fix it
    const { deps, client } = makeDeps();
    client.listPrFiles.mockRejectedValueOnce(new Error("socket"));
    const handle = createHandler(deps);
    expect(await resolveFully(handle, REQ)).toEqual({ ok: false, error: "fetch-failed" });
    expect((await resolveFully(handle, REQ)).ok).toBe(true);
  });

  it("fetches each sha+path blob only once (immutable content)", async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await resolveFully(handle, REQ);
    await resolveFully(handle, REQ);
    const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === "Assets/Foo.prefab");
    expect(fooFetches).toHaveLength(2); // only twice, base + head (the second handle doesn't re-fetch)
  });

  it("resolves remaining guids via code search and persists them", async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: "Assets/Scripts/S.cs" } });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Scripts/S.cs" } } });
    expect(guidCache.save).toHaveBeenCalledWith("https://api.github.com/o/r", { g1: "Assets/Scripts/S.cs" });
  });

  it("prefers the in-PR meta index over code search", async () => {
    const { deps, client } = makeDeps({
      files: [
        { path: "Assets/Foo.prefab", status: "modified" },
        { path: "Assets/S.cs.meta", status: "modified" },
      ],
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/S.cs.meta@head-sha": "guid: g1\n",
      },
      search: { g1: "Assets/Elsewhere.cs" },
    });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it("serves cached guids without searching", async () => {
    const { deps, client } = makeDeps({ cached: { g1: "Assets/Cached.cs" } });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Cached.cs" } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it("does not re-search a missed guid within the worker lifetime", async () => {
    const { deps, client } = makeDeps(); // search misses
    const handle = createHandler(deps);
    await resolveFully(handle, REQ);
    await resolveFully(handle, REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it("serves cached names even for guids that once missed in code search", async () => {
    // Since index resolutions now land in guidCache, a guid recorded as a miss can genuinely appear in the cache.
    // misses is the gatekeeper for "don't re-search", not for "don't emit the name"
    const { deps, client, guidCache } = makeDeps(); // search misses → g1 goes into misses
    const handler = createHandler(deps);
    await resolveFully(handler, REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    guidCache.data["https://api.github.com/o/r"] = { g1: "Assets/Later.cs" }; // as if an index resolution wrote it later
    const res = await resolveFully(handler, REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Later.cs" } } });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1); // no re-search
  });

  it("dedupes concurrent code searches for the same guid", async () => {
    // With the semantic default, multiple files run resolution concurrently: searches for the same guid fold into one
    const { deps, client } = makeDeps({ search: { g1: "Assets/S.cs" } });
    let release!: (v: string) => void;
    client.searchMetaByGuid.mockImplementation(
      () =>
        new Promise((r) => {
          release = r;
        }),
    );
    const handler = createHandler(deps);
    const [a, b] = [resolveFully(handler, REQ), resolveFully(handler, REQ)];
    await vi.waitFor(() => expect(client.searchMetaByGuid).toHaveBeenCalled());
    release("Assets/S.cs");
    const [ra, rb] = await Promise.all([a, b]);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(ra).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(rb).toEqual(ra);
  });

  it("keeps the diff usable when code search hits the rate limit", async () => {
    const twoGuids: DiffV2 = { ...DIFF, unresolvedGuids: ["g1", "g2"] };
    const { deps, client } = makeDeps({ diff: () => twoGuids });
    client.searchMetaByGuid.mockResolvedValueOnce("Assets/First.cs").mockRejectedValueOnce(new RateLimitError("x"));
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...twoGuids, resolved: { g1: "Assets/First.cs" } } });
  });

  it("does not treat Object.prototype members as cache hits (hostile guid)", async () => {
    const proto: DiffV2 = { ...DIFF, unresolvedGuids: ["constructor"] };
    const { deps, client } = makeDeps({ diff: () => proto, cached: { g9: "Assets/X.cs" } });
    const res = await resolveFully(createHandler(deps), REQ);
    // 'constructor' goes to search rather than a cache hit, and stays unresolved after missing
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "constructor");
    expect(res).toEqual({ ok: true, json: { ...proto, resolved: {} } });
  });

  it("caps code searches at 10 per request", async () => {
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many });
    await resolveFully(createHandler(deps), REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
  });

  it("does not count cached guids against the search cap", async () => {
    // If 2 of 12 guids are cached, the search budget of 10 can be spent entirely on the 10 unknown guids
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => many, cached: { g0: "Assets/A.cs", g1: "Assets/B.cs" } });
    const res = await resolveFully(createHandler(deps), REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
    expect(res).toEqual({ ok: true, json: { ...many, resolved: { g0: "Assets/A.cs", g1: "Assets/B.cs" } } });
  });

  it("maps AuthError / DiffError / other failures to stable error codes", async () => {
    const auth = makeDeps();
    auth.client.getPrRefs.mockRejectedValue(new AuthError("x"));
    expect(await resolveFully(createHandler(auth.deps), REQ)).toEqual({ ok: false, error: "auth-failed" });

    const bad = makeDeps({
      diff: () => {
        throw new DiffError("NestingTooDeep");
      },
    });
    expect(await resolveFully(createHandler(bad.deps), REQ)).toEqual({ ok: false, error: "diff-failed" });

    const net = makeDeps();
    net.client.listPrFiles.mockRejectedValue(new Error("socket"));
    expect(await resolveFully(createHandler(net.deps), REQ)).toEqual({ ok: false, error: "fetch-failed" });
  });

  it("returns too-large above 25MB unless forced", async () => {
    const big = new Uint8Array(13 * 1024 * 1024); // 26MB across base+head
    const diff = vi.fn(() => DIFF);
    const { deps, client } = makeDeps({ diff });
    client.getFileAtRef.mockResolvedValue(big);
    const handle = createHandler(deps);
    expect(await resolveFully(handle, REQ)).toEqual({ ok: false, error: "too-large", bytes: big.length * 2 });
    expect(diff).not.toHaveBeenCalled();
    // force proceeds to render. The blob is in the sha cache, so no re-fetch either
    const fetches = client.getFileAtRef.mock.calls.length;
    expect((await resolveFully(handle, { ...REQ, force: true })).ok).toBe(true);
    expect(diff).toHaveBeenCalledTimes(1);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetches);
  });

  it("renders exactly 25MB without the gate", async () => {
    const half = new Uint8Array((25 * 1024 * 1024) / 2);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(half);
    expect((await resolveFully(createHandler(deps), REQ)).ok).toBe(true);
  });

  it("maps RateLimitError to rate-limited", async () => {
    const limited = makeDeps();
    limited.client.getPrRefs.mockRejectedValue(new RateLimitError("x"));
    expect(await resolveFully(createHandler(limited.deps), REQ)).toEqual({ ok: false, error: "rate-limited" });
  });

  describe("source prefab merging", () => {
    // A diff where the first pass requests source supply. src1's path is resolved via Code Search.
    const NEEDS: DiffV2 = {
      ...DIFF,
      unresolvedGuids: ["src1"],
      neededSources: [{ guid: "src1", side: "after" }],
    };
    const MERGED: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["src1"], roots: [], loose: [] };

    it("fetches the resolved source at head and re-diffs with assets", async () => {
      const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
      const { deps, client } = makeDeps({
        diff: () => NEEDS,
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(createHandler(deps), REQ);
      // side=after, so the source is fetched from head and its bytes land in assets.
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Cyl.prefab", "head-sha");
      const assets = diffWithAssets.mock.calls[0]?.[2];
      expect(new TextDecoder().decode(assets.get("src1")!)).toBe("SRC");
      // Even after the re-diff, resolved is restored from guidCache and persists.
      expect(res).toEqual({ ok: true, json: { ...MERGED, resolved: { src1: "Assets/Cyl.prefab" } } });
    });

    it("fetches removed-instance sources from the base side", async () => {
      const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
      const { deps, client } = makeDeps({
        diff: () => ({ ...NEEDS, neededSources: [{ guid: "src1", side: "before" }] }),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@base-sha": "OLD",
        },
      });
      await resolveFully(createHandler(deps), REQ);
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Cyl.prefab", "base-sha");
    });

    it("keeps the first-pass diff when the source path cannot be resolved", async () => {
      const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => MERGED);
      const { deps } = makeDeps({ diff: () => NEEDS, diffWithAssets }); // search misses
      const res = await resolveFully(createHandler(deps), REQ);
      // An unknown-path source is given up on, returning the degraded view (the first-pass json) as-is.
      expect(diffWithAssets).not.toHaveBeenCalled();
      expect(res).toEqual({ ok: true, json: { ...NEEDS, resolved: {} } });
    });

    it("does not loop when the merged output still needs the same source", async () => {
      // If supplying still leaves it degraded (a broken source, etc.), don't loop forever on the same guid.
      const diffWithAssets = vi.fn<Differ["diffWithAssets"]>(() => NEEDS);
      const { deps } = makeDeps({
        diff: () => NEEDS,
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(createHandler(deps), REQ);
      expect(diffWithAssets).toHaveBeenCalledTimes(1);
      expect(res.ok).toBe(true);
    });

    it("still merges sources when serving a prefetched diff", async () => {
      // The crux of caching only the raw diff: the later stages (resolve → mergeSources) run every time, even on a cache hit
      const withSource: DiffV2 = {
        ...DIFF,
        unresolvedGuids: ["src1"],
        neededSources: [{ guid: "src1", side: "after" }],
      };
      const merged: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"] };
      const diffWithAssets = vi.fn(() => merged);
      const { deps, client } = makeDeps({
        files: [
          { path: "Assets/Foo.prefab", status: "modified" },
          { path: "Assets/Src.prefab.meta", status: "modified" },
        ],
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Src.prefab.meta@head-sha": "guid: src1\n",
          "Assets/Src.prefab@head-sha": "source prefab",
        },
        diff: () => withSource,
        diffWithAssets,
      });
      const handler = createHandler(deps);
      await handler.prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
      expect(diffWithAssets).not.toHaveBeenCalled(); // prefetch stops at raw
      const res = await resolveFully(handler, REQ);
      expect(res.ok).toBe(true);
      expect(diffWithAssets).toHaveBeenCalledTimes(1); // merging runs at serve time
    });
  });
});

describe("prefetch", () => {
  it("precomputes diffs so a later toggle serves without new blob fetches", async () => {
    const { deps, client } = makeDeps();
    const handler = createHandler(deps);
    await handler.prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled(); // prefetch doesn't touch the 10 req/min Code Search
    const fetchesAfterPrefetch = client.getFileAtRef.mock.calls.length;
    const res = await resolveFully(handler, REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetchesAfterPrefetch); // no blob re-fetch
  });

  it("persists prefetched diffs to the diff store (sw restart survival)", async () => {
    const { deps } = makeDeps();
    await createHandler(deps).prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(deps.diffStore.save).toHaveBeenCalledWith("base-sha:head-sha:Assets/Foo.prefab", DIFF);
  });

  it("serves a diff persisted by a previous worker from the store", async () => {
    // The SW dies after 30 seconds: a result prefetched in a prior life must be recoverable via storage.session
    const { deps, client, diffStore } = makeDeps();
    diffStore.data["base-sha:head-sha:Assets/Foo.prefab"] = DIFF; // seeded as if saved by a prior SW life
    const res = await resolveFully(createHandler(deps), REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).not.toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
  });

  it("prefetches only unity files and caps at 100", async () => {
    const files: PrFile[] = Array.from({ length: 120 }, (_, i) => ({
      path: `Assets/F${i}.prefab`,
      status: "modified",
    }));
    files.push({ path: "README.md", status: "modified" });
    const { deps, client } = makeDeps({ files });
    await createHandler(deps).prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    const paths = new Set(client.getFileAtRef.mock.calls.map((c) => c[2]));
    expect(paths.has("README.md")).toBe(false);
    expect(paths.size).toBe(100); // cut off at the cap
  });

  it("skips oversized files without caching them", async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(big);
    const handler = createHandler(deps);
    await handler.prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(deps.diffStore.save).not.toHaveBeenCalled();
    // A later manual toggle still shows the too-large gate as before
    expect(await resolveFully(handler, REQ)).toEqual({ ok: false, error: "too-large", bytes: big.length * 2 });
  });

  it("aborts silently on rate limit instead of surfacing an error", async () => {
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockRejectedValue(new RateLimitError("x"));
    await expect(
      createHandler(deps).prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 }),
    ).resolves.toBeUndefined();
  });

  it("returns without network when the pat is missing", async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    await createHandler(deps).prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });
});

it("dedupes a concurrent user toggle against an in-flight prefetch compute", async () => {
  // Even if the user clicks during prefetch, diff computation and blob fetches don't double up
  const { deps, client } = makeDeps();
  const handler = createHandler(deps);
  const [, res] = await Promise.all([
    handler.prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 }),
    resolveFully(handler, REQ),
  ]);
  expect(res.ok).toBe(true);
  const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === "Assets/Foo.prefab");
  expect(fooFetches).toHaveLength(2); // only twice, base + head
});

describe("semanticDiff with push (two-stage)", () => {
  it("responds immediately with pending and pushes code-search results in the final json", async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: "Assets/Scripts/S.cs" } });
    const { res, pushes } = await serveAndResolve(createHandler(deps), REQ);
    // The response returns immediately with empty resolved + pending. Names arrive via push (the crux of B4)
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} }, pending: true });
    const last = pushes.at(-1)!;
    expect(last.done).toBe(true);
    expect(last.json?.resolved).toEqual({ g1: "Assets/Scripts/S.cs" });
    expect(guidCache.save).toHaveBeenCalledWith("https://api.github.com/o/r", { g1: "Assets/Scripts/S.cs" });
  });

  it("does not set pending when the pr meta index resolves everything", async () => {
    const { deps } = makeDeps({
      files: [
        { path: "Assets/Foo.prefab", status: "modified" },
        { path: "Assets/S.cs.meta", status: "modified" },
      ],
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/S.cs.meta@head-sha": "guid: g1\n",
      },
    });
    const { res, pushes } = await serveAndResolve(createHandler(deps), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(pushes).toEqual([]); // if everything is resolved and no source merge is needed, there's no push
  });

  it("resolves via the repo index and only searches the leftover", async () => {
    const { deps, client } = makeDeps({
      diff: () => ({ ...DIFF, unresolvedGuids: ["g1", "g2"] }),
      search: { g2: "Assets/Other.cs" },
    });
    client.listMetaTree.mockResolvedValue({ truncated: false, metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }] });
    client.batchBlobTexts.mockResolvedValue({ sha1: "guid: g1\n" });
    const { pushes } = await serveAndResolve(createHandler(deps), REQ);
    // g1 arrives first from the index (intermediate push), and only g2, absent from the index, goes to Code Search (3-stage resolution)
    expect(pushes[0]).toMatchObject({ resolved: { g1: "Assets/S.cs" }, done: false });
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs", g2: "Assets/Other.cs" });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "g2");
  });

  it("falls back to code search when the tree is truncated", async () => {
    const { deps, client } = makeDeps({ search: { g1: "Assets/S.cs" } });
    client.listMetaTree.mockResolvedValue({ truncated: true, metas: [] });
    const { pushes } = await serveAndResolve(createHandler(deps), REQ);
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs" });
  });

  it("stops retrying the index for the session after an index rate limit", async () => {
    const { deps, client } = makeDeps();
    client.listMetaTree.mockRejectedValue(new RateLimitError("x"));
    const handler = createHandler(deps);
    await serveAndResolve(handler, REQ);
    await serveAndResolve(handler, REQ);
    expect(client.listMetaTree).toHaveBeenCalledTimes(1); // pinned to fallback for the SW lifetime
  });

  it("re-merges sources in the async stage once the source guid resolves", async () => {
    // The crux of mergeSources consistency: the immediate response comes back without merging,
    // and once the repo index resolves the source guid, the re-merged json arrives in the final push
    const withSource: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], neededSources: [{ guid: "src1", side: "after" }] };
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], resolved: { src1: "Assets/Src.prefab" } };
    const diffWithAssets = vi.fn(() => merged);
    const { deps, client } = makeDeps({
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/Src.prefab@head-sha": "source prefab",
      },
      diff: () => withSource,
      diffWithAssets,
    });
    client.listMetaTree.mockResolvedValue({
      truncated: false,
      metas: [{ path: "Assets/Src.prefab.meta", sha: "sha1" }],
    });
    client.batchBlobTexts.mockResolvedValue({ sha1: "guid: src1\n" });
    // Note: serveAndResolve waits for the done push, so by that point diffWithAssets has always been called
    // (done:true is only emitted after mergeSources completes). Asserting "not yet called" must be done
    // right after the immediate response (before waiting for the push to finish), so this one is assembled manually.
    const pushes: GuidResolvedPush[] = [];
    const res = await createHandler(deps).semanticDiff(REQ, (m) => pushes.push(m));
    expect(res.ok && res.pending).toBe(true);
    expect(diffWithAssets).not.toHaveBeenCalled(); // the immediate response doesn't merge (it takes priority)
    await vi.waitFor(() => expect(diffWithAssets).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
    expect(pushes.at(-1)?.json).toMatchObject({ resolved: { src1: "Assets/Src.prefab" } });
  });

  it("kicks the repo index sync from prefetch", async () => {
    const { deps, client } = makeDeps();
    await createHandler(deps).prefetch({ type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    await vi.waitFor(() => expect(client.listMetaTree).toHaveBeenCalledWith("o", "r", "head-sha"));
  });
});
