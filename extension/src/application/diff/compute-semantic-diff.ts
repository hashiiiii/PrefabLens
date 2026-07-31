import { applyResolved } from "../../domain/diff/resolved";
import {
  type GuidResolvedPush,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  unresolvedRemaining,
} from "../../domain/diff/types";
import type { DiffCachePort } from "../port/diff-cache";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { GuidCachePort } from "../port/guid-cache";
import type { RepoIndexPort } from "../port/repo-index";
import type { TokenStorePort } from "../port/token-store";
import type { DiffSession } from "./_diff-session";
import { getDiff } from "./_get-diff";
import { loadContext } from "./_load-context";
import { resolveRemaining } from "./_resolution";

const API_BASE = __API_BASE__;

export async function computeSemanticDiff(
  tokenStore: TokenStorePort,
  makeClient: (base: string, token: string, lane: "user" | "prefetch") => GithubPort,
  getDiffer: () => Promise<DifferPort>,
  guidCache: GuidCachePort,
  diffStore: DiffCachePort,
  repoIndexStore: RepoIndexPort,
  session: DiffSession,
  req: SemanticDiffRequest,
  push: (msg: GuidResolvedPush) => void,
): Promise<SemanticDiffResponse> {
  const accessToken = await tokenStore.readAccessToken();
  if (!accessToken) return { ok: false, error: "access-token-missing" };
  const client = makeClient(API_BASE, accessToken, "user");
  const ctxResult = await loadContext(session, client, req.owner, req.repo, req.target);
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
  void resolveRemaining(
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
