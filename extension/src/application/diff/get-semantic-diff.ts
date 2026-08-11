import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DifferGateway } from "../gateway/differ";
import type { MakeGithubClient } from "../gateway/github";
import type { GuidResolvedPush, SemanticDiffRequest, SemanticDiffResponse } from "../gateway/messenger";
import { API_BASE } from "../internal/api-base";
import { pushSemanticResolution } from "../internal/push-semantic-resolution";
import { getContext, getDiff } from "../internal/raw-diff";
import type { DiffSession } from "./create-diff-session";

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
  void pushSemanticResolution(
    guidCache,
    repoIndexStore,
    getDiffer,
    session,
    client,
    ctx,
    repoKey(API_BASE, req.owner, req.repo),
    withPr,
    remaining,
    req,
    push,
  );
  return { ok: true, json: withPr, pending: true };
}
