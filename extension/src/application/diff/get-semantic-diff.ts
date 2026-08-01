import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/resolved";
import {
  type GuidResolvedPush,
  type SemanticDiffRequest,
  type SemanticDiffResponse,
  unresolvedRemaining,
} from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DifferPort } from "../port/differ";
import type { GithubPort } from "../port/github";
import type { DiffSession } from "./_diff-session";
import { getContext } from "./_get-context";
import { getDiff } from "./_get-diff";
import { updateRemaining } from "./_resolution";

const API_BASE = __API_BASE__;

export async function getSemanticDiff(
  tokenStore: TokenRepository,
  makeClient: (base: string, token: string, lane: "user" | "prefetch") => GithubPort,
  getDiffer: () => Promise<DifferPort>,
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

  // Return immediately; resolution + source merge continue via push
  const remaining = unresolvedRemaining(withPr);
  if (!remaining.length && !withPr.neededSources?.length) return { ok: true, json: withPr };
  void updateRemaining(
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
