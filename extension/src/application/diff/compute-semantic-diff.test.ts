import { describe, expect, it, vi } from "vitest";
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
import { must } from "../../domain/must";
import { err, ok } from "../../domain/result";
import type { DifferPort } from "../port/differ";
import type { ChangedFile } from "../port/github";
import { createDiffSession, type DiffSession } from "./_diff-session";
import { computeSemanticDiff, type DiffDeps } from "./compute-semantic-diff";
import { prefetchPr } from "./prefetch-pr";

const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: ChangedFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  blobs?: Record<string, string>; // blob sha → text (getBlobRaw; absent sha = 404 → null)
  baseShas?: Record<string, string>; // path → blob sha at the merge base (listBlobShas)
  diff?: DifferPort["diff"];
  diffWithAssets?: DifferPort["diffWithAssets"];
  isUnityYaml?: DifferPort["isUnityYaml"];
  accessToken?: string | undefined;
  search?: Record<string, string | null>; // guid → asset path (null = no hit)
  cached?: Record<string, string>; // initial contents of guidCache
}) {
  const files = overrides?.files ?? [{ path: "Assets/Foo.prefab", status: "modified" }];
  const contents = overrides?.contents ?? { "Assets/Foo.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" };
  const getFileAtRef = vi.fn(async (_o: string, _r: string, path: string, ref: string) => {
    const text = contents[`${path}@${ref}`];
    return ok(text === undefined ? null : new TextEncoder().encode(text));
  });
  const client = {
    getPrRefs: vi.fn(async () => ok({ baseSha: "base-sha", headSha: "head-sha" })),
    listPrFiles: vi.fn(async () => ok(files)),
    // Commit/compare fakes mirror the PR refs so the same contents table serves every target kind
    getCommit: vi.fn(async () => ok({ sha: "head-sha", parentSha: "base-sha" as string | null, files })),
    compareRefs: vi.fn(async () => ok({ mergeBaseSha: "base-sha", files })),
    resolveRefSha: vi.fn(async () => ok("head-sha")),
    getFileAtRef,
    getBlobRaw: vi.fn(async (_o: string, _r: string, sha: string) => {
      const text = overrides?.blobs?.[sha];
      return ok(text === undefined ? null : new TextEncoder().encode(text));
    }),
    listBlobShas: vi.fn(async () =>
      ok({
        truncated: false,
        byPath: new Map(Object.entries(overrides?.baseShas ?? {})),
      }),
    ),
    searchMetaByGuid: vi.fn(async (_o: string, _r: string, guid: string) => ok(overrides?.search?.[guid] ?? null)),
    listMetaTree: vi.fn(async () =>
      ok({
        truncated: false,
        metas: [] as Array<{ path: string; sha: string }>,
      }),
    ),
    batchBlobTexts: vi.fn(async () => ok({})),
  };
  const differ: DifferPort = {
    diff: overrides?.diff ?? vi.fn(() => ok(DIFF)),
    diffWithAssets: overrides?.diffWithAssets ?? vi.fn(() => ok(DIFF)),
    // Fixture contents are shorthand strings, not real UnityYAML: accept by default.
    isUnityYaml: overrides?.isUnityYaml ?? (() => true),
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
  const deps: DiffDeps = {
    getSettings: async () => ({
      accessToken: Object.hasOwn(overrides ?? {}, "accessToken") ? overrides?.accessToken : "tok",
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
  deps: DiffDeps,
  session: DiffSession,
  req: SemanticDiffRequest,
): Promise<{ res: SemanticDiffResponse; pushes: GuidResolvedPush[] }> {
  const pushes: GuidResolvedPush[] = [];
  const res = await computeSemanticDiff(deps, session, req, (m) => pushes.push(m));
  if (res.ok && res.pending) await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  return { res, pushes };
}

/** Drives semanticDiff to completion — the immediate response plus every push — and returns the
 *  fully-resolved response. Errors and fully-in-PR-resolved diffs pass through unchanged; a pending
 *  diff resolves to the final push's json, i.e. what the pipeline ultimately produces. */
async function resolveFully(
  deps: DiffDeps,
  session: DiffSession,
  req: SemanticDiffRequest,
): Promise<SemanticDiffResponse> {
  const pushes: GuidResolvedPush[] = [];
  const res = await computeSemanticDiff(deps, session, req, (m) => pushes.push(m));
  if (!res.ok || !res.pending) return res;
  await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  const final = pushes.at(-1);
  return final?.json ? { ok: true, json: final.json } : res;
}

describe("semanticDiff", () => {
  it("returns access-token-missing without touching the network", async () => {
    const { deps, client } = makeDeps({ accessToken: undefined });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: false, error: "access-token-missing" });
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
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
  });

  it("serves a commit target from the commit API with the first parent as base", async () => {
    const { deps, client } = makeDeps();
    const res = await resolveFully(deps, createDiffSession(), { ...REQ, target: { kind: "commit", sha: "head-sha" } });
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} } });
    expect(client.getCommit).toHaveBeenCalledWith("o", "r", "head-sha");
    expect(client.getPrRefs).not.toHaveBeenCalled(); // commit pages never touch the PR API
  });

  it("serves a root commit (no parent) as an all-added diff", async () => {
    const files = [{ path: "Assets/Foo.prefab", status: "added", sha: "blob-head" }];
    const { deps, client } = makeDeps({ files, blobs: { "blob-head": "a" } });
    client.getCommit.mockResolvedValue(ok({ sha: "head-sha", parentSha: null, files }));
    const res = await resolveFully(deps, createDiffSession(), { ...REQ, target: { kind: "commit", sha: "head-sha" } });
    // The before side is never fetched for added files, so a missing parent is harmless
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} } });
  });

  it("serves a compare target from the merge base and resolves the head ref", async () => {
    const { deps, client } = makeDeps();
    const res = await resolveFully(deps, createDiffSession(), {
      ...REQ,
      target: { kind: "compare", base: "main", head: "feature" },
    });
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} } });
    expect(client.compareRefs).toHaveBeenCalledWith("o", "r", "main", "feature");
    // Cache keys need an immutable sha, not a branch name that a push would silently move
    expect(client.resolveRefSha).toHaveBeenCalledWith("o", "r", "feature");
  });

  it("uses an empty before for added files without fetching the base side", async () => {
    const diff = vi.fn<DifferPort["diff"]>(() => ok(DIFF));
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Foo.prefab", status: "added" }], diff });
    await resolveFully(deps, createDiffSession(), REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === "Assets/Foo.prefab" && c[3] === "base-sha",
    );
    expect(baseFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[0]).toHaveLength(0); // before is empty
  });

  it("uses an empty after for removed files without fetching the head side", async () => {
    const diff = vi.fn<DifferPort["diff"]>(() => ok(DIFF));
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Foo.prefab", status: "removed" }], diff });
    await resolveFully(deps, createDiffSession(), REQ);
    const headFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === "Assets/Foo.prefab" && c[3] === "head-sha",
    );
    expect(headFetches).toHaveLength(0);
    expect(diff.mock.calls[0]?.[1]).toHaveLength(0); // after is empty
  });

  it("rejects a file whose content is not UnityYAML on either side", async () => {
    // Real sniff behavior lives in differ.test.ts; here the fake reproduces its
    // contract so the outcome plumbing (computeDiff -> response) is what's tested.
    const diff = vi.fn<DifferPort["diff"]>(() => ok(DIFF));
    const { deps } = makeDeps({
      contents: { "Assets/Foo.prefab@base-sha": "\x00binary", "Assets/Foo.prefab@head-sha": "\x00binary2" },
      diff,
      isUnityYaml: () => false,
    });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: false, error: "not-unity-yaml" });
    // The differ must not even run on rejected content.
    expect(diff).not.toHaveBeenCalled();
  });

  it("caches the not-unity-yaml outcome for the sha pair", async () => {
    // Unlike too-large there is no force escape hatch: the verdict is
    // deterministic for a given blob pair, so a second toggle must serve the
    // cached outcome instead of re-fetching and re-sniffing.
    const isUnityYaml = vi.fn<DifferPort["isUnityYaml"]>(() => false);
    const { deps } = makeDeps({ isUnityYaml });
    const session = createDiffSession();
    expect(await computeSemanticDiff(deps, session, REQ, () => {})).toEqual({ ok: false, error: "not-unity-yaml" });
    const sniffs = isUnityYaml.mock.calls.length;
    expect(await computeSemanticDiff(deps, session, REQ, () => {})).toEqual({ ok: false, error: "not-unity-yaml" });
    expect(isUnityYaml.mock.calls.length).toBe(sniffs);
  });

  it("diffs a file missing from the PR list as modified (files API caps at 3000)", async () => {
    // In a PR with over 3000 files, the listing API is truncated, so a file present in the UI may be absent from the listing
    const { deps, client } = makeDeps({ files: [{ path: "Assets/Other.prefab", status: "modified" }] });
    const res = await resolveFully(deps, createDiffSession(), REQ);
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
      return ok(new TextEncoder().encode("x"));
    });
    await resolveFully(deps, createDiffSession(), REQ);
    expect(maxInFlight).toBe(2);
  });

  it("reads renamed files from previousPath on the base side", async () => {
    const { deps, client } = makeDeps({
      files: [{ path: "Assets/Foo.prefab", status: "renamed", previousPath: "Assets/Old.prefab" }],
      contents: { "Assets/Old.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" },
    });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Old.prefab", "base-sha");
  });

  it("caches PR context across calls (refs/files/guid index fetched once)", async () => {
    const { deps, client } = makeDeps();
    const session = createDiffSession();
    await resolveFully(deps, session, REQ);
    await resolveFully(deps, session, { ...REQ, path: "Assets/Foo.prefab" });
    expect(client.getPrRefs).toHaveBeenCalledTimes(1);
    expect(client.listPrFiles).toHaveBeenCalledTimes(1);
  });

  it("refreshes PR context after 60s so new pushes are picked up", async () => {
    vi.useFakeTimers();
    try {
      const { deps, client } = makeDeps();
      const session = createDiffSession();
      // Fake timers make resolveFully's vi.waitFor hang; this test only needs the immediate response.
      await computeSemanticDiff(deps, session, REQ, () => {});
      vi.setSystemTime(Date.now() + 59_000);
      await computeSemanticDiff(deps, session, REQ, () => {});
      expect(client.getPrRefs).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 2_000); // 61 seconds total
      await computeSemanticDiff(deps, session, REQ, () => {});
      expect(client.getPrRefs).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("retries the PR context after a failed load instead of caching the failure", async () => {
    // If a transient network failure lands in the 60s cache, re-toggling would no longer fix it
    const { deps, client } = makeDeps();
    client.listPrFiles.mockResolvedValueOnce(err({ kind: "fetch-failed" as const }) as never);
    const session = createDiffSession();
    expect(await resolveFully(deps, session, REQ)).toEqual({ ok: false, error: "fetch-failed" });
    expect((await resolveFully(deps, session, REQ)).ok).toBe(true);
  });

  it("fetches each sha+path blob only once (immutable content)", async () => {
    const { deps, client } = makeDeps();
    const session = createDiffSession();
    await resolveFully(deps, session, REQ);
    await resolveFully(deps, session, REQ);
    const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === "Assets/Foo.prefab");
    expect(fooFetches).toHaveLength(2); // only twice, base + head (the second handle doesn't re-fetch)
  });

  it("resolves remaining guids via code search and persists them", async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: "Assets/Scripts/S.cs" } });
    const res = await resolveFully(deps, createDiffSession(), REQ);
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
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it("serves cached guids without searching", async () => {
    const { deps, client } = makeDeps({ cached: { g1: "Assets/Cached.cs" } });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Cached.cs" } } });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled();
  });

  it("does not re-search a missed guid within the worker lifetime", async () => {
    const { deps, client } = makeDeps(); // search misses
    const session = createDiffSession();
    await resolveFully(deps, session, REQ);
    await resolveFully(deps, session, REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
  });

  it("serves cached names even for guids that once missed in code search", async () => {
    // Since index resolutions now land in guidCache, a guid recorded as a miss can genuinely appear in the cache.
    // misses is the gatekeeper for "don't re-search", not for "don't emit the name"
    const { deps, client, guidCache } = makeDeps(); // search misses → g1 goes into misses
    const session = createDiffSession();
    await resolveFully(deps, session, REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    guidCache.data["https://api.github.com/o/r"] = { g1: "Assets/Later.cs" }; // as if an index resolution wrote it later
    const res = await resolveFully(deps, session, REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/Later.cs" } } });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1); // no re-search
  });

  it("dedupes concurrent code searches for the same guid", async () => {
    // With the semantic default, multiple files run resolution concurrently: searches for the same guid fold into one
    const { deps, client } = makeDeps({ search: { g1: "Assets/S.cs" } });
    let release!: (v: ReturnType<typeof ok<string>>) => void;
    client.searchMetaByGuid.mockImplementation(
      () =>
        new Promise((r) => {
          release = r;
        }),
    );
    const session = createDiffSession();
    const [a, b] = [resolveFully(deps, session, REQ), resolveFully(deps, session, REQ)];
    await vi.waitFor(() => expect(client.searchMetaByGuid).toHaveBeenCalled());
    release(ok("Assets/S.cs"));
    const [ra, rb] = await Promise.all([a, b]);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(ra).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(rb).toEqual(ra);
  });

  it("keeps the diff usable when code search hits the rate limit", async () => {
    const twoGuids: DiffV2 = { ...DIFF, unresolvedGuids: ["g1", "g2"] };
    const { deps, client } = makeDeps({ diff: () => ok(twoGuids) });
    client.searchMetaByGuid
      .mockResolvedValueOnce(ok("Assets/First.cs"))
      .mockResolvedValueOnce(err({ kind: "rate-limited" as const }) as never);
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: true, json: { ...twoGuids, resolved: { g1: "Assets/First.cs" } } });
  });

  it("does not treat Object.prototype members as cache hits (hostile guid)", async () => {
    const proto: DiffV2 = { ...DIFF, unresolvedGuids: ["constructor"] };
    const { deps, client } = makeDeps({ diff: () => ok(proto), cached: { g9: "Assets/X.cs" } });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    // 'constructor' goes to search rather than a cache hit, and stays unresolved after missing
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "constructor");
    expect(res).toEqual({ ok: true, json: { ...proto, resolved: {} } });
  });

  it("caps code searches at 10 per request", async () => {
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => ok(many) });
    await resolveFully(deps, createDiffSession(), REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
  });

  it("does not count cached guids against the search cap", async () => {
    // If 2 of 12 guids are cached, the search budget of 10 can be spent entirely on the 10 unknown guids
    const many: DiffV2 = { ...DIFF, unresolvedGuids: Array.from({ length: 12 }, (_, i) => `g${i}`) };
    const { deps, client } = makeDeps({ diff: () => ok(many), cached: { g0: "Assets/A.cs", g1: "Assets/B.cs" } });
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(10);
    expect(res).toEqual({ ok: true, json: { ...many, resolved: { g0: "Assets/A.cs", g1: "Assets/B.cs" } } });
  });

  it("maps auth-failed / diff-failed / other failures to stable error codes", async () => {
    const auth = makeDeps();
    auth.client.getPrRefs.mockResolvedValue(err({ kind: "auth-failed" as const }) as never);
    expect(await resolveFully(auth.deps, createDiffSession(), REQ)).toEqual({ ok: false, error: "auth-failed" });

    const bad = makeDeps({
      diff: () => err({ kind: "diff-failed", message: "NestingTooDeep" }),
    });
    expect(await resolveFully(bad.deps, createDiffSession(), REQ)).toEqual({ ok: false, error: "diff-failed" });

    const net = makeDeps();
    net.client.listPrFiles.mockResolvedValue(err({ kind: "fetch-failed" as const }) as never);
    expect(await resolveFully(net.deps, createDiffSession(), REQ)).toEqual({ ok: false, error: "fetch-failed" });
  });

  it("returns too-large above 25MB unless forced", async () => {
    const big = new Uint8Array(13 * 1024 * 1024); // 26MB across base+head
    const diff = vi.fn(() => ok(DIFF));
    const { deps, client } = makeDeps({ diff });
    client.getFileAtRef.mockResolvedValue(ok(big));
    const session = createDiffSession();
    expect(await resolveFully(deps, session, REQ)).toEqual({ ok: false, error: "too-large", bytes: big.length * 2 });
    expect(diff).not.toHaveBeenCalled();
    // force proceeds to render. The blob is in the sha cache, so no re-fetch either
    const fetches = client.getFileAtRef.mock.calls.length;
    expect((await resolveFully(deps, session, { ...REQ, force: true })).ok).toBe(true);
    expect(diff).toHaveBeenCalledTimes(1);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetches);
  });

  it("renders exactly 25MB without the gate", async () => {
    const half = new Uint8Array((25 * 1024 * 1024) / 2);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(ok(half));
    expect((await resolveFully(deps, createDiffSession(), REQ)).ok).toBe(true);
  });

  it("maps rate-limited failure to rate-limited", async () => {
    const limited = makeDeps();
    limited.client.getPrRefs.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
    expect(await resolveFully(limited.deps, createDiffSession(), REQ)).toEqual({ ok: false, error: "rate-limited" });
  });

  describe("blob-sha fetching", () => {
    // contents-by-path has erratic multi-second TTFB (#110): whenever the blob sha is known
    // (files API for head, merge-base tree for base), fetch by sha and leave path+ref as the fallback.
    it("fetches base and head by blob sha without touching the contents api", async () => {
      const { deps, client } = makeDeps({
        files: [
          { path: "Assets/Foo.prefab", status: "modified", sha: "foo-head" },
          { path: "Assets/S.cs.meta", status: "modified", sha: "meta-head" },
        ],
        blobs: { "foo-head": "a", "foo-base": "b", "meta-head": "guid: g1\n" },
        baseShas: { "Assets/Foo.prefab": "foo-base" },
        contents: {},
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      // the guid index also reads the changed .meta by its files-api sha
      expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
      expect(client.getBlobRaw).toHaveBeenCalledWith("o", "r", "foo-base");
      expect(client.getBlobRaw).toHaveBeenCalledWith("o", "r", "foo-head");
      expect(client.getFileAtRef).not.toHaveBeenCalled();
    });

    it("uses the files-api sha for the base side of removed files", async () => {
      const diff = vi.fn<DifferPort["diff"]>(() => ok(DIFF));
      const { deps, client } = makeDeps({
        files: [{ path: "Assets/Foo.prefab", status: "removed", sha: "foo-base" }],
        blobs: { "foo-base": "b" },
        contents: {},
        diff,
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res.ok).toBe(true);
      expect(client.getBlobRaw).toHaveBeenCalledWith("o", "r", "foo-base");
      expect(client.getFileAtRef).not.toHaveBeenCalled();
      expect(diff.mock.calls[0]?.[1]).toHaveLength(0); // after stays empty
    });

    it("looks up renamed base blobs under previousPath in the base tree", async () => {
      const { deps, client } = makeDeps({
        files: [{ path: "Assets/Foo.prefab", status: "renamed", previousPath: "Assets/Old.prefab", sha: "foo-head" }],
        blobs: { "foo-head": "a", "old-base": "b" },
        baseShas: { "Assets/Old.prefab": "old-base" },
        contents: {},
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res.ok).toBe(true);
      expect(client.getBlobRaw).toHaveBeenCalledWith("o", "r", "old-base");
      expect(client.getFileAtRef).not.toHaveBeenCalled();
    });

    it("falls back to the contents api for the base side when the tree is truncated", async () => {
      const { deps, client } = makeDeps({
        files: [{ path: "Assets/Foo.prefab", status: "modified", sha: "foo-head" }],
        blobs: { "foo-head": "a" },
        contents: { "Assets/Foo.prefab@base-sha": "b" },
      });
      client.listBlobShas.mockResolvedValue(ok({ truncated: true, byPath: new Map() }));
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res.ok).toBe(true);
      expect(client.getBlobRaw).toHaveBeenCalledWith("o", "r", "foo-head");
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
    });

    it("falls back to the contents api when the blob fetch 404s", async () => {
      // a force push between the files listing and the blob fetch can strand the sha
      const { deps, client } = makeDeps({
        files: [{ path: "Assets/Foo.prefab", status: "modified", sha: "foo-head" }],
        blobs: {}, // getBlobRaw misses → null
        contents: { "Assets/Foo.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" },
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res.ok).toBe(true);
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "head-sha");
    });

    it("degrades to the contents api when the base tree fetch fails", async () => {
      const { deps, client } = makeDeps({
        files: [{ path: "Assets/Foo.prefab", status: "modified", sha: "foo-head" }],
        blobs: { "foo-head": "a" },
        contents: { "Assets/Foo.prefab@base-sha": "b" },
      });
      client.listBlobShas.mockResolvedValue(err({ kind: "fetch-failed" as const }) as never);
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res.ok).toBe(true);
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
    });

    it("propagates a rate-limited base tree fetch like the guid index does", async () => {
      const { deps, client } = makeDeps();
      client.listBlobShas.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
      expect(await resolveFully(deps, createDiffSession(), REQ)).toEqual({ ok: false, error: "rate-limited" });
    });

    it("reads removed .meta files via their files-api sha (base-side blob)", async () => {
      const { deps, client } = makeDeps({
        files: [
          { path: "Assets/Foo.prefab", status: "modified", sha: "foo-head" },
          { path: "Assets/S.cs.meta", status: "removed", sha: "meta-base" },
        ],
        blobs: { "foo-head": "a", "foo-base": "b", "meta-base": "guid: g1\n" },
        baseShas: { "Assets/Foo.prefab": "foo-base" },
        contents: {},
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
      expect(client.getFileAtRef).not.toHaveBeenCalled();
    });
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
      const diffWithAssets = vi.fn<DifferPort["diffWithAssets"]>(() => ok(MERGED));
      const { deps, client } = makeDeps({
        diff: () => ok(NEEDS),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
      // side=after, so the source is fetched from head and its bytes land in assets.
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Cyl.prefab", "head-sha");
      const assets = must(diffWithAssets.mock.calls[0]?.[2]);
      expect(new TextDecoder().decode(must(assets.get("src1")))).toBe("SRC");
      // Even after the re-diff, resolved is restored from guidCache and persists.
      expect(res).toEqual({ ok: true, json: { ...MERGED, resolved: { src1: "Assets/Cyl.prefab" } } });
    });

    it("fetches removed-instance sources from the base side", async () => {
      const diffWithAssets = vi.fn<DifferPort["diffWithAssets"]>(() => ok(MERGED));
      const { deps, client } = makeDeps({
        diff: () => ok({ ...NEEDS, neededSources: [{ guid: "src1", side: "before" }] }),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@base-sha": "OLD",
        },
      });
      await resolveFully(deps, createDiffSession(), REQ);
      expect(client.getFileAtRef).toHaveBeenCalledWith("o", "r", "Assets/Cyl.prefab", "base-sha");
    });

    it("keeps the first-pass diff when the source path cannot be resolved", async () => {
      const diffWithAssets = vi.fn<DifferPort["diffWithAssets"]>(() => ok(MERGED));
      const { deps } = makeDeps({ diff: () => ok(NEEDS), diffWithAssets }); // search misses
      const res = await resolveFully(deps, createDiffSession(), REQ);
      // An unknown-path source is given up on, returning the degraded view (the first-pass json) as-is.
      expect(diffWithAssets).not.toHaveBeenCalled();
      expect(res).toEqual({ ok: true, json: { ...NEEDS, resolved: {} } });
    });

    it("does not loop when the merged output still needs the same source", async () => {
      // If supplying still leaves it degraded (a broken source, etc.), don't loop forever on the same guid.
      const diffWithAssets = vi.fn<DifferPort["diffWithAssets"]>(() => ok(NEEDS));
      const { deps } = makeDeps({
        diff: () => ok(NEEDS),
        diffWithAssets,
        search: { src1: "Assets/Cyl.prefab" },
        contents: {
          "Assets/Foo.prefab@base-sha": "b",
          "Assets/Foo.prefab@head-sha": "a",
          "Assets/Cyl.prefab@head-sha": "SRC",
        },
      });
      const res = await resolveFully(deps, createDiffSession(), REQ);
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
      const diffWithAssets = vi.fn(() => ok(merged));
      const { deps } = makeDeps({
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
      await prefetchPr(deps, session, { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
      expect(diffWithAssets).not.toHaveBeenCalled(); // prefetch stops at raw
      const res = await resolveFully(deps, session, REQ);
      expect(res.ok).toBe(true);
      expect(diffWithAssets).toHaveBeenCalledTimes(1); // merging runs at serve time
    });
  });
});

it("dedupes a concurrent user toggle against an in-flight prefetch compute", async () => {
  // Even if the user clicks during prefetch, diff computation and blob fetches don't double up
  const { deps, client } = makeDeps();
  const session = createDiffSession();
  const [, res] = await Promise.all([
    prefetchPr(deps, session, { type: "prefetch", owner: "o", repo: "r", prNumber: 1 }),
    resolveFully(deps, session, REQ),
  ]);
  expect(res.ok).toBe(true);
  const fooFetches = client.getFileAtRef.mock.calls.filter((c) => c[2] === "Assets/Foo.prefab");
  expect(fooFetches).toHaveLength(2); // only twice, base + head
});

describe("semanticDiff with push (two-stage)", () => {
  it("responds immediately with pending and pushes code-search results in the final json", async () => {
    const { deps, guidCache } = makeDeps({ search: { g1: "Assets/Scripts/S.cs" } });
    const { res, pushes } = await serveAndResolve(deps, createDiffSession(), REQ);
    // The response returns immediately with empty resolved + pending. Names arrive via push (the crux of B4)
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: {} }, pending: true });
    const last = must(pushes.at(-1));
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
    const { res, pushes } = await serveAndResolve(deps, createDiffSession(), REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: "Assets/S.cs" } } });
    expect(pushes).toEqual([]); // if everything is resolved and no source merge is needed, there's no push
  });

  it("resolves via the repo index and only searches the leftover", async () => {
    const { deps, client } = makeDeps({
      diff: () => ok({ ...DIFF, unresolvedGuids: ["g1", "g2"] }),
      search: { g2: "Assets/Other.cs" },
    });
    client.listMetaTree.mockResolvedValue(ok({ truncated: false, metas: [{ path: "Assets/S.cs.meta", sha: "sha1" }] }));
    client.batchBlobTexts.mockResolvedValue(ok({ sha1: "guid: g1\n" }));
    const { pushes } = await serveAndResolve(deps, createDiffSession(), REQ);
    // g1 arrives first from the index (intermediate push), and only g2, absent from the index, goes to Code Search (3-stage resolution)
    expect(pushes[0]).toMatchObject({ resolved: { g1: "Assets/S.cs" }, done: false });
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs", g2: "Assets/Other.cs" });
    expect(client.searchMetaByGuid).toHaveBeenCalledTimes(1);
    expect(client.searchMetaByGuid).toHaveBeenCalledWith("o", "r", "g2");
  });

  it("falls back to code search when the tree is truncated", async () => {
    const { deps, client } = makeDeps({ search: { g1: "Assets/S.cs" } });
    client.listMetaTree.mockResolvedValue(ok({ truncated: true, metas: [] }));
    const { pushes } = await serveAndResolve(deps, createDiffSession(), REQ);
    expect(pushes.at(-1)?.json?.resolved).toEqual({ g1: "Assets/S.cs" });
  });

  it("stops retrying the index for the session after an index rate limit", async () => {
    const { deps, client } = makeDeps();
    client.listMetaTree.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
    const session = createDiffSession();
    await serveAndResolve(deps, session, REQ);
    await serveAndResolve(deps, session, REQ);
    expect(client.listMetaTree).toHaveBeenCalledTimes(1); // pinned to fallback for the SW lifetime
  });

  it("re-merges sources in the async stage once the source guid resolves", async () => {
    // The crux of mergeSources consistency: the immediate response comes back without merging,
    // and once the repo index resolves the source guid, the re-merged json arrives in the final push
    const withSource: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], neededSources: [{ guid: "src1", side: "after" }] };
    const merged: DiffV2 = { ...DIFF, unresolvedGuids: ["src1"], resolved: { src1: "Assets/Src.prefab" } };
    const diffWithAssets = vi.fn(() => ok(merged));
    const { deps, client } = makeDeps({
      contents: {
        "Assets/Foo.prefab@base-sha": "b",
        "Assets/Foo.prefab@head-sha": "a",
        "Assets/Src.prefab@head-sha": "source prefab",
      },
      diff: () => ok(withSource),
      diffWithAssets,
    });
    client.listMetaTree.mockResolvedValue(
      ok({
        truncated: false,
        metas: [{ path: "Assets/Src.prefab.meta", sha: "sha1" }],
      }),
    );
    client.batchBlobTexts.mockResolvedValue(ok({ sha1: "guid: src1\n" }));
    // Note: serveAndResolve waits for the done push, so by that point diffWithAssets has always been called
    // (done:true is only emitted after mergeSources completes). Asserting "not yet called" must be done
    // right after the immediate response (before waiting for the push to finish), so this one is assembled manually.
    const pushes: GuidResolvedPush[] = [];
    const res = await computeSemanticDiff(deps, createDiffSession(), REQ, (m) => pushes.push(m));
    expect(res.ok && res.pending).toBe(true);
    expect(diffWithAssets).not.toHaveBeenCalled(); // the immediate response doesn't merge (it takes priority)
    await vi.waitFor(() => expect(diffWithAssets).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
    expect(pushes.at(-1)?.json).toMatchObject({ resolved: { src1: "Assets/Src.prefab" } });
  });

  it("kicks the repo index sync from prefetch", async () => {
    const { deps, client } = makeDeps();
    await prefetchPr(deps, createDiffSession(), { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    await vi.waitFor(() => expect(client.listMetaTree).toHaveBeenCalledWith("o", "r", "head-sha"));
  });
});
