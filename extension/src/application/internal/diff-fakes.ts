// Shared test harness for the semantic-diff pipeline. get-semantic-diff.test.ts
// and prefetch-pr.test.ts use it to run the same production pipeline
// from two entry points. This is not a *.test.ts file, so Vitest does not
// collect it. Import it only from tests.
import { expect, vi } from "vitest";
import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { type DiffV2, emptyDiff } from "../../domain/diff/types";
import type { GuidMap } from "../../domain/guid/guid-map";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoGuidIndex } from "../../domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { ok } from "../../domain/result";
import type { DiffSession } from "../diff/create-diff-session";
import { getSemanticDiff } from "../diff/get-semantic-diff";
import type { DifferGateway } from "../gateway/differ";
import type { ChangedFile, GithubGateway, MakeGithubClient } from "../gateway/github";
import type { GuidResolvedPush, SemanticDiffRequest, SemanticDiffResponse } from "../gateway/messenger";
import { API_BASE } from "./api-base";

type GetDiffer = () => Promise<DifferGateway>;

type GithubResult<K extends keyof GithubGateway> = Awaited<ReturnType<GithubGateway[K]>>;
// Argument tuples recorded for each client method, in call order.
export type GithubCalls = { [K in keyof GithubGateway]: Array<Parameters<GithubGateway[K]>> };
// Canned answers, consulted before the state-derived default. An array is a
// once-queue: each call shifts one entry, and a drained array falls through.
// A single value answers every call.
export type GithubResults = { [K in keyof GithubGateway]?: GithubResult<K> | Array<GithubResult<K>> };
// Replacement behaviors, consulted after `results` and before the state-derived default.
export type GithubImpls = {
  [K in keyof GithubGateway]?: (...args: Parameters<GithubGateway[K]>) => Promise<GithubResult<K>>;
};

export const REQ: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

export const DIFF: DiffV2 = { ...emptyDiff(), unresolvedGuids: ["g1"] };

export function makeFakes(overrides?: {
  files?: ChangedFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  blobs?: Record<string, string>; // blob sha → text (getBlobRaw, absent sha = 404 → null)
  baseShas?: Record<string, string>; // path → blob sha at the merge base (listBlobShas)
  diff?: DifferGateway["diff"];
  diffWithAssets?: DifferGateway["diffWithAssets"];
  isUnityYaml?: DifferGateway["isUnityYaml"];
  accessToken?: string | undefined;
  search?: Record<string, string | null>; // guid → asset path (null = no hit)
  cached?: Record<string, string>; // initial contents of guidCache
}) {
  const files = overrides?.files ?? [{ path: "Assets/Foo.prefab", status: "modified" }];
  const contents = overrides?.contents ?? { "Assets/Foo.prefab@base-sha": "b", "Assets/Foo.prefab@head-sha": "a" };
  const calls: GithubCalls = {
    getPrRefs: [],
    listPrFiles: [],
    getCommit: [],
    compareRefs: [],
    resolveRefSha: [],
    getFileAtRef: [],
    getBlobRaw: [],
    listBlobShas: [],
    searchMetaByGuid: [],
    listMetaTree: [],
    batchBlobTexts: [],
  };
  const results: GithubResults = {};
  const impls: GithubImpls = {};
  // Records the argument tuple, then answers from `results` (canned), `impls`
  // (replacement behavior), or the constructor state tables, in that order.
  const method =
    <K extends keyof GithubGateway>(
      key: K,
      fromState: (...args: Parameters<GithubGateway[K]>) => Promise<GithubResult<K>>,
    ) =>
    async (...args: Parameters<GithubGateway[K]>): Promise<GithubResult<K>> => {
      calls[key].push(args);
      const queued: GithubResult<K> | Array<GithubResult<K>> | undefined = results[key];
      if (Array.isArray(queued)) {
        const next = queued.shift();
        if (next !== undefined) return next;
      } else if (queued !== undefined) {
        return queued;
      }
      const impl = impls[key];
      if (impl) return impl(...args);
      return fromState(...args);
    };
  const client: GithubGateway = {
    getPrRefs: method("getPrRefs", async () => ok({ baseSha: "base-sha", headSha: "head-sha" })),
    listPrFiles: method("listPrFiles", async () => ok(files)),
    // Commit/compare fakes mirror the PR refs so the same contents table serves every target kind
    getCommit: method("getCommit", async () => ok({ sha: "head-sha", parentSha: "base-sha", files })),
    compareRefs: method("compareRefs", async () => ok({ mergeBaseSha: "base-sha", files })),
    resolveRefSha: method("resolveRefSha", async () => ok("head-sha")),
    getFileAtRef: method("getFileAtRef", async (_o, _r, path, ref) => {
      const text = contents[`${path}@${ref}`];
      return ok(text === undefined ? null : new TextEncoder().encode(text));
    }),
    getBlobRaw: method("getBlobRaw", async (_o, _r, sha) => {
      const text = overrides?.blobs?.[sha];
      return ok(text === undefined ? null : new TextEncoder().encode(text));
    }),
    listBlobShas: method("listBlobShas", async () =>
      ok({
        truncated: false,
        byPath: new Map(Object.entries(overrides?.baseShas ?? {})),
      }),
    ),
    searchMetaByGuid: method("searchMetaByGuid", async (_o, _r, guid) => ok(overrides?.search?.[guid] ?? null)),
    listMetaTree: method("listMetaTree", async () =>
      ok({
        truncated: false,
        metas: [],
      }),
    ),
    batchBlobTexts: method("batchBlobTexts", async () => ok({})),
  };
  const differ: DifferGateway = {
    diff: overrides?.diff ?? (() => ok(DIFF)),
    diffWithAssets: overrides?.diffWithAssets ?? (() => ok(DIFF)),
    // Fixture contents are shorthand strings, not real UnityYAML: accept by default.
    isUnityYaml: overrides?.isUnityYaml ?? (() => true),
  };
  const cacheData: Record<string, GuidMap> = {};
  if (overrides?.cached) cacheData[repoKey(API_BASE, "o", "r")] = { ...overrides.cached };
  const guidSaves: Array<[string, GuidMap]> = [];
  const guidCache = {
    data: cacheData,
    saves: guidSaves,
    load: async (repo: string) => cacheData[repo] ?? {},
    save: async (repo: string, entries: GuidMap) => {
      guidSaves.push([repo, entries]);
      cacheData[repo] = { ...cacheData[repo], ...entries };
    },
  };
  const diffStoreData: Record<string, DiffV2> = {};
  const diffSaves: Array<[string, DiffV2]> = [];
  const diffStore = {
    data: diffStoreData,
    saves: diffSaves,
    load: async (key: string) => diffStoreData[key],
    save: async (key: string, json: DiffV2) => {
      diffSaves.push([key, json]);
      diffStoreData[key] = json;
    },
  };
  // This fake mirrors the RepoIndexRepository interface (loadGuids/saveGuids/loadIndex/saveIndex).
  // It starts empty. Tests seed guidsData/indexData directly.
  const guidsData: Record<string, GuidMap> = {};
  const indexData: Record<string, RepoGuidIndex> = {};
  const savedGuids: Array<[string, GuidMap]> = [];
  const savedIndexes: Array<[string, RepoGuidIndex]> = [];
  const loadIndexCalls: string[] = [];
  const repoIndexStore = {
    guidsData,
    indexData,
    savedGuids,
    savedIndexes,
    loadIndexCalls,
    loadGuids: async (repo: string) => guidsData[repo] ?? {},
    saveGuids: async (repo: string, entries: GuidMap) => {
      savedGuids.push([repo, entries]);
      guidsData[repo] = { ...guidsData[repo], ...entries };
    },
    loadIndex: async (repo: string) => {
      loadIndexCalls.push(repo);
      return indexData[repo];
    },
    saveIndex: async (repo: string, index: RepoGuidIndex) => {
      savedIndexes.push([repo, index]);
      indexData[repo] = index;
    },
  };
  const tokenStore: TokenRepository = {
    readAccessToken: async () => (Object.hasOwn(overrides ?? {}, "accessToken") ? overrides?.accessToken : "tok"),
    saveAccessToken: async () => {},
    savePendingSignIn: async () => {},
    readPendingSignIn: async () => undefined,
    clearPendingSignIn: async () => {},
  };
  const makeClient: MakeGithubClient = () => client;
  const getDiffer = async () => differ;
  return { tokenStore, makeClient, getDiffer, guidCache, diffStore, repoIndexStore, client, calls, results, impls };
}

// Serves the request and, when the response is pending, waits for the done push
// before it returns. Callers assert on the immediate response and the push list.
export async function serveAndResolve(
  tokenStore: TokenRepository,
  makeClient: MakeGithubClient,
  getDiffer: GetDiffer,
  guidCache: GuidRepository,
  diffStore: DiffRepository,
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  req: SemanticDiffRequest,
): Promise<{ res: SemanticDiffResponse; pushes: GuidResolvedPush[] }> {
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
  if (res.ok && res.pending) await vi.waitFor(() => expect(pushes.at(-1)?.done).toBe(true));
  return { res, pushes };
}

// Drives semanticDiff to completion (the immediate response plus every push) and
// returns the fully-resolved response. Errors and diffs that resolve fully in the
// PR return unchanged. A pending diff resolves to the json of the final push,
// that is, the final output of the pipeline.
export async function resolveFully(
  tokenStore: TokenRepository,
  makeClient: MakeGithubClient,
  getDiffer: GetDiffer,
  guidCache: GuidRepository,
  diffStore: DiffRepository,
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  req: SemanticDiffRequest,
): Promise<SemanticDiffResponse> {
  const { res, pushes } = await serveAndResolve(
    tokenStore,
    makeClient,
    getDiffer,
    guidCache,
    diffStore,
    repoIndexStore,
    session,
    req,
  );
  if (!res.ok || !res.pending) return res;
  const final = pushes.at(-1);
  return final?.json ? { ok: true, json: final.json } : res;
}
