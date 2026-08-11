import { applyResolved } from "../../domain/diff/fn/apply-resolved";
import { unresolvedRemaining } from "../../domain/diff/fn/unresolved-remaining";
import type { DiffV2 } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { DiffContext, DiffSession } from "../diff/create-diff-session";
import type { DifferGateway } from "../gateway/differ";
import { type GithubGateway, isRateLimited } from "../gateway/github";
import type { ResolutionStatus } from "../gateway/messenger";
import { resolveGuids } from "./guid-resolution";
import { getBlob } from "./raw-diff";
import { mergeSourceRounds } from "./source-rounds";

export async function mergeGithubSources(
  differ: DifferGateway,
  guidCache: GuidRepository,
  session: DiffSession,
  client: Pick<GithubGateway, "searchMetaByGuid" | "getBlobRaw" | "getFileAtRef">,
  owner: string,
  repo: string,
  repoKey: string,
  context: DiffContext,
  before: Uint8Array,
  after: Uint8Array,
  first: DiffV2,
): Promise<{ json: DiffV2; status: ResolutionStatus }> {
  return mergeSourceRounds(
    differ,
    before,
    after,
    first,
    async (source, path) => {
      const sha = source.side === "before" ? context.refs.baseSha : context.refs.headSha;
      // Only the base tree can supply a blob sha for a source outside the changed-file list.
      const blobSha = source.side === "before" ? context.baseShas?.get(path) : undefined;
      const bytes = await getBlob(session, client, owner, repo, path, sha, blobSha);
      if (!bytes.ok) return { abort: isRateLimited(bytes.error) ? "rateLimited" : "failed" };
      if (!bytes.value) return { skip: true };
      return { bytes: bytes.value };
    },
    async (json) => {
      const withIndex = applyResolved(json, context.guidIndex);
      const found = await resolveGuids(
        guidCache,
        session,
        client,
        owner,
        repo,
        repoKey,
        unresolvedRemaining(withIndex),
      );
      return {
        json: { ...withIndex, resolved: { ...withIndex.resolved, ...found.resolved } },
        rateLimited: found.rateLimited,
      };
    },
  );
}
