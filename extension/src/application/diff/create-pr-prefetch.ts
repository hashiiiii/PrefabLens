import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import type { PrefetchRequest } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { isUnityPath } from "../../domain/unity";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { DiffSession } from "./_diff-session";
import { getContext } from "./_get-context";
import { getDiff } from "./_get-diff";
import { getRepoIndex } from "./_resolution";

const PREFETCH_MAX = 100; // bounds API usage per PR
const PREFETCH_CONCURRENCY = 4;
const API_BASE = __API_BASE__;

// Raw diff only — leave Code Search / updateSources to serve time (10 req/min)
export async function createPrPrefetch(
  tokenStore: TokenRepository,
  makeClient: (base: string, token: string, lane: "user" | "prefetch") => GithubPort,
  getDiffer: () => Promise<DifferPort>,
  _guidCache: GuidRepository,
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
      `${API_BASE}/${req.owner}/${req.repo}`,
      ctx.refs.headSha,
    );
    const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
    for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
      const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
      const outcomes = await Promise.all(
        chunk.map((f) => getDiff(getDiffer, diffStore, session, client, ctx, req.owner, req.repo, f.path, false)),
      );
      // Only rate limit stops the whole thing; other per-file failures are shown again on manual toggle
      if (outcomes.some((o) => !o.ok && o.error === "rate-limited")) {
        console.debug("prefablens: prefetch aborted", { kind: "rate-limited" });
        return;
      }
    }
  } catch (err) {
    // Prefetch gives up quietly; only the user-action path surfaces error UI
    console.debug("prefablens: prefetch aborted", err);
  }
}
