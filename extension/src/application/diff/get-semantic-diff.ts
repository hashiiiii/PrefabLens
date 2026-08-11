import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type { DiffV2 } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DifferGateway } from "../gateway/differ";
import { type GithubGateway, isRateLimited, type MakeGithubClient } from "../gateway/github";
import type {
  GuidResolvedPush,
  ResolutionStatus,
  SemanticDiffRequest,
  SemanticDiffResponse,
} from "../gateway/messenger";
import { API_BASE } from "../internal/api-base";
import { mergeGithubSources } from "../internal/github-source-merge";
import { resolveGuids } from "../internal/guid-resolution";
import { getContext, getDiff, getPair } from "../internal/raw-diff";
import { getRepoIndex } from "../internal/repo-index";
import type { DiffContext, DiffSession } from "./create-diff-session";

type ResolutionClient = Pick<
  GithubGateway,
  "searchMetaByGuid" | "listMetaTree" | "batchBlobTexts" | "getBlobRaw" | "getFileAtRef"
>;

// Background: the index, then Code Search, then the source re-merge via push. The catch still emits done to release waiters.
async function updateRemaining(
  guidCache: GuidRepository,
  session: DiffSession,
  client: ResolutionClient,
  owner: string,
  repo: string,
  repoKey: string,
  repoIndexStore: RepoIndexRepository,
  getDiffer: () => Promise<DifferGateway>,
  first: DiffV2,
  remaining: string[],
  request: SemanticDiffRequest,
  context: DiffContext,
  push: (message: GuidResolvedPush) => void,
): Promise<void> {
  const at = { owner: request.owner, repo: request.repo, target: request.target, path: request.path };
  try {
    // Empty remaining (source re-merge only) skips the index: the first build can take tens of seconds
    const index = remaining.length
      ? await getRepoIndex(repoIndexStore, session, client, owner, repo, repoKey, context.refs.headSha)
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
        // The hits land in guidCache: source merging rebuilds via applyResolved. Without this save, index hits vanish.
        await guidCache.save(repoKey, fromIndex);
        // Deliver the available names first. The later final push makes the structure final.
        push({ type: "guidResolved", ...at, resolved: fromIndex, done: false });
      }
    }
    // Only guids missing from the index go to Code Search
    const search = leftover.length
      ? await resolveGuids(guidCache, session, client, owner, repo, repoKey, leftover)
      : { resolved: {}, rateLimited: false };
    let status: ResolutionStatus = search.rateLimited ? "rateLimited" : "complete";
    let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
    if (json.neededSources?.length) {
      // Resolution advanced, so the source merge runs again: a source guid can be resolved now.
      // getDiffer is memoized. When the wasm is already loaded, an early start costs nothing.
      const [differ, pair] = await Promise.all([
        getDiffer(),
        getPair(session, client, context, owner, repo, request.path),
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
      const merged = await mergeGithubSources(
        differ,
        guidCache,
        session,
        client,
        owner,
        repo,
        repoKey,
        context,
        before,
        after,
        json,
      );
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

  // Return immediately. Resolution and the source merge continue via push.
  const remaining = unresolvedRemaining(withPr);
  if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
  void updateRemaining(
    guidCache,
    session,
    client,
    req.owner,
    req.repo,
    repoKey(API_BASE, req.owner, req.repo),
    repoIndexStore,
    getDiffer,
    withPr,
    remaining,
    req,
    ctx,
    push,
  );
  return { ok: true, json: withPr, pending: true };
}
