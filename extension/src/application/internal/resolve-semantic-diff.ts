import type { DiffV2 } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DiffContext, DiffSession } from "../diff/create-diff-session";
import type { DifferGateway } from "../gateway/differ";
import { type GithubGateway, isRateLimited } from "../gateway/github";
import type { GuidResolvedPush, ResolutionStatus, SemanticDiffRequest } from "../gateway/messenger";
import { mergeGithubSources } from "./github-source-merge";
import { resolveGuids } from "./guid-resolution";
import { getPair } from "./raw-diff";
import { getRepoIndex } from "./repo-index";

export async function* resolveSemanticDiff(
  guidCache: GuidRepository,
  repoIndexStore: RepoIndexRepository,
  getDiffer: () => Promise<DifferGateway>,
  session: DiffSession,
  client: GithubGateway,
  context: DiffContext,
  repoKey: string,
  first: DiffV2,
  remaining: string[],
  request: SemanticDiffRequest,
): AsyncGenerator<GuidResolvedPush> {
  const { owner, repo } = request;
  const at = { owner, repo, target: request.target, path: request.path };
  let status: ResolutionStatus = "complete";
  try {
    // An index build can take tens of seconds and cannot add a name when no GUID remains.
    const index = remaining.length
      ? await getRepoIndex(repoIndexStore, session, client, owner, repo, repoKey, context.refs.headSha)
      : null;
    const fromIndex: Record<string, string> = {};
    let leftover = remaining;
    if (index) {
      leftover = [];
      for (const guid of remaining) {
        const hit = Object.hasOwn(index, guid) ? index[guid] : undefined;
        if (hit !== undefined) fromIndex[guid] = hit;
        else leftover.push(guid);
      }
      if (Object.keys(fromIndex).length) {
        // The source merge reads these names from the GUID cache.
        await guidCache.save(repoKey, fromIndex);
        yield { type: "guidResolved", ...at, resolved: fromIndex, done: false };
      }
    }
    const search = leftover.length
      ? await resolveGuids(guidCache, session, client, owner, repo, repoKey, leftover)
      : { resolved: {}, rateLimited: false };
    status = search.rateLimited ? "rateLimited" : "complete";
    let json: DiffV2 = { ...first, resolved: { ...first.resolved, ...fromIndex, ...search.resolved } };
    if (json.neededSources?.length) {
      // Parallel startup keeps the source re-merge off the critical path.
      const [differ, pair] = await Promise.all([
        getDiffer(),
        getPair(session, client, context, owner, repo, request.path),
      ]);
      if (!pair.ok) {
        yield {
          type: "guidResolved",
          ...at,
          resolved: {},
          done: true,
          status: status === "rateLimited" || isRateLimited(pair.error) ? "rateLimited" : "failed",
        };
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
      // A manual retry has the best chance to recover from a rate limit.
      if (status !== "rateLimited") status = merged.status;
    }
    yield { type: "guidResolved", ...at, resolved: {}, json, done: true, status };
  } catch (error) {
    console.debug("prefablens: guid resolution aborted", error);
    yield {
      type: "guidResolved",
      ...at,
      resolved: {},
      done: true,
      status: status === "rateLimited" || isRateLimited(error) ? "rateLimited" : "failed",
    };
  }
}
