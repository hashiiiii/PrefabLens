import { describe, expect, it, vi } from "vitest";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { type DiffV2, emptyDiff } from "../../domain/diff/types";
import { err, ok } from "../../domain/result";
import { must } from "../../internal/must";
import type { DifferGateway } from "../gateway/differ";
import type { GuidResolvedPush } from "../gateway/messenger";
import { API_BASE } from "../internal/api-base";
import { DIFF, makeFakes, REQ, resolveFully, serveAndResolve } from "../internal/diff-fakes";
import { createDiffSession } from "./create-diff-session";
import { getSemanticDiff } from "./get-semantic-diff";
import { prefetchPr } from "./prefetch-pr";

describe("semanticDiff", () => {
  it("returns access-token-missing without touching the network", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      accessToken: undefined,
    });
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res).toEqual({ ok: false, error: "access-token-missing" });
    expect(calls.getPrRefs).toEqual([]);
  });

  it("refreshes PR context after 60s so new pushes are picked up", async () => {
    vi.useFakeTimers();
    try {
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes();
      const session = createDiffSession();
      // Fake timers make resolveFully's vi.waitFor hang. This test only needs the immediate response.
      await getSemanticDiff(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        session,
        REQ,
        () => {},
      );
      vi.setSystemTime(Date.now() + 59_000);
      await getSemanticDiff(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        session,
        REQ,
        () => {},
      );
      expect(calls.getPrRefs).toHaveLength(1);
      vi.setSystemTime(Date.now() + 2_000); // 61 seconds total
      await getSemanticDiff(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        session,
        REQ,
        () => {},
      );
      expect(calls.getPrRefs).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("prefers the in-PR meta index over code search", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
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
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(calls.searchMetaByGuid).toEqual([]);
  });

  it("serves cached guids without searching", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      cached: { g1: "Assets/Cached.cs" },
    });
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Cached.cs" } } });
    expect(calls.searchMetaByGuid).toEqual([]);
  });

  it("does not re-search a missed guid within the worker lifetime", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes(); // search misses
    const session = createDiffSession();
    await resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ);
    await resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ);
    expect(calls.searchMetaByGuid).toHaveLength(1);
  });

  it("serves cached names even for guids that once missed in code search", async () => {
    // Since index resolutions now land in guidCache, a guid recorded as a miss can genuinely appear in the cache.
    // misses is the gatekeeper for "do not re-search", not for "do not emit the name"
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes(); // The search misses, so g1 goes into misses.
    const session = createDiffSession();
    await resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ);
    expect(calls.searchMetaByGuid).toHaveLength(1);
    guidCache.data[repoKey(API_BASE, "o", "r")] = { g1: "Assets/Later.cs" }; // The seed simulates a later write by an index resolution.
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      session,
      REQ,
    );
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Later.cs" } } });
    expect(calls.searchMetaByGuid).toHaveLength(1); // no re-search
  });

  it("dedupes concurrent code searches for the same guid", async () => {
    // With the semantic default, multiple files run resolution concurrently: searches for the same guid share one request
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls, impls } = makeFakes({
      search: { g1: "Assets/S.cs" },
    });
    let release!: (v: ReturnType<typeof ok<string>>) => void;
    impls.searchMetaByGuid = () =>
      new Promise((r) => {
        release = r;
      });
    const session = createDiffSession();
    const [a, b] = [
      resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ),
      resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ),
    ];
    await vi.waitFor(() => expect(calls.searchMetaByGuid).not.toHaveLength(0));
    release(ok("Assets/S.cs"));
    const [ra, rb] = await Promise.all([a, b]);
    expect(calls.searchMetaByGuid).toHaveLength(1);
    expect(ra).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(rb).toEqual(ra);
  });

  it("keeps the diff usable when code search hits the rate limit", async () => {
    const twoGuids: DiffV2 = { ...DIFF, unresolvedGuids: ["g1", "g2"] };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, results } = makeFakes({
      diff: () => ok(twoGuids),
    });
    results.searchMetaByGuid = [ok("Assets/First.cs"), err({ kind: "rate-limited" as const })];
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res).toEqual({ ok: true, json: { ...twoGuids, resolved: { g1: "Assets/First.cs" } } });
  });

  it("does not treat Object.prototype members as cache hits (hostile guid)", async () => {
    const proto: DiffV2 = { ...DIFF, unresolvedGuids: ["constructor"] };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      diff: () => ok(proto),
      cached: { g9: "Assets/X.cs" },
    });
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    // 'constructor' goes to search rather than a cache hit, and stays unresolved after missing
    expect(calls.searchMetaByGuid).toContainEqual(["o", "r", "constructor"]);
    expect(res).toEqual({ ok: true, json: { ...proto, resolved: {} } });
  });

  it("caps code searches at 10 per request", async () => {
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      diff: () => ok(many),
    });
    await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(calls.searchMetaByGuid).toHaveLength(10);
  });

  it("does not count cached guids against the search cap", async () => {
    // If 2 of 12 guids are cached, the search budget of 10 can be spent entirely on the 10 unknown guids
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      diff: () => ok(many),
      cached: { g0: "Assets/A.cs", g1: "Assets/B.cs" },
    });
    const res = await resolveFully(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(calls.searchMetaByGuid).toHaveLength(10);
    expect(res).toEqual({ ok: true, json: { ...many, resolved: { g0: "Assets/A.cs", g1: "Assets/B.cs" } } });
  });

  describe("source prefab merging", () => {
    // A diff where the first pass requests source supply. src1's path is resolved via Code Search.
    const NEEDS: DiffV2 = {
      ...DIFF,
      unresolvedGuids: ["src1"],
      neededSources: [{ guid: "src1", side: "after" }],
    };
    const MERGED: DiffV2 = { ...emptyDiff(), unresolvedGuids: ["src1"], roots: [], loose: [] };

    it("fetches the resolved source at head and re-diffs with assets", async () => {
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        return ok(MERGED);
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
        diff: () => ok(NEEDS),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      // side=after, so the source is fetched from head and its bytes land in assets.
      expect(calls.getFileAtRef).toContainEqual(["o", "r", "Assets/Cyl.prefab", "head-sha"]);
      const assets = must(diffWithAssetsCalls[0]?.[2]);
      expect(new TextDecoder().decode(must(assets.get("src1")))).toBe("SRC");
      // Even after the re-diff, resolved is restored from guidCache and persists.
      expect(res).toEqual({ ok: true, json: { ...MERGED, resolved: { src1: "Assets/Cyl.prefab" } } });
    });

    it("fetches removed-instance sources from the base side", async () => {
      const diffWithAssets: DifferGateway["diffWithAssets"] = () => ok(MERGED);
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
        diff: () => ok({ ...NEEDS, neededSources: [{ guid: "src1", side: "before" }] }),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@base-sha": "OLD",
        },
      });
      await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      expect(calls.getFileAtRef).toContainEqual(["o", "r", "Assets/Cyl.prefab", "base-sha"]);
    });

    it("fetches a before-side source riding the base-tree blob sha", async () => {
      const diffWithAssets: DifferGateway["diffWithAssets"] = () => ok(MERGED);
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
        diff: () => ok({ ...NEEDS, neededSources: [{ guid: "src1", side: "before" }] }),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        baseShas: { "Assets/Cyl.prefab": "cyl-base" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@base-sha": "OLD",
        },
      });
      await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      // A blob-sha miss uses path+ref instead. Both seams are exercised.
      expect(calls.getBlobRaw).toContainEqual(["o", "r", "cyl-base"]);
      expect(calls.getFileAtRef).toContainEqual(["o", "r", "Assets/Cyl.prefab", "base-sha"]);
    });

    it("skips binary-serialized sources without counting them as progress", async () => {
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        return ok(MERGED);
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
        diff: () => ok(NEEDS),
        diffWithAssets,
        // Main prefab sides stay YAML. Only the fetched source is treated as binary.
        isUnityYaml: (bytes) => !new TextDecoder().decode(bytes).includes("\x00"),
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "\x00binary",
        },
      });
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      // A binary-source merge is a no-op re-diff: give up and keep the first pass.
      expect(diffWithAssetsCalls).toEqual([]);
      expect(res).toEqual({ ok: true, json: { ...NEEDS, resolved: { src1: "Assets/Cyl.prefab" } } });
    });

    it("caps source re-diff rounds at 3 even while progressing", async () => {
      // Each merge output requests the next source, which always resolves: without the cap,
      // a deep source chain re-diffs forever.
      let round = 0;
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        round += 1;
        return ok({
          ...DIFF,
          unresolvedGuids: [`s${round}`],
          neededSources: [{ guid: `s${round}`, side: "after" }],
        });
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
        // applyResolved rebuilds `resolved` from the PR index only. Seed names via guidCache.
        diff: () =>
          ok({
            ...DIFF,
            unresolvedGuids: ["s0"],
            neededSources: [{ guid: "s0", side: "after" }],
          }),
        diffWithAssets,
        cached: { s0: "Assets/S0.prefab", s1: "Assets/S1.prefab", s2: "Assets/S2.prefab", s3: "Assets/S3.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/S0.prefab@head-sha": "S0",
          "Assets/S1.prefab@head-sha": "S1",
          "Assets/S2.prefab@head-sha": "S2",
        },
      });
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      expect(diffWithAssetsCalls).toHaveLength(3);
      expect(res.ok && res.json.neededSources).toEqual([{ guid: "s3", side: "after" }]); // degraded at the cap
    });

    it("keeps the first-pass diff when the source path cannot be resolved", async () => {
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        return ok(MERGED);
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
        diff: () => ok(NEEDS),
        diffWithAssets,
      }); // search misses
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      // An unknown-path source is given up on, returning the degraded view (the first-pass json) as-is.
      expect(diffWithAssetsCalls).toEqual([]);
      expect(res).toEqual({ ok: true, json: { ...NEEDS, resolved: {} } });
    });

    it("does not loop when the merged output still needs the same source", async () => {
      // If the supply still leaves the diff degraded (for example a broken source), the loop must not repeat forever on the same guid.
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        return ok(NEEDS);
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
        diff: () => ok(NEEDS),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        createDiffSession(),
        REQ,
      );
      expect(diffWithAssetsCalls).toHaveLength(1);
      expect(res.ok).toBe(true);
    });

    it("still merges sources when serving a prefetched diff", async () => {
      // Caching only the raw diff lets resolution and source merging run again after every cache hit.
      const withSource: DiffV2 = {
        ...DIFF,
        unresolvedGuids: ["src1"],
        neededSources: [{ guid: "src1", side: "after" }],
      };
      const merged: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"] };
      const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
      const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
        diffWithAssetsCalls.push(args);
        return ok(merged);
      };
      const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
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
        diff: () => ok(withSource),
        diffWithAssets,
      });
      const session = createDiffSession();
      await prefetchPr(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, session, {
        type: "prefetch",
        owner: "o",
        repo: "r",
        prNumber: 1,
      });
      expect(diffWithAssetsCalls).toEqual([]); // prefetch stops at raw
      const res = await resolveFully(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        session,
        REQ,
      );
      expect(res.ok).toBe(true);
      expect(diffWithAssetsCalls).toHaveLength(1); // merging runs at serve time
    });
  });
});

it("dedupes a concurrent user toggle against an in-flight prefetch compute", async () => {
  // Even if the user clicks during prefetch, the diff computation and the blob fetches do not run twice
  const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes();
  const session = createDiffSession();
  const [, res] = await Promise.all([
    prefetchPr(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, session, {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    }),
    resolveFully(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ),
  ]);
  expect(res.ok).toBe(true);
  const fooFetches = calls.getFileAtRef.filter((c) => c[2] === "Assets/Foo.prefab");
  expect(fooFetches).toHaveLength(2); // only twice, base + head
});

describe("semanticDiff with push (two-stage)", () => {
  it("responds immediately with pending and pushes code-search results in the final json", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
      search: { g1: "Assets/Scripts/S.cs" },
    });
    const { res, pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    // The response returns immediately with empty resolved + pending. Names arrive via push (the crux of B4)
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} }, pending: true });
    const last = must(pushes.at(-1));
    expect(last.done).toBe(true);
    expect(last.json?.resolved).toEqual({ g1: "Assets/Scripts/S.cs" });
    expect(guidCache.saves).toContainEqual([repoKey(API_BASE, "o", "r"), { g1: "Assets/Scripts/S.cs" }]);
  });

  it("does not set pending when the pr meta index resolves everything", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore } = makeFakes({
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
    const { res, pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(pushes).toEqual([]); // If everything is resolved and no source merge is needed, there is no push.
  });

  it("resolves via the repo index and only searches the leftover", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls, results } = makeFakes({
      diff: () => ok({ ...DIFF, unresolvedGuids: ["g1", "g2"] }),
      search: { g2: "Assets/Other.cs" },
    });
    results.listMetaTree = ok({ truncated: false, metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }] });
    results.batchBlobTexts = ok({ sha1: "guid: g1\n" });
    const { pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    // g1 arrives first from the index (intermediate push), and only g2, absent from the index, goes to Code Search (3-stage resolution)
    expect(pushes[0]).toMatchObject({ resolved: { g1: "Assets/S.cs" }, done: false });
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs", g2: "Assets/Other.cs" });
    expect(calls.searchMetaByGuid).toHaveLength(1);
    expect(calls.searchMetaByGuid).toContainEqual(["o", "r", "g2"]);
  });

  it("falls back to code search when the tree is truncated", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, results } = makeFakes({
      search: { g1: "Assets/S.cs" },
    });
    results.listMetaTree = ok({ truncated: true, metas: [] });
    const { pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs" });
  });

  it("stops retrying the index for the session after an index rate limit", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls, results } = makeFakes();
    results.listMetaTree = err({ kind: "rate-limited" as const });
    const session = createDiffSession();
    await serveAndResolve(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ);
    await serveAndResolve(tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, session, REQ);
    expect(calls.listMetaTree).toHaveLength(1); // pinned to fallback for the SW lifetime
  });

  it("skips the index when only a source re-merge is pending", async () => {
    // The first index build can take tens of seconds and cannot help: no guid names are missing.
    // Resolve the source guid via the in-PR .meta index so remaining is empty but neededSources remains.
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: [] };
    const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
    const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
      diffWithAssetsCalls.push(args);
      return ok(merged);
    };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, calls } = makeFakes({
      files: [
        { path: "Assets/Foo.prefab", status: "modified" },
        { path: "Assets/Src.prefab.meta", status: "modified" },
      ],
      diff: () =>
        ok({
          ...DIFF,
          unresolvedGuids: ["src1"],
          neededSources: [{ guid: "src1", side: "after" }],
        }),
      diffWithAssets,
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/Src.prefab.meta@head-sha": "guid: src1\n",
        "Assets/Src.prefab@head-sha": "SRC",
      },
    });
    const { pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(calls.listMetaTree).toEqual([]);
    expect(diffWithAssetsCalls).toHaveLength(1);
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "complete" });
  });

  it("marks the final push rateLimited when Code Search hits the limit", async () => {
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, results } = makeFakes();
    results.searchMetaByGuid = err({ kind: "rate-limited" as const });
    const { pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("still emits the done push, marked failed, when source fetch fails during re-merge", async () => {
    // Waiters key on done: a crash that drops it leaves the indicator spinning forever.
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, impls } = makeFakes({
      diff: () =>
        ok({
          ...DIFF,
          unresolvedGuids: ["src1"],
          neededSources: [{ guid: "src1", side: "after" }],
        }),
      cached: { src1: "Assets/Src.prefab" },
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
      },
    });
    impls.getFileAtRef = async (_o, _r, path, ref) => {
      if (path === "Assets/Src.prefab") return err({ kind: "fetch-failed" as const });
      const contents: Record<string, string> = {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
      };
      const text = contents[`${path}@${ref}`];
      return ok(text === undefined ? null : new TextEncoder().encode(text));
    };
    const { pushes } = await serveAndResolve(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
    );
    expect(must(pushes.at(-1))).toMatchObject({ done: true, status: "failed" });
  });

  it("re-merges sources in the async stage once the source guid resolves", async () => {
    // The immediate response avoids waiting for source merging. The final push supplies the merged JSON after GUID resolution.
    const withSource: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], neededSources: [{ guid: "src1", side: "after" }] };
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], resolved: { src1: "Assets/Src.prefab" } };
    const diffWithAssetsCalls: Array<Parameters<DifferGateway["diffWithAssets"]>> = [];
    const diffWithAssets: DifferGateway["diffWithAssets"] = (...args) => {
      diffWithAssetsCalls.push(args);
      return ok(merged);
    };
    const { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, results } = makeFakes({
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/Src.prefab@head-sha": "source prefab",
      },
      diff: () => ok(withSource),
      diffWithAssets,
    });
    results.listMetaTree = ok({
      truncated: false,
      metas: [{ path: "Assets/Src.prefab.meta", sha: "sha1" }],
    });
    results.batchBlobTexts = ok({ sha1: "guid: src1\n" });
    // Note: serveAndResolve waits for the done push, and by that point diffWithAssets always ran
    // A terminal push occurs after source merging, so the early assertion must run immediately after the response.
    const pushes: GuidResolvedPush[] = [];
    const res = await getSemanticDiff(
      tokenStore,
      makeClient,
      getDiffer,
      guidCache,
      diffStore,
      repoIndexStore,
      createDiffSession(),
      REQ,
      (m) => pushes.push(m),
    );
    expect(res.ok && res.pending).toBe(true);
    expect(diffWithAssetsCalls).toEqual([]); // the immediate response does not merge (it takes priority)
    await vi.waitFor(() => expect(diffWithAssetsCalls).toHaveLength(1));
    await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
    expect(pushes.at(-1)?.json).toMatchObject({ resolved: { src1: "Assets/Src.prefab" } });
  });

  it("kicks the repo index sync from prefetch", async () => {
    const { tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, calls } = makeFakes();
    await prefetchPr(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, createDiffSession(), {
      type: "prefetch",
      owner: "o",
      repo: "r",
      prNumber: 1,
    });
    await vi.waitFor(() => expect(calls.listMetaTree).toContainEqual(["o", "r", "head-sha"]));
  });
});
