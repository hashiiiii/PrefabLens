import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type {
  DiffV2,
  GuidResolvedPush,
  ResolutionStatus,
  SemanticDiffRequest,
  SemanticDiffResponse,
} from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DifferGateway } from "../gateway/differ";
import { type GithubGateway, isRateLimited } from "../gateway/github";
import { getBlob, getContext, getDiff, getPair } from "../internal/raw-diff";
import { getRepoIndex } from "../internal/repo-index";
import type { DiffContext, DiffSession } from "./create-diff-session";

const API_BASE = __API_BASE__;
const MAX_SEARCHES = 10; // Code Search is authenticated 10 req/min — don't burn it all in one response
const MAX_SOURCE_ROUNDS = 3; // re-diff cap for nested sources (independent of core's depth cap of 8)

type SearchClient = Pick<GithubGateway, "searchMetaByGuid" | "listMetaTree" | "batchBlobTexts">;
type ResolutionClient = SearchClient & Pick<GithubGateway, "getBlobRaw" | "getFileAtRef">;

// cache → Code Search; failures (incl. rate limits) don't drop the diff — return what resolved
async function getGuids(
  guidCache: GuidRepository,
  session: DiffSession,
  guids: string[],
  client: SearchClient,
  owner: string,
  repo: string,
  repoKey: string,
): Promise<{ resolved: Record<string, string>; rateLimited: boolean }> {
  if (!guids.length) return { resolved: {}, rateLimited: false };
  // hasOwn: guids are arbitrary strings, so 'constructor' etc. don't hit Object.prototype
  // Index hits also land in guidCache, so emit cached names even when listed in misses
  const cached = await guidCache.load(repoKey);
  const resolved: Record<string, string> = {};
  const unknown: string[] = [];
  for (const g of guids) {
    const hit = Object.hasOwn(cached, g) ? cached[g] : undefined;
    if (hit !== undefined) resolved[g] = hit;
    else unknown.push(g);
  }
  const searchable = unknown.filter((g) => !session.misses.has(`${repoKey}:${g}`));
  const found: Record<string, string> = {};
  let rateLimited = false;
  for (const g of searchable.slice(0, MAX_SEARCHES)) {
    const key = `${repoKey}:${g}`;
    const pathResult = await session.searches.get(key, () => client.searchMetaByGuid(owner, repo, g));
    if (!pathResult.ok) {
      // Rate limit truncates the run: report it instead of degrading silently (#194)
      if (isRateLimited(pathResult.error)) {
        rateLimited = true;
        break;
      }
      session.misses.add(key);
      continue;
    }
    if (pathResult.value) resolved[g] = found[g] = pathResult.value;
    else session.misses.add(key);
  }
  if (Object.keys(found).length) await guidCache.save(repoKey, found);
  return { resolved, rateLimited };
}

// Unresolved-by-in-PR-.meta → cache → Code Search; rateLimited folds into updateSources status
async function getUnresolved(
  guidCache: GuidRepository,
  session: DiffSession,
  json: DiffV2,
  client: SearchClient,
  owner: string,
  repo: string,
  repoKey: string,
): Promise<{ json: DiffV2; rateLimited: boolean }> {
  const resolved = { ...json.resolved };
  const pending = unresolvedRemaining(json);
  const found = await getGuids(guidCache, session, pending, client, owner, repo, repoKey);
  return { json: { ...json, resolved: { ...resolved, ...found.resolved } }, rateLimited: found.rateLimited };
}

// Fetch neededSources via resolved path and re-diff with assets; failure degrades (doesn't drop)
async function updateSources(
  guidCache: GuidRepository,
  session: DiffSession,
  first: DiffV2,
  differ: DifferGateway,
  before: Uint8Array,
  after: Uint8Array,
  ctx: DiffContext,
  client: ResolutionClient,
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
      const bytesResult = await getBlob(session, client, owner, repo, path, sha, blobSha);
      if (!bytesResult.ok) {
        // Degrade to first-pass diff, but tell the caller why (#194)
        return { json: current, status: isRateLimited(bytesResult.error) ? "rateLimited" : "failed" };
      }
      const bytes = bytesResult.value;
      if (!bytes) continue;
      // Binary-serialized sources are a no-op re-diff — don't count as progress
      if (!differ.isUnityYaml(bytes)) continue;
      assets.set(s.guid, bytes);
      progressed = true;
    }
    if (!progressed) break;
    const mergedResult = differ.diffWithAssets(before, after, assets);
    if (!mergedResult.ok) return { json: current, status: "failed" }; // merge failure degrades to current result
    const merged = mergedResult.value;
    // Merging surfaces new external refs inside the source, so resolve again
    const next = await getUnresolved(
      guidCache,
      session,
      applyResolved(merged, ctx.guidIndex),
      client,
      owner,
      repo,
      repoKey,
    );
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
async function updateRemaining(
  guidCache: GuidRepository,
  repoIndexStore: RepoIndexRepository,
  getDiffer: () => Promise<DifferGateway>,
  session: DiffSession,
  first: DiffV2,
  remaining: string[],
  client: ResolutionClient,
  req: SemanticDiffRequest,
  apiBase: string,
  ctx: DiffContext,
  push: (msg: GuidResolvedPush) => void,
): Promise<void> {
  const key = repoKey(apiBase, req.owner, req.repo);
  const at = { owner: req.owner, repo: req.repo, target: req.target, path: req.path };
  try {
    // Empty remaining (source re-merge only): skip index — first build can take tens of seconds
    const index = remaining.length
      ? await getRepoIndex(repoIndexStore, session, client, req.owner, req.repo, key, ctx.refs.headSha)
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
        // Land in guidCache: updateSources rebuilds via applyResolved; without this, index hits vanish
        await guidCache.save(key, fromIndex);
        // Deliver available names first; structure finalized by the later final push
        push({ type: "guidResolved", ...at, resolved: fromIndex, done: false });
      }
    }
    // Only guids missing from the index go to Code Search
    const search = leftover.length
      ? await getGuids(guidCache, session, leftover, client, req.owner, req.repo, key)
      : { resolved: {}, rateLimited: false };
    let status: ResolutionStatus = search.rateLimited ? "rateLimited" : "complete";
    let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
    if (json.neededSources?.length) {
      // Resolution advanced — redo source merging (source guid may have resolved this time)
      const differ = await getDiffer();
      const pair = await getPair(session, client, ctx, req.owner, req.repo, req.path);
      if (!pair.ok) {
        push({
          type: "guidResolved",
          ...at,
          resolved: {},
          done: true,
          status: isRateLimited(pair.error) ? "rateLimited" : "failed",
        });
        return;
      }
      const [before, after] = pair.value;
      const merged = await updateSources(
        guidCache,
        session,
        json,
        differ,
        before,
        after,
        ctx,
        client,
        req.owner,
        req.repo,
        key,
      );
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
      status: isRateLimited(err) ? "rateLimited" : "failed",
    });
  }
}

export async function getSemanticDiff(
  tokenStore: TokenRepository,
  makeClient: (base: string, token: string, lane: "user" | "prefetch") => GithubGateway,
  getDiffer: () => Promise<DifferGateway>,
  guidCache: GuidRepository,
  diffStore: DiffRepository,
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  req: SemanticDiffRequest,
  push: (msg: GuidResolvedPush) => void,
): Promise<SemanticDiffResponse> {
  const accessToken = await tokenStore.readAccessToken();
  if (!accessToken) return { ok: false, error: "access-token-missing" };
  const client = makeClient(API_BASE, accessToken, "user");
  const ctxResult = await getContext(session, client, req.owner, req.repo, req.target);
  if (!ctxResult.ok) return { ok: false, error: ctxResult.error.kind };
  const ctx = ctxResult.value;
  const outcome = await getDiff(
    getDiffer,
    diffStore,
    session,
    client,
    ctx,
    req.owner,
    req.repo,
    req.path,
    req.force === true,
  );
  if (!outcome.ok) return outcome;
  const withPr = applyResolved(outcome.json, ctx.guidIndex);

  // Return immediately; resolution + source merge continue via push
  const remaining = unresolvedRemaining(withPr);
  if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
  void updateRemaining(
    guidCache,
    repoIndexStore,
    getDiffer,
    session,
    withPr,
    remaining,
    client,
    req,
    API_BASE,
    ctx,
    push,
  );
  return { ok: true, json: withPr, pending: true };
}
