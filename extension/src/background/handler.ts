import { AuthError, type ChangedFile, type GithubClient, RateLimitError, type RefPair } from "../github/client";
import { applyResolved, buildGuidIndex, type GuidCache } from "../github/guids";
import { type HostApi, resolveApi } from "../github/hosts";
import type { RepoIndexStore } from "../github/repoIndex";
import {
  type DiffTarget,
  type DiffV2,
  type GuidResolvedPush,
  type PrefetchRequest,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  targetKey,
} from "../types";
import { isUnityPath } from "../unity";
import { DiffError, type Differ } from "../wasm/differ";
import { createPromiseCache } from "./promiseCache";
import { createResolution, type DiffContext } from "./resolution";

type ClientLike = Pick<
  GithubClient,
  | "getPrRefs"
  | "listPrFiles"
  | "getCommit"
  | "compareRefs"
  | "resolveRefSha"
  | "getFileAtRef"
  | "getBlobRaw"
  | "listBlobShas"
  | "searchMetaByGuid"
  | "listMetaTree"
  | "batchBlobTexts"
>;

export type Deps = {
  getSettings(origin: string): Promise<{ pat?: string }>;
  makeClient(api: HostApi, token: string, lane: "user" | "prefetch"): ClientLike;
  getDiffer(): Promise<Differ>;
  guidCache: GuidCache;
  diffStore: { load(key: string): Promise<DiffV2 | undefined>; save(key: string, json: DiffV2): Promise<void> };
  repoIndexStore: RepoIndexStore;
};

export type Handler = {
  semanticDiff(req: SemanticDiffRequest, push: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};

/** The only per-kind logic: refs + changed-file discovery. Everything downstream is target-agnostic. */
async function loadRefsAndFiles(
  client: ClientLike,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<{ refs: RefPair; files: ChangedFile[] }> {
  if (target.kind === "pull") {
    const [refs, files] = await Promise.all([
      client.getPrRefs(owner, repo, target.prNumber),
      client.listPrFiles(owner, repo, target.prNumber),
    ]);
    return { refs, files };
  }
  if (target.kind === "commit") {
    const commit = await client.getCommit(owner, repo, target.sha);
    // Root commit: every file is added, so the before side is never fetched; using the commit's
    // own sha as baseSha keeps downstream tree lookups harmless.
    return { refs: { baseSha: commit.parentSha ?? commit.sha, headSha: commit.sha }, files: commit.files };
  }
  const [cmp, headSha] = await Promise.all([
    client.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha, not a branch name. The compare body can't supply it:
    // its commits array truncates at 250, so the last entry isn't always the head.
    client.resolveRefSha(owner, repo, target.head),
  ]);
  return { refs: { baseSha: cmp.mergeBaseSha, headSha }, files: cmp.files };
}

const EMPTY = new Uint8Array(0);
const CONTEXT_TTL_MS = 60_000; // PR context is short-lived because a push changes headSha
const BLOB_CACHE_MAX = 32;
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // over 25MB renders on click
const PREFETCH_MAX = 100; // prefetch cap per PR (bounds API usage)
const PREFETCH_CONCURRENCY = 4;

type DiffOutcome =
  | { ok: true; json: DiffV2 }
  | { ok: false; error: "too-large"; bytes: number }
  | { ok: false; error: "not-unity-yaml" };

export function createHandler(deps: Deps): Handler {
  // Per-PR context cache (60s ttl: a push moves headSha). The SW may be killed at any time; then we just re-fetch.
  const contexts = createPromiseCache<DiffContext>({ ttlMs: CONTEXT_TTL_MS });
  // sha+path → bytes. The promise fold shares one fetch between concurrent prefetch and manual-toggle requests.
  const blobs = createPromiseCache<Uint8Array | null>({ max: BLOB_CACHE_MAX });
  // baseSha:headSha:path → raw diff computation. too-large is dropped so force can recompute; not-unity-yaml
  // is deterministic for the sha pair, so it stays cached alongside successes.
  const diffs = createPromiseCache<DiffOutcome>({ retain: (o) => o.ok || o.error !== "too-large" });

  /** blobSha rides along when known (files API / merge-base tree): blob-by-sha latency is flat where
   *  contents-by-path stalls for seconds (#110). A 404 on the sha (force push) falls back to path+ref. */
  function fetchBlob(
    client: ClientLike,
    owner: string,
    repo: string,
    path: string,
    sha: string,
    blobSha?: string,
  ): Promise<Uint8Array | null> {
    // a blob sha never collides with the `${sha}:${path}` form
    return blobs.get(blobSha ?? `${sha}:${path}`, () =>
      blobSha
        ? client.getBlobRaw(owner, repo, blobSha).then((bytes) => bytes ?? client.getFileAtRef(owner, repo, path, sha))
        : client.getFileAtRef(owner, repo, path, sha),
    );
  }

  /** Retrieves the before/after blobs (status/previousPath rules follow the files API). */
  async function fetchPair(
    client: ClientLike,
    ctx: DiffContext,
    owner: string,
    repo: string,
    path: string,
  ): Promise<[Uint8Array, Uint8Array]> {
    const file = ctx.files.find((f) => f.path === path);
    const status = file?.status ?? "modified";
    const beforePath = file?.previousPath ?? path;
    // files API sha is the head blob, except for removed files where it is the base blob
    const beforeBlob = status === "removed" ? file?.sha : ctx.baseShas?.get(beforePath);
    const afterBlob = status === "removed" ? undefined : file?.sha;
    const fetchSide = (p: string, sha: string, blobSha?: string): Promise<Uint8Array> =>
      fetchBlob(client, owner, repo, p, sha, blobSha).then((bytes) => bytes ?? EMPTY);
    return Promise.all([
      status === "added" ? Promise.resolve(EMPTY) : fetchSide(beforePath, ctx.refs.baseSha, beforeBlob),
      status === "removed" ? Promise.resolve(EMPTY) : fetchSide(path, ctx.refs.headSha, afterBlob),
    ]);
  }

  // Repo-index and Code Search resolution plus source re-merge, sharing the handler's cached fetchers.
  const resolution = createResolution({
    guidCache: deps.guidCache,
    repoIndexStore: deps.repoIndexStore,
    getDiffer: () => deps.getDiffer(),
    fetchBlob,
    fetchPair,
  });

  function loadContext(
    origin: string,
    client: ClientLike,
    owner: string,
    repo: string,
    target: DiffTarget,
  ): Promise<DiffContext> {
    // Two instances can host the same owner/repo/PR number, so the context key carries the
    // origin. The sha-keyed blob/diff caches stay shared: shas are content-addressed.
    return contexts.get(`${origin}:${targetKey(owner, repo, target)}`, async () => {
      const { refs, files } = await loadRefsAndFiles(client, owner, repo, target);
      const bySha = new Map(files.map((f) => [f.path, f.sha]));
      const [guidIndex, baseShas] = await Promise.all([
        buildGuidIndex(files, async (path, side) => {
          // the files API sha matches the side buildGuidIndex reads: head, or base exactly for removed metas
          const bytes = await fetchBlob(
            client,
            owner,
            repo,
            path,
            side === "base" ? refs.baseSha : refs.headSha,
            bySha.get(path),
          );
          return bytes ? new TextDecoder().decode(bytes) : null;
        }),
        // like buildGuidIndex, only rate limits propagate; anything else degrades to the contents-api fallback
        client.listBlobShas(owner, repo, refs.baseSha).then(
          (tree) => (tree.truncated ? null : tree.byPath),
          (err: unknown) => {
            if (err instanceof RateLimitError) throw err;
            return null;
          },
        ),
      ]);
      return { refs, files, guidIndex, baseShas };
    });
  }

  /** blob fetch → 25MB guard → plain diff, no further. Don't put resolution or mergeSources here
   *  (resolved improves later via Code Search, so the raw diff determined by sha alone is the cache unit). */
  async function computeDiff(
    client: ClientLike,
    ctx: DiffContext,
    owner: string,
    repo: string,
    path: string,
    force: boolean,
  ): Promise<DiffOutcome> {
    // If not in the listing (the files API cuts off at 3000 entries), treat as modified: the missing side just 404s → EMPTY (fetchPair's rule)
    const [before, after] = await fetchPair(client, ctx, owner, repo, path);
    if (!force && before.length + after.length > TOO_LARGE_BYTES) {
      return { ok: false, error: "too-large", bytes: before.length + after.length };
    }
    const differ = await deps.getDiffer();
    // Path passed the extension prefilter, but some .asset files are binary
    // regardless of Force Text: content is the ground truth.
    if (!differ.isUnityYaml(before) && !differ.isUnityYaml(after)) {
      return { ok: false, error: "not-unity-yaml" };
    }
    return { ok: true, json: differ.diff(before, after) };
  }

  /** sha-keyed, so a push naturally produces a different key (no invalidation needed). */
  function getDiff(
    client: ClientLike,
    ctx: DiffContext,
    owner: string,
    repo: string,
    path: string,
    force: boolean,
  ): Promise<DiffOutcome> {
    const key = `${ctx.refs.baseSha}:${ctx.refs.headSha}:${path}`;
    return diffs.get(key, async (): Promise<DiffOutcome> => {
      const stored = await deps.diffStore.load(key); // a result left by a prior SW life
      if (stored) return { ok: true, json: stored };
      const outcome = await computeDiff(client, ctx, owner, repo, path, force);
      if (outcome.ok) void deps.diffStore.save(key, outcome.json);
      return outcome;
    });
  }

  async function semanticDiff(
    req: SemanticDiffRequest,
    push: (msg: GuidResolvedPush) => void,
  ): Promise<SemanticDiffResponse> {
    try {
      const api = resolveApi(req.origin);
      const settings = await deps.getSettings(req.origin);
      if (!settings.pat) return { ok: false, error: "pat-missing" };
      const client = deps.makeClient(api, settings.pat, "user");
      const ctx = await loadContext(req.origin, client, req.owner, req.repo, req.target);
      const outcome = await getDiff(client, ctx, req.owner, req.repo, req.path, req.force === true);
      if (!outcome.ok) return outcome;
      const withPr = applyResolved(outcome.json, ctx.guidIndex);

      // Two-stage path: return the diff immediately, continue resolution and source merging in the background, deliver via push
      const remaining = withPr.unresolvedGuids.filter((g) => !Object.hasOwn(withPr.resolved ?? {}, g));
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolution.resolveRemaining(withPr, remaining, client, req, api.restBase, ctx, push);
      return { ok: true, json: withPr, pending: true };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: "rate-limited" };
      if (err instanceof AuthError) return { ok: false, error: "auth-failed" };
      if (err instanceof DiffError) return { ok: false, error: "diff-failed" };
      return { ok: false, error: "fetch-failed" }; // don't put raw errors in the response
    }
  }

  /** Precomputes the raw diff only. No resolve/search/mergeSources
   *  — Code Search is a scarce 10 req/min resource and mergeSources depends on resolution, so leave them to serve time. */
  async function prefetch(req: PrefetchRequest): Promise<void> {
    try {
      const api = resolveApi(req.origin);
      const settings = await deps.getSettings(req.origin);
      if (!settings.pat) return;
      const client = deps.makeClient(api, settings.pat, "prefetch");
      const ctx = await loadContext(req.origin, client, req.owner, req.repo, { kind: "pull", prNumber: req.prNumber });
      // Run independently of raw-diff prefetch (index sync speeds up the 3-stage resolution at serve time)
      void resolution.getRepoIndex(
        client,
        req.owner,
        req.repo,
        `${api.restBase}/${req.owner}/${req.repo}`,
        ctx.refs.headSha,
      );
      const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
      for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map((f) =>
            getDiff(client, ctx, req.owner, req.repo, f.path, false).catch((err) => {
              if (err instanceof RateLimitError) throw err; // only a rate limit stops the whole thing
              // Swallow per-file failures: the error is shown again on manual toggle
            }),
          ),
        );
      }
    } catch (err) {
      // Prefetch gives up quietly. Only the user-action path surfaces error UI
      console.debug("prefablens: prefetch aborted", err);
    }
  }

  return { semanticDiff, prefetch };
}
