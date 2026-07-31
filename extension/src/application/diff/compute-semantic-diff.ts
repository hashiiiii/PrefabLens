import { applyResolved } from "../../domain/diff/resolved";
import {
  type GuidResolvedPush,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  unresolvedRemaining,
} from "../../domain/diff/types";
import type { DiffCachePort } from "../port/diff-cache";
import { DiffError, type DifferPort } from "../port/differ";
import { AuthError, type GithubPort, RateLimitError } from "../port/github";
import type { GuidCachePort } from "../port/guid-cache";
import type { RepoIndexPort } from "../port/repo-index";
import type { DiffSession } from "./_diff-session";
import { getDiff } from "./_get-diff";
import { loadContext } from "./_load-context";
import { resolveRemaining } from "./_resolution";

export type DiffDeps = {
  getSettings(): Promise<{ accessToken?: string }>;
  makeClient(base: string, token: string, lane: "user" | "prefetch"): GithubPort;
  getDiffer(): Promise<DifferPort>;
  guidCache: GuidCachePort;
  diffStore: DiffCachePort;
  repoIndexStore: RepoIndexPort;
};

const API_BASE = __API_BASE__;

export async function computeSemanticDiff(
  deps: DiffDeps,
  session: DiffSession,
  req: SemanticDiffRequest,
  push: (msg: GuidResolvedPush) => void,
): Promise<SemanticDiffResponse> {
  try {
    const settings = await deps.getSettings();
    if (!settings.accessToken) return { ok: false, error: "access-token-missing" };
    const client = deps.makeClient(API_BASE, settings.accessToken, "user");
    const ctx = await loadContext(session, client, req.owner, req.repo, req.target);
    const outcome = await getDiff(deps, session, client, ctx, req.owner, req.repo, req.path, req.force === true);
    if (!outcome.ok) return outcome;
    const withPr = applyResolved(outcome.json, ctx.guidIndex);

    // Return immediately; resolution + source merge continue via push
    const remaining = unresolvedRemaining(withPr);
    if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
    void resolveRemaining(deps, session, withPr, remaining, client, req, API_BASE, ctx, push);
    return { ok: true, json: withPr, pending: true };
  } catch (err) {
    if (err instanceof RateLimitError) return { ok: false, error: "rate-limited" };
    if (err instanceof AuthError) return { ok: false, error: "auth-failed" };
    if (err instanceof DiffError) return { ok: false, error: "diff-failed" };
    return { ok: false, error: "fetch-failed" }; // don't put raw errors in the response
  }
}
