import type { PrefetchRequest } from "../../domain/diff/types";
import { isUnityPath } from "../../domain/unity";
import { RateLimitError } from "../port/github";
import type { DiffSession } from "./_diff-session";

const PREFETCH_MAX = 100; // bounds API usage per PR
const PREFETCH_CONCURRENCY = 4;

export type PrefetchPr = (req: PrefetchRequest) => Promise<void>;

// Raw diff only — leave Code Search / mergeSources to serve time (10 req/min)
export function createPrefetchPr(session: DiffSession): PrefetchPr {
  const { deps, apiBase, resolution, loadContext, getDiff } = session;

  return async function prefetchPr(req: PrefetchRequest): Promise<void> {
    try {
      const settings = await deps.getSettings();
      if (!settings.accessToken) return;
      const client = deps.makeClient(apiBase, settings.accessToken, "prefetch");
      const ctx = await loadContext(client, req.owner, req.repo, { kind: "pull", prNumber: req.prNumber });
      // Index sync independent of raw-diff prefetch (speeds 3-stage resolution at serve time)
      void resolution.getRepoIndex(
        client,
        req.owner,
        req.repo,
        `${apiBase}/${req.owner}/${req.repo}`,
        ctx.refs.headSha,
      );
      const unity = ctx.files.filter((f) => isUnityPath(f.path)).slice(0, PREFETCH_MAX);
      for (let i = 0; i < unity.length; i += PREFETCH_CONCURRENCY) {
        const chunk = unity.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map((f) =>
            getDiff(client, ctx, req.owner, req.repo, f.path, false).catch((err) => {
              if (err instanceof RateLimitError) throw err; // only rate limit stops the whole thing
              // Swallow per-file failures: shown again on manual toggle
            }),
          ),
        );
      }
    } catch (err) {
      // Prefetch gives up quietly; only the user-action path surfaces error UI
      console.debug("prefablens: prefetch aborted", err);
    }
  };
}
