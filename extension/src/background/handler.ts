import {
  API_BASE,
  AuthError,
  type ChangedFile,
  type GithubClient,
  RateLimitError,
  type RefPair,
} from "../github/client";
import { applyResolved, buildGuidIndex, type GuidCache } from "../github/guids";
import { type RepoIndexStore, syncRepoIndex } from "../github/repoIndex";
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

// baseShas: path → blob sha at the base ref. null = tree unavailable (truncated/failed) → contents-api fallback
type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
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
    client.resolveRefSha(owner, repo, target.head), // cache keys need an immutable sha, not a branch name
  ]);
  return { refs: { baseSha: cmp.mergeBaseSha, headSha }, files: cmp.files };
}

const EMPTY = new Uint8Array(0);
const MAX_SEARCHES = 10; // Code Search is authenticated 10 req/min — don't burn it all in one response
const MAX_SOURCE_ROUNDS = 3; // re-diff cap for nested sources (independent of core's depth cap of 8)
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
  // Per-PR context cache. The SW may be killed at any time; then we just re-fetch.
  const contexts = new Map<string, { at: number; ctx: Promise<DiffContext> }>();
  // sha+path → bytes Promise. Storing a Promise folds concurrent prefetch and manual-toggle requests into one fetch.
  const blobs = new Map<string, Promise<Uint8Array | null>>();
  // guids that missed in Code Search. Indexing lag means we don't persist these — SW lifetime only
  const misses = new Set<string>();
  // repoKey:guid → in-flight search. Folds concurrent searches for the same guid into one (protects the 10 req/min)
  const searches = new Map<string, Promise<string | null>>();
  // baseSha:headSha:path → raw diff computation Promise. Keeps only successes (too-large/failure allow recomputation)
  const diffs = new Map<string, Promise<DiffOutcome>>();
  // repoKey@ref → whole-repo index Promise. null means not indexable (truncated/over the cap/failure)
  const indexes = new Map<string, Promise<Record<string, string> | null>>();
  // A repo that hit a rate limit falls back for the SW lifetime (gives up on the index and defers to Code Search only)
  const indexFallback = new Set<string>();

  /** Resolves guid[] in cache → Code Search order (the body of searchUnresolved itself).
   *  A search failure (including rate limits) doesn't drop the diff: returns only what was resolved. */
  async function searchGuids(
    guids: string[],
    client: ClientLike,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<Record<string, string>> {
    if (!guids.length) return {};
    // hasOwn: guids are arbitrary strings, so 'constructor' etc. don't falsely hit Object.prototype
    // The cached lookup covers all guids without going through misses: since index resolutions also land in guidCache,
    // a cached name is always emitted even if it's in misses (the search gatekeeper)
    const cached = await deps.guidCache.load(repoKey);
    const resolved: Record<string, string> = {};
    const unknown: string[] = [];
    for (const g of guids) {
      if (Object.hasOwn(cached, g)) resolved[g] = cached[g]!;
      else unknown.push(g);
    }
    const searchable = unknown.filter((g) => !misses.has(`${repoKey}:${g}`));
    const found: Record<string, string> = {};
    for (const g of searchable.slice(0, MAX_SEARCHES)) {
      const key = `${repoKey}:${g}`;
      try {
        let p = searches.get(key);
        if (!p) {
          p = client.searchMetaByGuid(owner, repo, g);
          searches.set(key, p);
          void p.catch(() => {}).then(() => searches.delete(key)); // after completion, guidCache/misses take over
        }
        const path = await p;
        if (path) resolved[g] = found[g] = path;
        else misses.add(key);
      } catch (err) {
        if (err instanceof RateLimitError) break;
        misses.add(key);
      }
    }
    if (Object.keys(found).length) await deps.guidCache.save(repoKey, found);
    return resolved;
  }

  /** Thin wrapper that resolves guids unresolved by in-PR .meta in cache → Code Search order.
   *  mergeSources calls it internally, so keep the signature and behavior unchanged. */
  async function searchUnresolved(
    json: DiffV2,
    client: ClientLike,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<DiffV2> {
    const resolved = { ...json.resolved };
    const pending = json.unresolvedGuids.filter((g) => !Object.hasOwn(resolved, g));
    const found = await searchGuids(pending, client, owner, repo, repoKey);
    return { ...json, resolved: { ...resolved, ...found } };
  }

  /** Fetches and memoizes the whole-repo guid index. A repo that hit a rate limit is pinned to fallback for the SW lifetime. */
  function getRepoIndex(
    client: ClientLike,
    owner: string,
    repo: string,
    repoKey: string,
    ref: string,
  ): Promise<Record<string, string> | null> {
    if (indexFallback.has(repoKey)) return Promise.resolve(null);
    const key = `${repoKey}@${ref}`;
    const hit = indexes.get(key);
    if (hit) return hit;
    const p = syncRepoIndex(client, deps.repoIndexStore, owner, repo, repoKey, ref).catch((err: unknown) => {
      indexes.delete(key); // don't cache failures: retry on the next visit
      if (err instanceof RateLimitError) indexFallback.add(repoKey);
      return null;
    });
    indexes.set(key, p);
    return p;
  }

  /** blobSha rides along when known (files API / merge-base tree): blob-by-sha latency is flat where
   *  contents-by-path stalls for seconds (#110). A 404 on the sha (force push) falls back to path+ref. */
  async function fetchBlob(
    client: ClientLike,
    owner: string,
    repo: string,
    path: string,
    sha: string,
    blobSha?: string,
  ): Promise<Uint8Array | null> {
    const key = blobSha ?? `${sha}:${path}`; // a blob sha never collides with the `${sha}:${path}` form
    const hit = blobs.get(key); // the stored value is Promise<Uint8Array | null>, so undefined = not cached
    if (hit !== undefined) return hit;
    const p = blobSha
      ? client.getBlobRaw(owner, repo, blobSha).then((bytes) => bytes ?? client.getFileAtRef(owner, repo, path, sha))
      : client.getFileAtRef(owner, repo, path, sha);
    p.catch(() => blobs.delete(key)); // don't keep failures: the next call can re-fetch
    blobs.set(key, p);
    if (blobs.size > BLOB_CACHE_MAX) blobs.delete(blobs.keys().next().value!);
    return p;
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

  /** Fetches neededSources (the source prefab of an added/removed instance) via the resolved
   *  path and re-diffs with assets attached. The source guid rides on unresolvedGuids as an
   *  m_SourcePrefab reference, so searchUnresolved has already done the path resolution.
   *  Failure to resolve/fetch/merge degrades to the diff at that point (doesn't drop the whole thing). */
  async function mergeSources(
    first: DiffV2,
    differ: Differ,
    before: Uint8Array,
    after: Uint8Array,
    ctx: DiffContext,
    client: ClientLike,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<DiffV2> {
    const assets = new Map<string, Uint8Array>();
    let current = first;
    for (let round = 0; round < MAX_SOURCE_ROUNDS; round++) {
      const needed = (current.neededSources ?? []).filter((s) => !assets.has(s.guid));
      if (!needed.length) break;
      let progressed = false;
      for (const s of needed) {
        const path = current.resolved?.[s.guid];
        if (path === undefined) continue;
        const sha = s.side === "before" ? ctx.refs.baseSha : ctx.refs.headSha;
        // sources aren't PR files, so only the base tree can supply a sha; the head side keeps the path fallback
        const blobSha = s.side === "before" ? ctx.baseShas?.get(path) : undefined;
        let bytes: Uint8Array | null = null;
        try {
          bytes = await fetchBlob(client, owner, repo, path, sha, blobSha);
        } catch {
          return current; // rate limit etc.: degrade to the first-pass diff
        }
        if (!bytes) continue;
        // Sources resolved by guid can be binary-serialized too: merging
        // them is a no-op re-diff, so don't count it as progress.
        if (!differ.isUnityYaml(bytes)) continue;
        assets.set(s.guid, bytes);
        progressed = true;
      }
      if (!progressed) break;
      let merged: DiffV2;
      try {
        merged = differ.diffWithAssets(before, after, assets);
      } catch {
        return current; // a merge failure degrades to the current result
      }
      // Merging surfaces new external references (script/material) inside the source, so resolve again.
      current = await searchUnresolved(applyResolved(merged, ctx.guidIndex), client, owner, repo, repoKey);
    }
    return current;
  }

  function loadContext(client: ClientLike, owner: string, repo: string, target: DiffTarget): Promise<DiffContext> {
    const key = targetKey(owner, repo, target);
    const entry = contexts.get(key);
    if (entry && Date.now() - entry.at < CONTEXT_TTL_MS) return entry.ctx;
    const ctx = (async () => {
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
    })();
    contexts.set(key, { at: Date.now(), ctx });
    ctx.catch(() => contexts.delete(key)); // don't cache failures
    return ctx;
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
    const hit = diffs.get(key);
    if (hit) return hit;
    const p = (async (): Promise<DiffOutcome> => {
      const stored = await deps.diffStore.load(key); // a result left by a prior SW life
      if (stored) return { ok: true, json: stored };
      const outcome = await computeDiff(client, ctx, owner, repo, path, force);
      if (outcome.ok) void deps.diffStore.save(key, outcome.json);
      return outcome;
    })();
    diffs.set(key, p);
    p.then(
      (o) => {
        // too-large allows a force recomputation; not-unity-yaml is
        // deterministic for the sha pair, so keep it cached in memory
        if (!o.ok && o.error === "too-large") diffs.delete(key);
      },
      () => diffs.delete(key),
    );
    return p;
  }

  /** Runs the rest of the 3-stage resolution (index → Code Search) and source re-merge in the background, delivering results via push.
   *  On failure it still emits a done push in catch to release waiters. */
  async function resolveRemaining(
    first: DiffV2,
    remaining: string[],
    client: ClientLike,
    req: SemanticDiffRequest,
    base: string,
    ctx: DiffContext,
    push: (msg: GuidResolvedPush) => void,
  ): Promise<void> {
    const repoKey = `${base}/${req.owner}/${req.repo}`;
    const at = { owner: req.owner, repo: req.repo, target: req.target, path: req.path };
    try {
      // If remaining is empty (source re-merge only), don't wait on the index: the first index build can take tens of seconds and doesn't help resolution
      const index = remaining.length
        ? await getRepoIndex(client, req.owner, req.repo, repoKey, ctx.refs.headSha)
        : null;
      const fromIndex: Record<string, string> = {};
      let leftover = remaining;
      if (index) {
        for (const g of remaining) if (Object.hasOwn(index, g)) fromIndex[g] = index[g]!;
        leftover = remaining.filter((g) => !Object.hasOwn(fromIndex, g));
        if (Object.keys(fromIndex).length) {
          // Also land it in guidCache: searchUnresolved inside mergeSources rebuilds resolved
          // from ctx.guidIndex via applyResolved, so without going through guidCache the index-derived
          // resolutions would vanish after the source re-merge (same reasoning as Code-Search-derived ones already restored this way).
          await deps.guidCache.save(repoKey, fromIndex);
          // Deliver the already-available names first (the structure is finalized by the later final push)
          push({ type: "guidResolved", ...at, resolved: fromIndex, done: false });
        }
      }
      // Only guids that aren't indexable or aren't in the index go to Code Search
      const fromSearch = leftover.length ? await searchGuids(leftover, client, req.owner, req.repo, repoKey) : {};
      let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...fromSearch } };
      if (json.neededSources?.length) {
        // Resolution advanced, so redo source merging (picks up the case where the source guid resolved this time)
        const differ = await deps.getDiffer();
        const [before, after] = await fetchPair(client, ctx, req.owner, req.repo, req.path);
        json = await mergeSources(json, differ, before, after, ctx, client, req.owner, req.repo, repoKey);
      }
      push({ type: "guidResolved", ...at, resolved: {}, json, done: true }); // the final push replaces json
    } catch (err) {
      console.debug("prefablens: guid resolution aborted", err);
      push({ type: "guidResolved", ...at, resolved: {}, done: true });
    }
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

      // Two-stage path: return the diff immediately, continue resolution and source merging in the background, deliver via push
      const remaining = withPr.unresolvedGuids.filter((g) => !Object.hasOwn(withPr.resolved ?? {}, g));
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolveRemaining(withPr, remaining, client, req, base, ctx, push);
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
      const settings = await deps.getSettings();
      if (!settings.pat) return;
      const base = API_BASE;
      const client = deps.makeClient(base, settings.pat, "prefetch");
      const ctx = await loadContext(client, req.owner, req.repo, { kind: "pull", prNumber: req.prNumber });
      // Run independently of raw-diff prefetch (index sync speeds up the 3-stage resolution at serve time)
      void getRepoIndex(client, req.owner, req.repo, `${base}/${req.owner}/${req.repo}`, ctx.refs.headSha);
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
