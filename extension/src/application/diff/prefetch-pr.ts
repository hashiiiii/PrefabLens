import type { AuthRepository } from "../../domain/auth/auth-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { repoKey } from "../../domain/diff/fn/repo-key";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { isUnityPath } from "../../domain/unity/fn/is-unity-path";
import type { DifferGateway } from "../gateway/differ";
import { type GithubGateway, isRateLimited, type MakeGithubGateway } from "../gateway/github";
import type { PrefetchRequest } from "../gateway/messenger";
import { API_BASE } from "../internal/api-base";
import { mergeGithubSourcesFromIndex } from "../internal/github-source-merge";
import { diffCacheKey, getContext, getDiff, getPair } from "../internal/raw-diff";
import { getRepoIndex } from "../internal/repo-index";
import type { DiffContext, DiffSession } from "./create-diff-session";

const PREFETCH_MAX = 100; // bounds API usage per PR
const PREFETCH_CONCURRENCY = 4;

export async function prefetchPr(
  authRepository: AuthRepository,
  makeGithubGateway: MakeGithubGateway,
  getDiffer: () => Promise<DifferGateway>,
  diffRepository: DiffRepository,
  repoIndexRepository: RepoIndexRepository,
  session: DiffSession,
  req: PrefetchRequest,
): Promise<void> {
  try {
    const accessToken = await authRepository.loadAccessToken();
    if (!accessToken) return;
    const githubGateway = makeGithubGateway(API_BASE, accessToken, "prefetch");
    const ctxResult = await getContext(session, githubGateway, req.owner, req.repo, {
      kind: "pull",
      prNumber: req.prNumber,
    });
    if (!ctxResult.ok) {
      console.debug("prefablens: prefetch aborted", ctxResult.error);
      return;
    }
    const ctx = ctxResult.value;
    const indexPromise = getRepoIndex(
      repoIndexRepository,
      session,
      githubGateway,
      req.owner,
      req.repo,
      repoKey(API_BASE, req.owner, req.repo),
      ctx.refs.headSha,
    );
    const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
    let stopped = false;

    const rawWork = async (): Promise<void> => {
      for (let i = 0; i < unity.length && !stopped; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        const outcomes = await Promise.all(
          chunk.map((f) =>
            getDiff(getDiffer, diffRepository, session, githubGateway, ctx, req.owner, req.repo, f.path, false),
          ),
        );
        if (outcomes.some((outcome) => !outcome.ok && outcome.error === "rate-limited")) stopped = true;
      }
    };

    const semanticWork = async (): Promise<void> => {
      const repoIndex = await indexPromise;
      const index = new Map(Object.entries(repoIndex ?? {}));
      for (const [guid, path] of ctx.guidIndex) index.set(guid, path);
      for (let i = 0; i < unity.length && !stopped; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        const outcomes = await Promise.all(
          chunk.map((file) =>
            preloadSemanticDiff(
              getDiffer,
              diffRepository,
              session,
              githubGateway,
              ctx,
              req.owner,
              req.repo,
              file.path,
              index,
            ),
          ),
        );
        if (outcomes.includes("rate-limited")) stopped = true;
      }
    };

    await Promise.all([rawWork(), semanticWork()]);
    if (stopped) console.debug("prefablens: prefetch aborted", { kind: "rate-limited" });
  } catch (err) {
    // Prefetch stops quietly. Only the user-action path shows error UI.
    console.debug("prefablens: prefetch aborted", err);
  }
}

async function preloadSemanticDiff(
  getDiffer: () => Promise<DifferGateway>,
  diffRepository: DiffRepository,
  session: DiffSession,
  githubGateway: GithubGateway,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
  index: Map<string, string>,
): Promise<"rate-limited" | undefined> {
  const outcome = await getDiff(getDiffer, diffRepository, session, githubGateway, ctx, owner, repo, path, false);
  if (!outcome.ok) return outcome.error === "rate-limited" ? "rate-limited" : undefined;

  let json = applyResolved(outcome.json, index);
  if (json.neededSources?.length) {
    const [differ, pair] = await Promise.all([getDiffer(), getPair(session, githubGateway, ctx, owner, repo, path)]);
    if (!pair.ok) return isRateLimited(pair.error) ? "rate-limited" : undefined;
    const [before, after] = pair.value;
    // This path uses the repo index. Code Search permits 10 authenticated requests each minute.
    const merged = await mergeGithubSourcesFromIndex(
      differ,
      session,
      githubGateway,
      owner,
      repo,
      ctx,
      before,
      after,
      json,
      index,
    );
    if (merged.status !== "complete") return merged.status === "rateLimited" ? "rate-limited" : undefined;
    json = merged.json;
  }
  await diffRepository.save(diffCacheKey(ctx, path), json);
  return undefined;
}
