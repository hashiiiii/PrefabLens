import { applyResolved } from "../../domain/diff/resolved";
import {
  type GuidResolvedPush,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  unresolvedRemaining,
} from "../../domain/diff/types";
import { DiffError } from "../port/differ";
import { AuthError, RateLimitError } from "../port/github";
import type { DiffSession } from "./_diff-session";

export type ComputeSemanticDiff = (
  req: SemanticDiffRequest,
  push: (msg: GuidResolvedPush) => void,
) => Promise<SemanticDiffResponse>;

// Two-stage response: immediate raw diff with in-PR names, then resolution +
// source merge continue via push (moved verbatim from the old engine.semanticDiff)
export function createComputeSemanticDiff(session: DiffSession): ComputeSemanticDiff {
  const { deps, apiBase, resolution, loadContext, getDiff } = session;
  return async function computeSemanticDiff(req, push) {
    try {
      const settings = await deps.getSettings();
      if (!settings.accessToken) return { ok: false, error: "access-token-missing" };
      const client = deps.makeClient(apiBase, settings.accessToken, "user");
      const ctx = await loadContext(client, req.owner, req.repo, req.target);
      const outcome = await getDiff(client, ctx, req.owner, req.repo, req.path, req.force === true);
      if (!outcome.ok) return outcome;
      const withPr = applyResolved(outcome.json, ctx.guidIndex);

      // Return immediately; resolution + source merge continue via push
      const remaining = unresolvedRemaining(withPr);
      if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
      void resolution.resolveRemaining(withPr, remaining, client, req, apiBase, ctx, push);
      return { ok: true, json: withPr, pending: true };
    } catch (err) {
      if (err instanceof RateLimitError) return { ok: false, error: "rate-limited" };
      if (err instanceof AuthError) return { ok: false, error: "auth-failed" };
      if (err instanceof DiffError) return { ok: false, error: "diff-failed" };
      return { ok: false, error: "fetch-failed" }; // don't put raw errors in the response
    }
  };
}
