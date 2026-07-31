import { describe, expect, it, vi } from "vitest";
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
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

describe("prefetch", () => {
  it("precomputes diffs so a later toggle serves without new blob fetches", async () => {
    const { deps, client } = makeDeps();
    const session = createDiffSession();
    await prefetchPr(deps, session, { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(client.searchMetaByGuid).not.toHaveBeenCalled(); // prefetch doesn't touch the 10 req/min Code Search
    const fetchesAfterPrefetch = client.getFileAtRef.mock.calls.length;
    const res = await resolveFully(deps, session, REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef.mock.calls.length).toBe(fetchesAfterPrefetch); // no blob re-fetch
  });

  it("persists prefetched diffs to the diff store (sw restart survival)", async () => {
    const { deps } = makeDeps();
    await prefetchPr(deps, createDiffSession(), { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(deps.diffStore.save).toHaveBeenCalledWith("base-sha:head-sha:Assets/Foo.prefab", DIFF);
  });

  it("serves a diff persisted by a previous worker from the store", async () => {
    // The SW dies after 30 seconds: a result prefetched in a prior life must be recoverable via storage.session
    const { deps, client, diffStore } = makeDeps();
    diffStore.data["base-sha:head-sha:Assets/Foo.prefab"] = DIFF; // seeded as if saved by a prior SW life
    const res = await resolveFully(deps, createDiffSession(), REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).not.toHaveBeenCalledWith("o", "r", "Assets/Foo.prefab", "base-sha");
  });

  it("prefetches only unity files and caps at 100", async () => {
    const files: ChangedFile[] = Array.from({ length: 120 }, (_, i) => ({
      path: `Assets/F${i}.prefab`,
      status: "modified",
    }));
    files.push({ path: "README.md", status: "modified" });
    const { deps, client } = makeDeps({ files });
    await prefetchPr(deps, createDiffSession(), { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    const paths = new Set(client.getFileAtRef.mock.calls.map((c) => c[2]));
    expect(paths.has("README.md")).toBe(false);
    expect(paths.size).toBe(100); // cut off at the cap
  });

  it("skips oversized files without caching them", async () => {
    const big = new Uint8Array(13 * 1024 * 1024);
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(ok(big));
    const session = createDiffSession();
    await prefetchPr(deps, session, { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(deps.diffStore.save).not.toHaveBeenCalled();
    // A later manual toggle still shows the too-large gate as before
    expect(await resolveFully(deps, session, REQ)).toEqual({ ok: false, error: "too-large", bytes: big.length * 2 });
  });

  it("aborts silently on rate limit instead of surfacing an error", async () => {
    const { deps, client } = makeDeps();
    client.getFileAtRef.mockResolvedValue(err({ kind: "rate-limited" as const }) as never);
    await expect(
      prefetchPr(deps, createDiffSession(), { type: "prefetch", owner: "o", repo: "r", prNumber: 1 }),
    ).resolves.toBeUndefined();
  });

  it("returns without network when the access token is missing", async () => {
    const { deps, client } = makeDeps({ accessToken: undefined });
    await prefetchPr(deps, createDiffSession(), { type: "prefetch", owner: "o", repo: "r", prNumber: 1 });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });
});
