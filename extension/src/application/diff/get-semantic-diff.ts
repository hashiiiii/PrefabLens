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
import { type GithubGateway, isRateLimited, type MakeGithubClient, toBackgroundError } from "../gateway/github";
import { API_BASE } from "../internal/api-base";
import { getBlob, getContext, getDiff, getPair } from "../internal/raw-diff";
import { getRepoIndex } from "../internal/repo-index";
import { mergeSourceRounds } from "../internal/source-rounds";
import type { DiffContext, DiffSession } from "./create-diff-session";

const MAX_SEARCHES = 10; // Code Search is authenticated 10 req/min — don't burn it all in one response

type SearchClient = Pick<GithubGateway, "searchMetaByGuid" | "listMetaTree" | "batchBlobTexts">;
type ResolutionClient = SearchClient & Pick<GithubGateway, "getBlobRaw" | "getFileAtRef">;

// Everything that guid resolution threads through unchanged. Built one time per request.
type ResolveDeps = {
  guidCache: GuidRepository;
  session: DiffSession;
  client: ResolutionClient;
  owner: string;
  repo: string;
  repoKey: string;
};

// cache → Code Search; failures (incl. rate limits) don't drop the diff — return what resolved
async function getGuids(
  deps: ResolveDeps,
  guids: string[],
): Promise<{ resolved: Record<string, string>; rateLimited: boolean }> {
  if (!guids.length) return { resolved: {}, rateLimited: false };
  const { guidCache, session, client, owner, repo } = deps;
  // hasOwn: guids are arbitrary strings, so 'constructor' etc. don't hit Object.prototype
  // Index hits also land in guidCache, so emit cached names even when listed in misses
  const cached = await guidCache.load(deps.repoKey);
  const resolved: Record<string, string> = {};
  const unknown: string[] = [];
  for (const g of guids) {
    const hit = Object.hasOwn(cached, g) ? cached[g] : undefined;
    if (hit !== undefined) resolved[g] = hit;
    else unknown.push(g);
  }
  const searchable = unknown.filter((g) => !session.misses.has(`${deps.repoKey}:${g}`));
  const found: Record<string, string> = {};
  let rateLimited = false;
  for (const g of searchable.slice(0, MAX_SEARCHES)) {
    const key = `${deps.repoKey}:${g}`;
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
  if (Object.keys(found).length) await guidCache.save(deps.repoKey, found);
  return { resolved, rateLimited };
}

// Unresolved-by-in-PR-.meta → cache → Code Search; rateLimited folds into updateSources status
async function getUnresolved(deps: ResolveDeps, json: DiffV2): Promise<{ json: DiffV2; rateLimited: boolean }> {
  const found = await getGuids(deps, unresolvedRemaining(json));
  return { json: { ...json, resolved: { ...json.resolved, ...found.resolved } }, rateLimited: found.rateLimited };
}

function updateSources(
  deps: ResolveDeps,
  differ: DifferGateway,
  first: DiffV2,
  before: Uint8Array,
  after: Uint8Array,
  ctx: DiffContext,
): Promise<{ json: DiffV2; status: ResolutionStatus }> {
  return mergeSourceRounds(
    differ,
    before,
    after,
    first,
    async (s, path) => {
      const sha = s.side === "before" ? ctx.refs.baseSha : ctx.refs.headSha;
      // Sources aren't PR files: only base tree can supply a sha; head keeps path fallback
      const blobSha = s.side === "before" ? ctx.baseShas?.get(path) : undefined;
      const bytes = await getBlob(deps.session, deps.client, deps.owner, deps.repo, path, sha, blobSha);
      // The loop degrades to the diff so far but reports the cause (#194).
      if (!bytes.ok) return { abort: isRateLimited(bytes.error) ? "rateLimited" : "failed" };
      if (!bytes.value) return { skip: true };
      return { bytes: bytes.value };
    },
    (json) => getUnresolved(deps, applyResolved(json, ctx.guidIndex)),
  );
}

// Background index → Code Search + source re-merge via push; catch still emits done to release waiters
async function updateRemaining(
  deps: ResolveDeps,
  repoIndexStore: RepoIndexRepository,
  getDiffer: () => Promise<DifferGateway>,
  first: DiffV2,
  remaining: string[],
  req: SemanticDiffRequest,
  ctx: DiffContext,
  push: (msg: GuidResolvedPush) => void,
): Promise<void> {
  const at = { owner: req.owner, repo: req.repo, target: req.target, path: req.path };
  try {
    // Empty remaining (source re-merge only): skip index — first build can take tens of seconds
    const index = remaining.length
      ? await getRepoIndex(
          repoIndexStore,
          deps.session,
          deps.client,
          req.owner,
          req.repo,
          deps.repoKey,
          ctx.refs.headSha,
        )
      : null;
    const fromIndex: Record<string, string> = {};
    let leftover = remaining;
    if (index) {
      leftover = [];
      for (const g of remaining) {
        const hit = Object.hasOwn(index, g) ? index[g] : undefined;
        if (hit !== undefined) fromIndex[g] = hit;
        else leftover.push(g);
      }
      if (Object.keys(fromIndex).length) {
        // Land in guidCache: updateSources rebuilds via applyResolved; without this, index hits vanish
        await deps.guidCache.save(deps.repoKey, fromIndex);
        // Deliver available names first; structure finalized by the later final push
        push({ type: "guidResolved", ...at, resolved: fromIndex, done: false });
      }
    }
    // Only guids missing from the index go to Code Search
    const search = leftover.length ? await getGuids(deps, leftover) : { resolved: {}, rateLimited: false };
    let status: ResolutionStatus = search.rateLimited ? "rateLimited" : "complete";
    let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
    if (json.neededSources?.length) {
      // Resolution advanced, so the source merge runs again: a source guid can be resolved now.
      // getDiffer is memoized. When the wasm is already loaded, an early start costs nothing.
      const [differ, pair] = await Promise.all([
        getDiffer(),
        getPair(deps.session, deps.client, ctx, req.owner, req.repo, req.path),
      ]);
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
      const merged = await updateSources(deps, differ, json, before, after, ctx);
      json = merged.json;
      // rateLimited wins: this kind has the best chance to succeed on a manual retry.
      if (status !== "rateLimited") status = merged.status;
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
  makeClient: MakeGithubClient,
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
  if (!ctxResult.ok) return { ok: false, error: toBackgroundError(ctxResult.error) };
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
  const deps: ResolveDeps = {
    guidCache,
    session,
    client,
    owner: req.owner,
    repo: req.repo,
    repoKey: repoKey(API_BASE, req.owner, req.repo),
  };
  void updateRemaining(deps, repoIndexStore, getDiffer, withPr, remaining, req, ctx, push);
  return { ok: true, json: withPr, pending: true };
}
