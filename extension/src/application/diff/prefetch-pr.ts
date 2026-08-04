import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { repoKey } from "../../domain/diff/fn/repo-key";
import type { PrefetchRequest } from "../../domain/diff/types";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { isUnityPath } from "../../domain/unity/fn/is-unity-path";
import type { DifferGateway } from "../gateway/differ";
import type { MakeGithubClient } from "../gateway/github";
import { API_BASE } from "../internal/api-base";
import { getContext, getDiff } from "../internal/raw-diff";
import { getRepoIndex } from "../internal/repo-index";
import type { DiffSession } from "./create-diff-session";

const PREFETCH_MAX = 100; // bounds API usage per PR
const PREFETCH_CONCURRENCY = 4;

// Raw diff only. Code Search and the source merge stay at serve time (10 req/min).
export async function prefetchPr(
  tokenStore: TokenRepository,
  makeClient: MakeGithubClient,
  getDiffer: () => Promise<DifferGateway>,
  diffStore: DiffRepository,
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  req: PrefetchRequest,
): Promise<void> {
  try {
    const accessToken = await tokenStore.readAccessToken();
    if (!accessToken) return;
    const client = makeClient(API_BASE, accessToken, "prefetch");
    const ctxResult = await getContext(session, client, req.owner, req.repo, { kind: "pull", prNumber: req.prNumber });
    if (!ctxResult.ok) {
      console.debug("prefablens: prefetch aborted", ctxResult.error);
      return;
    }
    const ctx = ctxResult.value;
    // Index sync independent of raw-diff prefetch (speeds 3-stage resolution at serve time)
    void getRepoIndex(
      repoIndexStore,
      session,
      client,
      req.owner,
      req.repo,
      repoKey(API_BASE, req.owner, req.repo),
      ctx.refs.headSha,
    );
    const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
    for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
      const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
      const outcomes = await Promise.all(
        chunk.map((f) => getDiff(getDiffer, diffStore, session, client, ctx, req.owner, req.repo, f.path, false)),
      );
      // Only a rate limit stops the whole run. Other per-file failures appear again on a manual toggle.
      if (outcomes.some((o) => !o.ok && o.error === "rate-limited")) {
        console.debug("prefablens: prefetch aborted", { kind: "rate-limited" });
        return;
      }
    }
  } catch (err) {
    // Prefetch stops quietly. Only the user-action path shows error UI.
    console.debug("prefablens: prefetch aborted", err);
  }
}
