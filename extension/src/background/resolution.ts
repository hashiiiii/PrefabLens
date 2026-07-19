import { type ChangedFile, type GithubClient, RateLimitError, type RefPair } from "../github/client";
import { applyResolved, type GuidCache } from "../github/guids";
import { type RepoIndexStore, syncRepoIndex } from "../github/repoIndex";
import {
  type DiffV2,
  type GuidResolvedPush,
  type ResolutionStatus,
  type SemanticDiffRequest,
  unresolvedRemaining,
} from "../types";
import type { Differ } from "../wasm/differ";
import { createPromiseCache } from "./promiseCache";

/** What the pipeline itself calls on the GitHub client. Callers thread their richer
 *  client through the generic C, so the injected fetchers keep their own view of it. */
export type SearchClient = Pick<GithubClient, "searchMetaByGuid" | "listMetaTree" | "batchBlobTexts">;

// baseShas: path → blob sha at the base ref. null = tree unavailable (truncated/failed) → contents-api fallback
export type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
};

const MAX_SEARCHES = 10; // Code Search is authenticated 10 req/min — don't burn it all in one response
const MAX_SOURCE_ROUNDS = 3; // re-diff cap for nested sources (independent of core's depth cap of 8)

export type ResolutionDeps<C extends SearchClient> = {
  guidCache: GuidCache;
  repoIndexStore: RepoIndexStore;
  getDiffer(): Promise<Differ>;
  /** The handler's cached blob fetcher (sha+path keyed, blob-sha fast path). */
  fetchBlob(
    client: C,
    owner: string,
    repo: string,
    path: string,
    sha: string,
    blobSha?: string,
  ): Promise<Uint8Array | null>;
  /** The handler's before/after pair fetcher (status/previousPath rules follow the files API). */
  fetchPair(client: C, ctx: DiffContext, owner: string, repo: string, path: string): Promise<[Uint8Array, Uint8Array]>;
};

export type Resolution<C extends SearchClient> = {
  searchGuids(
    guids: string[],
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ resolved: Record<string, string>; rateLimited: boolean }>;
  getRepoIndex(
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
    ref: string,
  ): Promise<Record<string, string> | null>;
  mergeSources(
    first: DiffV2,
    differ: Differ,
    before: Uint8Array,
    after: Uint8Array,
    ctx: DiffContext,
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ json: DiffV2; status: ResolutionStatus }>;
  resolveRemaining(
    first: DiffV2,
    remaining: string[],
    client: C,
    req: SemanticDiffRequest,
    base: string,
    ctx: DiffContext,
    push: (msg: GuidResolvedPush) => void,
  ): Promise<void>;
};

/** Guid resolution beyond the in-PR .meta index: whole-repo index → Code Search, plus the
 *  source prefab re-merge that resolution unlocks. Owns the search/index caches; blob and
 *  diff caching stay with the handler, injected through fetchBlob/fetchPair. */
export function createResolution<C extends SearchClient>(deps: ResolutionDeps<C>): Resolution<C> {
  // guids that missed in Code Search. Indexing lag means we don't persist these — SW lifetime only
  const misses = new Set<string>();
  // repoKey:guid → in-flight search, folding concurrent searches for the same guid into one (protects the
  // 10 req/min). Nothing is retained after settling: guidCache/misses take over from there.
  const searches = createPromiseCache<string | null>({ retain: () => false });
  // repoKey@ref → whole-repo index. null means not indexable (truncated/over the cap)
  const indexes = createPromiseCache<Record<string, string> | null>();
  // A repo that hit a rate limit falls back for the SW lifetime (gives up on the index and defers to Code Search only)
  const indexFallback = new Set<string>();

  /** Resolves guid[] in cache → Code Search order (the body of searchUnresolved itself).
   *  A search failure (including rate limits) doesn't drop the diff: returns only what was resolved. */
  async function searchGuids(
    guids: string[],
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ resolved: Record<string, string>; rateLimited: boolean }> {
    if (!guids.length) return { resolved: {}, rateLimited: false };
    // hasOwn: guids are arbitrary strings, so 'constructor' etc. don't falsely hit Object.prototype
    // The cached lookup covers all guids without going through misses: since index resolutions also land in guidCache,
    // a cached name is always emitted even if it's in misses (the search gatekeeper)
    const cached = await deps.guidCache.load(repoKey);
    const resolved: Record<string, string> = {};
    const unknown: string[] = [];
    for (const g of guids) {
      const hit = Object.hasOwn(cached, g) ? cached[g] : undefined;
      if (hit !== undefined) resolved[g] = hit;
      else unknown.push(g);
    }
    const searchable = unknown.filter((g) => !misses.has(`${repoKey}:${g}`));
    const found: Record<string, string> = {};
    let rateLimited = false;
    for (const g of searchable.slice(0, MAX_SEARCHES)) {
      const key = `${repoKey}:${g}`;
      try {
        const path = await searches.get(key, () => client.searchMetaByGuid(owner, repo, g));
        if (path) resolved[g] = found[g] = path;
        else misses.add(key);
      } catch (err) {
        // A rate limit truncates the run: report it instead of degrading silently (#194).
        if (err instanceof RateLimitError) {
          rateLimited = true;
          break;
        }
        misses.add(key);
      }
    }
    if (Object.keys(found).length) await deps.guidCache.save(repoKey, found);
    return { resolved, rateLimited };
  }

  /** Thin wrapper that resolves guids unresolved by in-PR .meta in cache → Code Search
   *  order, reporting whether a rate limit truncated the search (mergeSources folds the
   *  flag into its own status). */
  async function searchUnresolved(
    json: DiffV2,
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ json: DiffV2; rateLimited: boolean }> {
    const resolved = { ...json.resolved };
    const pending = unresolvedRemaining(json);
    const found = await searchGuids(pending, client, owner, repo, repoKey);
    return { json: { ...json, resolved: { ...resolved, ...found.resolved } }, rateLimited: found.rateLimited };
  }

  /** Fetches and memoizes the whole-repo guid index. A repo that hit a rate limit is pinned to fallback for the SW lifetime. */
  function getRepoIndex(
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
    ref: string,
  ): Promise<Record<string, string> | null> {
    if (indexFallback.has(repoKey)) return Promise.resolve(null);
    return indexes
      .get(`${repoKey}@${ref}`, () => syncRepoIndex(client, deps.repoIndexStore, owner, repo, repoKey, ref))
      .catch((err: unknown) => {
        // the cache has already dropped the failure, so the next visit retries
        if (err instanceof RateLimitError) indexFallback.add(repoKey);
        return null;
      });
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
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ json: DiffV2; status: ResolutionStatus }> {
    const assets = new Map<string, Uint8Array>();
    let current = first;
    let rateLimited = false;
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
          bytes = await deps.fetchBlob(client, owner, repo, path, sha, blobSha);
        } catch (err) {
          // degrade to the first-pass diff, but tell the caller why (#194)
          return { json: current, status: err instanceof RateLimitError ? "rateLimited" : "failed" };
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
        return { json: current, status: "failed" }; // a merge failure degrades to the current result
      }
      // Merging surfaces new external references (script/material) inside the source, so resolve again.
      const next = await searchUnresolved(applyResolved(merged, ctx.guidIndex), client, owner, repo, repoKey);
      rateLimited ||= next.rateLimited;
      current = next.json;
    }
    return { json: current, status: rateLimited ? "rateLimited" : "complete" };
  }

  /** rateLimited wins over failed: it is the outcome a manual retry is most likely to fix. */
  function combine(a: ResolutionStatus, b: ResolutionStatus): ResolutionStatus {
    if (a === "rateLimited" || b === "rateLimited") return "rateLimited";
    if (a === "failed" || b === "failed") return "failed";
    return "complete";
  }

  /** Runs the rest of the 3-stage resolution (index → Code Search) and source re-merge in the background, delivering results via push.
   *  On failure it still emits a done push in catch to release waiters. */
  async function resolveRemaining(
    first: DiffV2,
    remaining: string[],
    client: C,
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
        for (const g of remaining) {
          const hit = Object.hasOwn(index, g) ? index[g] : undefined;
          if (hit !== undefined) fromIndex[g] = hit;
        }
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
      const search = leftover.length
        ? await searchGuids(leftover, client, req.owner, req.repo, repoKey)
        : { resolved: {}, rateLimited: false };
      let status: ResolutionStatus = search.rateLimited ? "rateLimited" : "complete";
      let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
      if (json.neededSources?.length) {
        // Resolution advanced, so redo source merging (picks up the case where the source guid resolved this time)
        const differ = await deps.getDiffer();
        const [before, after] = await deps.fetchPair(client, ctx, req.owner, req.repo, req.path);
        const merged = await mergeSources(json, differ, before, after, ctx, client, req.owner, req.repo, repoKey);
        json = merged.json;
        status = combine(status, merged.status);
      }
      push({ type: "guidResolved", ...at, resolved: {}, json, done: true, status }); // the final push replaces json
    } catch (err) {
      console.debug("prefablens: guid resolution aborted", err);
      push({
        type: "guidResolved",
        ...at,
        resolved: {},
        done: true,
        status: err instanceof RateLimitError ? "rateLimited" : "failed",
      });
    }
  }

  return { searchGuids, getRepoIndex, mergeSources, resolveRemaining };
}
