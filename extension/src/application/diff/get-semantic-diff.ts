import type { TokenRepository } from "../../domain/auth/token-repository";
import type { DiffRepository } from "../../domain/diff/diff-repository";
import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { repoKey } from "../../domain/diff/fn/repo-key";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import type { DifferGateway } from "../gateway/differ";
import type { MakeGithubGateway } from "../gateway/github";
import type { SemanticDiffEvent, SemanticDiffRequest } from "../gateway/messenger";
import { API_BASE } from "../internal/api-base";
import { getContext, getDiff } from "../internal/raw-diff";
import { resolveSemanticDiff } from "../internal/resolve-semantic-diff";
import type { DiffSession } from "./create-diff-session";

export async function* getSemanticDiff(
  tokenRepository: TokenRepository,
  makeGithubGateway: MakeGithubGateway,
  getDiffer: () => Promise<DifferGateway>,
  guidRepository: GuidRepository,
  diffRepository: DiffRepository,
  repoIndexRepository: RepoIndexRepository,
  session: DiffSession,
  req: SemanticDiffRequest,
): AsyncGenerator<SemanticDiffEvent> {
  const accessToken = await tokenRepository.readAccessToken();
  if (!accessToken) {
    yield { type: "response", response: { ok: false, error: "access-token-missing" } };
    return;
  }
  const githubGateway = makeGithubGateway(API_BASE, accessToken, "user");
  const ctxResult = await getContext(session, githubGateway, req.owner, req.repo, req.target);
  if (!ctxResult.ok) {
    yield { type: "response", response: { ok: false, error: ctxResult.error.kind } };
    return;
  }
  const ctx = ctxResult.value;
  const outcome = await getDiff(
    getDiffer,
    diffRepository,
    session,
    githubGateway,
    ctx,
    req.owner,
    req.repo,
    req.path,
    req.force === true,
  );
  if (!outcome.ok) {
    yield { type: "response", response: outcome };
    return;
  }
  const withPr = applyResolved(outcome.json, ctx.guidIndex);

  const remaining = unresolvedRemaining(withPr);
  if (!remaining.length && !withPr.neededSources?.length) {
    yield { type: "response", response: { ok: true, json: withPr } };
    return;
  }

  // The first yield lets the background answer before resolution continues.
  yield { type: "response", response: { ok: true, json: withPr, pending: true } };
  for await (const message of resolveSemanticDiff(
    guidRepository,
    repoIndexRepository,
    getDiffer,
    session,
    githubGateway,
    ctx,
    repoKey(API_BASE, req.owner, req.repo),
    withPr,
    remaining,
    req,
  )) {
    yield { type: "resolution", message };
  }
}
