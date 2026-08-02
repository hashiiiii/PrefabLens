// Shared test harness for the semantic-diff pipeline. Used by
// get-semantic-diff.test.ts and create-pr-prefetch.test.ts, which exercise the
// same production pipeline from two entry points. Not a *.test.ts file, so
// Vitest does not collect it; it must only be imported from tests.
import { expect, vi } from "vitest";
import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import type { DiffV2, GuidResolvedPush, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { ok } from "../../domain/result";
import type { DiffSession } from "../create-diff-session";
import type { DifferPort } from "../port/differ";
import type { ChangedFile, GithubPort } from "../port/github";
import { getSemanticDiff } from "./get-semantic-diff";

type MakeClient = (base: string, token: string, lane: "user" | "prefetch") => GithubPort;
type GetDiffer = () => Promise<DifferPort>;

export const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

export const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };

export function makeFakes(overrides?: {
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
  const tokenStore: TokenRepository = {
    readAccessToken: async () => (Object.hasOwn(overrides ?? {}, "accessToken") ? overrides?.accessToken : "tok"),
    saveAccessToken: async () => {},
    savePendingSignIn: async () => {},
    readPendingSignIn: async () => undefined,
    clearPendingSignIn: async () => {},
  };
  const makeClient = (_base: string, _token: string, _lane: "user" | "prefetch") => client;
  const getDiffer = async () => differ;
  return { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, client };
}

/** Drives semanticDiff to completion — the immediate response plus every push — and returns the
 *  fully-resolved response. Errors and fully-in-PR-resolved diffs pass through unchanged; a pending
 *  diff resolves to the final push's json, i.e. what the pipeline ultimately produces. */
export async function resolveFully(
  tokenStore: TokenRepository,
  makeClient: MakeClient,
  getDiffer: GetDiffer,
  guidCache: GuidRepository,
  diffStore: DiffRepository,
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  req: SemanticDiffRequest,
): Promise<SemanticDiffResponse> {
  const pushes: GuidResolvedPush[] = [];
  const res = await getSemanticDiff(
    tokenStore,
    makeClient,
    getDiffer,
    guidCache,
    diffStore,
    repoIndexStore,
    session,
    req,
    (m) => pushes.push(m),
  );
  if (!res.ok || !res.pending) return res;
  await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  const final = pushes.at(-1);
  return final?.json ? { ok: true, json: final.json } : res;
}
