import { applyResolved } from "../../domain/diff/resolved";
import {
  type DiffV2,
  type GuidResolvedPush,
  type ResolutionStatus,
  type SemanticDiffRequest,
  unresolvedRemaining,
} from "../../domain/diff/types";
import { syncRepoIndex } from "../../infrastructure/github/repoIndex";
import type { DifferPort } from "../port/differ";
import { type ChangedFile, type GithubPort, RateLimitError, type RefPair } from "../port/github";
import type { GuidCachePort } from "../port/guid-cache";
import type { RepoIndexPort } from "../port/repo-index";
import { createPromiseCache } from "./promise-cache";

// Pipeline's GitHub surface; callers thread a richer client through C so injected fetchers keep their view
export type SearchClient = Pick<GithubPort, "searchMetaByGuid" | "listMetaTree" | "batchBlobTexts">;

// baseShas: path → blob sha at base. null = tree unavailable → contents-api fallback
export type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
};

const MAX_SEARCHES = 10; // Code Search is authenticated 10 req/min — don't burn it all in one response
const MAX_SOURCE_ROUNDS = 3; // re-diff cap for nested sources (independent of core's depth cap of 8)

export type ResolutionDeps<C extends SearchClient> = {
  guidCache: GuidCachePort;
  repoIndexStore: RepoIndexPort;
  getDiffer(): Promise<DifferPort>;
  // Handler's cached blob fetcher (sha+path keyed, blob-sha fast path)
  fetchBlob(
    client: C,
    owner: string,
    repo: string,
    path: string,
    sha: string,
    blobSha?: string,
  ): Promise<Uint8Array | null>;
  // Handler's before/after pair fetcher (status/previousPath follow the files API)
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
    differ: DifferPort,
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

// Beyond in-PR .meta: repo index → Code Search + source re-merge. Blob/diff caches stay in the handler.
export function createResolution<C extends SearchClient>(deps: ResolutionDeps<C>): Resolution<C> {
  // Code Search misses; indexing lag → SW lifetime only (not persisted)
  const misses = new Set<string>();
  // Fold concurrent searches for the same guid (protects 10 req/min); nothing retained after settle
  const searches = createPromiseCache<string | null>({ retain: () => false });
  // repoKey@ref → whole-repo index; null = not indexable (truncated/over the cap)
  const indexes = createPromiseCache<Record<string, string> | null>();
  // Rate-limited repos skip the index for the SW lifetime (Code Search only)
  const indexFallback = new Set<string>();

  // cache → Code Search; failures (incl. rate limits) don't drop the diff — return what resolved
  async function searchGuids(
    guids: string[],
    client: C,
    owner: string,
    repo: string,
    repoKey: string,
  ): Promise<{ resolved: Record<string, string>; rateLimited: boolean }> {
    if (!guids.length) return { resolved: {}, rateLimited: false };
    // hasOwn: guids are arbitrary strings, so 'constructor' etc. don't hit Object.prototype
    // Index hits also land in guidCache, so emit cached names even when listed in misses
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
        // Rate limit truncates the run: report it instead of degrading silently (#194)
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

  // Unresolved-by-in-PR-.meta → cache → Code Search; rateLimited folds into mergeSources status
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

  // Memoized whole-repo index; rate-limited repos stay on fallback for the SW lifetime
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
        // Cache already dropped the failure, so the next visit retries
        if (err instanceof RateLimitError) indexFallback.add(repoKey);
        return null;
      });
  }

  // Fetch neededSources via resolved path and re-diff with assets; failure degrades (doesn't drop)
  async function mergeSources(
    first: DiffV2,
    differ: DifferPort,
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
        // Sources aren't PR files: only base tree can supply a sha; head keeps path fallback
        const blobSha = s.side === "before" ? ctx.baseShas?.get(path) : undefined;
        let bytes: Uint8Array | null = null;
        try {
          bytes = await deps.fetchBlob(client, owner, repo, path, sha, blobSha);
        } catch (err) {
          // Degrade to first-pass diff, but tell the caller why (#194)
          return { json: current, status: err instanceof RateLimitError ? "rateLimited" : "failed" };
        }
        if (!bytes) continue;
        // Binary-serialized sources are a no-op re-diff — don't count as progress
        if (!differ.isUnityYaml(bytes)) continue;
        assets.set(s.guid, bytes);
        progressed = true;
      }
      if (!progressed) break;
      let merged: DiffV2;
      try {
        merged = differ.diffWithAssets(before, after, assets);
      } catch {
        return { json: current, status: "failed" }; // merge failure degrades to current result
      }
      // Merging surfaces new external refs inside the source, so resolve again
      const next = await searchUnresolved(applyResolved(merged, ctx.guidIndex), client, owner, repo, repoKey);
      rateLimited ||= next.rateLimited;
      current = next.json;
    }
    return { json: current, status: rateLimited ? "rateLimited" : "complete" };
  }

  // rateLimited wins: most likely to succeed on manual retry
  function combine(a: ResolutionStatus, b: ResolutionStatus): ResolutionStatus {
    if (a === "rateLimited" || b === "rateLimited") return "rateLimited";
    if (a === "failed" || b === "failed") return "failed";
    return "complete";
  }

  // Background index → Code Search + source re-merge via push; catch still emits done to release waiters
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
      // Empty remaining (source re-merge only): skip index — first build can take tens of seconds
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
          // Land in guidCache: mergeSources rebuilds via applyResolved; without this, index hits vanish
          await deps.guidCache.save(repoKey, fromIndex);
          // Deliver available names first; structure finalized by the later final push
          push({ type: "guidResolved", ...at, resolved: fromIndex, done: false });
        }
      }
      // Only guids missing from the index go to Code Search
      const search = leftover.length
        ? await searchGuids(leftover, client, req.owner, req.repo, repoKey)
        : { resolved: {}, rateLimited: false };
      let status: ResolutionStatus = search.rateLimited ? "rateLimited" : "complete";
      let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
      if (json.neededSources?.length) {
        // Resolution advanced — redo source merging (source guid may have resolved this time)
        const differ = await deps.getDiffer();
        const [before, after] = await deps.fetchPair(client, ctx, req.owner, req.repo, req.path);
        const merged = await mergeSources(json, differ, before, after, ctx, client, req.owner, req.repo, repoKey);
        json = merged.json;
        status = combine(status, merged.status);
      }
      push({ type: "guidResolved", ...at, resolved: {}, json, done: true, status }); // final push replaces json
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
