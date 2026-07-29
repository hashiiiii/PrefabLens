import {
  API_BASE,
  AuthError,
  type ChangedFile,
  type GithubClient,
  RateLimitError,
  type RefPair,
} from "../github/client";
import { applyResolved, buildGuidIndex, type GuidCache } from "../github/guids";
import type { RepoIndexStore } from "../github/repoIndex";
import {
  type DiffTarget,
  type DiffV2,
  type GuidResolvedPush,
  type PrefetchRequest,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  targetKey,
  unresolvedRemaining,
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
  getSettings(): Promise<{ pat?: string }>;
  makeClient(base: string, token: string, lane: "user" | "prefetch"): ClientLike;
  getDiffer(): Promise<Differ>;
  guidCache: GuidCache;
  diffStore: { load(key: string): Promise<DiffV2 | undefined>; save(key: string, json: DiffV2): Promise<void> };
  repoIndexStore: RepoIndexStore;
};

export type Handler = {
  semanticDiff(req: SemanticDiffRequest, push: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};

// Per-kind: refs + changed-file discovery; everything downstream is target-agnostic
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
    // Root commit: before side is never fetched; own sha as baseSha keeps tree lookups harmless
    return { refs: { baseSha: commit.parentSha ?? commit.sha, headSha: commit.sha }, files: commit.files };
  }
  const [cmp, headSha] = await Promise.all([
    client.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha; compare commits truncate at 250 so last ≠ always head
    client.resolveRefSha(owner, repo, target.head),
  ]);
  return { refs: { baseSha: cmp.mergeBaseSha, headSha }, files: cmp.files };
}

const EMPTY = new Uint8Array(0);
const CONTEXT_TTL_MS = 60_000; // push moves headSha
const BLOB_CACHE_MAX = 32;
const TOO_LARGE_BYTES = 25 * 1024 * 1024; // over 25MB renders on click
const PREFETCH_MAX = 100; // bounds API usage per PR
const PREFETCH_CONCURRENCY = 4;

type DiffOutcome =
  | { ok: true; json: DiffV2 }
  | { ok: false; error: "too-large"; bytes: number }
  | { ok: false; error: "not-unity-yaml" };

export function createHandler(deps: Deps): Handler {
  // Per-PR context; SW kill → re-fetch
  const contexts = createPromiseCache<DiffContext>({ ttlMs: CONTEXT_TTL_MS });
  // sha+path → bytes; promise fold shares prefetch + toggle fetches
  const blobs = createPromiseCache<Uint8Array | null>({ max: BLOB_CACHE_MAX });
  // too-large dropped so force can recompute; not-unity-yaml stays cached
  const diffs = createPromiseCache<DiffOutcome>({ retain: (o) => o.ok || o.error !== "too-large" });

  // Prefer blob-sha when known (#110); 404 (force push) falls back to path+ref
  function fetchBlob(
    client: ClientLike,
    owner: string,
    repo: string,
    path: string,
    sha: string,
    blobSha?: string,
  ): Promise<Uint8Array | null> {
    // blob sha never collides with `${sha}:${path}`
    return blobs.get(blobSha ?? `${sha}:${path}`, () =>
      blobSha
        ? client.getBlobRaw(owner, repo, blobSha).then((bytes) => bytes ?? client.getFileAtRef(owner, repo, path, sha))
        : client.getFileAtRef(owner, repo, path, sha),
    );
  }

  // Before/after blobs; status/previousPath follow the files API
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
    // files API sha is head blob, except removed where it is the base blob
    const beforeBlob = status === "removed" ? file?.sha : ctx.baseShas?.get(beforePath);
    const afterBlob = status === "removed" ? undefined : file?.sha;
    const fetchSide = (p: string, sha: string, blobSha?: string): Promise<Uint8Array> =>
      fetchBlob(client, owner, repo, p, sha, blobSha).then((bytes) => bytes ?? EMPTY);
    return Promise.all([
      status === "added" ? Promise.resolve(EMPTY) : fetchSide(beforePath, ctx.refs.baseSha, beforeBlob),
      status === "removed" ? Promise.resolve(EMPTY) : fetchSide(path, ctx.refs.headSha, afterBlob),
    ]);
  }

  const resolution = createResolution({
    guidCache: deps.guidCache,
    repoIndexStore: deps.repoIndexStore,
    getDiffer: () => deps.getDiffer(),
    fetchBlob,
    fetchPair,
  });

  function loadContext(client: ClientLike, owner: string, repo: string, target: DiffTarget): Promise<DiffContext> {
    return contexts.get(targetKey(owner, repo, target), async () => {
      const { refs, files } = await loadRefsAndFiles(client, owner, repo, target);
      const bySha = new Map(files.map((f) => [f.path, f.sha]));
      const [guidIndex, baseShas] = await Promise.all([
        buildGuidIndex(files, async (path, side) => {
          // files API sha matches the side buildGuidIndex reads (head, or base for removed metas)
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
        // Only rate limits propagate; anything else → null → contents-api fallback
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

  // Raw sha-keyed diff only; resolution/mergeSources stay out (Code Search improves later)
  async function computeDiff(
    client: ClientLike,
    ctx: DiffContext,
    owner: string,
    repo: string,
    path: string,
    force: boolean,
  ): Promise<DiffOutcome> {
    // Missing from listing (files API caps at 3000) → treat as modified; 404 side → EMPTY
    const [before, after] = await fetchPair(client, ctx, owner, repo, path);
    if (!force && before.length + after.length > TOO_LARGE_BYTES) {
      return { ok: false, error: "too-large", bytes: before.length + after.length };
    }
    const differ = await deps.getDiffer();
    // Prefilter passed, but some .asset files are binary regardless of ForceText
    if (!differ.isUnityYaml(before) && !differ.isUnityYaml(after)) {
      return { ok: false, error: "not-unity-yaml" };
    }
    return { ok: true, json: differ.diff(before, after) };
  }

  // Sha-keyed: a push produces a new key (no invalidation)
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
      const stored = await deps.diffStore.load(key); // prior SW life
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
      const settings = await deps.getSettings();
      if (!settings.pat) return { ok: false, error: "pat-missing" };
      const base = API_BASE;
      const client = deps.makeClient(base, settings.pat, "user");
      const ctx = await loadContext(client, req.owner, req.repo, req.target);
      const outcome = await getDiff(client, ctx, req.owner, req.repo, req.path, req.force === true);
      if (!outcome.ok) return outcome;
      const withPr = applyResolved(outcome.json, ctx.guidIndex);

      // Return immediately; resolution + source merge continue via push
      const remaining = unresolvedRemaining(withPr);
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolution.resolveRemaining(withPr, remaining, client, req, base, ctx, push);
      return { ok: true, json: withPr, pending: true };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: "rate-limited" };
      if (err instanceof AuthError) return { ok: false, error: "auth-failed" };
      if (err instanceof DiffError) return { ok: false, error: "diff-failed" };
      return { ok: false, error: "fetch-failed" }; // don't put raw errors in the response
    }
  }

  // Raw diff only — leave Code Search / mergeSources to serve time (10 req/min)
  async function prefetch(req: PrefetchRequest): Promise<void> {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return;
      const base = API_BASE;
      const client = deps.makeClient(base, settings.pat, "prefetch");
      const ctx = await loadContext(client, req.owner, req.repo, { kind: "pull", prNumber: req.prNumber });
      // Index sync independent of raw-diff prefetch (speeds 3-stage resolution at serve time)
      void resolution.getRepoIndex(client, req.owner, req.repo, `${base}/${req.owner}/${req.repo}`, ctx.refs.headSha);
      const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
      for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map((f) =>
            getDiff(client, ctx, req.owner, req.repo, f.path, false).catch((err) => {
              if (err instanceof RateLimitError) throw err; // only rate limit stops the whole thing
              // Swallow per-file failures: shown again on manual toggle
            }),
          ),
        );
      }
    } catch (err) {
      // Prefetch gives up quietly; only the user-action path surfaces error UI
      console.debug("prefablens: prefetch aborted", err);
    }
  }

  return { semanticDiff, prefetch };
}
