import { applyResolved } from "../../domain/diff/resolved";
import {
  type DiffTarget,
  type DiffV2,
  type GuidResolvedPush,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  targetKey,
  unresolvedRemaining,
} from "../../domain/diff/types";
import type { DiffCachePort } from "../port/diff-cache";
import { DiffError, type DifferPort } from "../port/differ";
import { AuthError, type ChangedFile, type GithubPort, RateLimitError, type RefPair } from "../port/github";
import type { GuidCachePort } from "../port/guid-cache";
import type { RepoIndexPort } from "../port/repo-index";
import { buildGuidIndex } from "./build-guid-index";
import { createPromiseCache } from "./promise-cache";
import { createResolution, type DiffContext, type Resolution } from "./resolution";

export type DiffDeps = {
  getSettings(): Promise<{ accessToken?: string }>;
  makeClient(base: string, token: string, lane: "user" | "prefetch"): GithubPort;
  getDiffer(): Promise<DifferPort>;
  guidCache: GuidCachePort;
  diffStore: DiffCachePort;
  repoIndexStore: RepoIndexPort;
};

// Per-kind: refs + changed-file discovery; everything downstream is target-agnostic
async function loadRefsAndFiles(
  client: GithubPort,
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

type DiffOutcome =
  | { ok: true; json: DiffV2 }
  | { ok: false; error: "too-large"; bytes: number }
  | { ok: false; error: "not-unity-yaml" };

export type DiffEngine = {
  deps: DiffDeps;
  apiBase: string;
  resolution: Resolution<GithubPort>;
  loadContext(client: GithubPort, owner: string, repo: string, target: DiffTarget): Promise<DiffContext>;
  getDiff(
    client: GithubPort,
    ctx: DiffContext,
    owner: string,
    repo: string,
    path: string,
    force: boolean,
  ): Promise<DiffOutcome>;
  semanticDiff(req: SemanticDiffRequest, push: (msg: GuidResolvedPush) => void): Promise<SemanticDiffResponse>;
};

export function createDiffEngine(deps: DiffDeps): DiffEngine {
  // Per-PR context; SW kill → re-fetch
  const contexts = createPromiseCache<DiffContext>({ ttlMs: CONTEXT_TTL_MS });
  // sha+path → bytes; promise fold shares prefetch + toggle fetches
  const blobs = createPromiseCache<Uint8Array | null>({ max: BLOB_CACHE_MAX });
  // too-large dropped so force can recompute; not-unity-yaml stays cached
  const diffs = createPromiseCache<DiffOutcome>({ retain: (o) => o.ok || o.error !== "too-large" });
  const apiBase = __API_BASE__;

  // Prefer blob-sha when known (#110); 404 (force push) falls back to path+ref
  function fetchBlob(
    client: GithubPort,
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
    client: GithubPort,
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

  function loadContext(client: GithubPort, owner: string, repo: string, target: DiffTarget): Promise<DiffContext> {
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
    client: GithubPort,
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
    client: GithubPort,
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
      if (!settings.accessToken) return { ok: false, error: "access-token-missing" };
      const client = deps.makeClient(apiBase, settings.accessToken, "user");
      const ctx = await loadContext(client, req.owner, req.repo, req.target);
      const outcome = await getDiff(client, ctx, req.owner, req.repo, req.path, req.force === true);
      if (!outcome.ok) return outcome;
      const withPr = applyResolved(outcome.json, ctx.guidIndex);

      // Return immediately; resolution + source merge continue via push
      const remaining = unresolvedRemaining(withPr);
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolution.resolveRemaining(withPr, remaining, client, req, apiBase, ctx, push);
      return { ok: true, json: withPr, pending: true };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: "rate-limited" };
      if (err instanceof AuthError) return { ok: false, error: "auth-failed" };
      if (err instanceof DiffError) return { ok: false, error: "diff-failed" };
      return { ok: false, error: "fetch-failed" }; // don't put raw errors in the response
    }
  }

  return { deps, apiBase, resolution, loadContext, getDiff, semanticDiff };
}
