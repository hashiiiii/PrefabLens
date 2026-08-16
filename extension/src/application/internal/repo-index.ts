import { assetPathFromMeta } from "../../domain/diff/fn/asset-path-from-meta";
import { parseGuidFromMeta } from "../../domain/diff/fn/parse-guid-from-meta";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { ok, type Result } from "../../domain/result";
import type { DiffSession } from "../diff/create-diff-session";
import type { GithubFailure, GithubGateway } from "../gateway/github";
import { isRateLimited } from "../gateway/github";

type GithubMetaTree = Pick<GithubGateway, "listMetaTree" | "batchBlobTexts">;

const INDEX_MAX_METAS = 50_000; // Above this count, the code skips the index to protect the storage quota.
const GRAPHQL_BATCH = 100;

// The whole-repo guid→asset path map. A truncated or over-cap listing returns
// null, and Code Search applies instead. blobSha→guid is content-derived (a
// permanent cache). After a push, only changed .meta files are fetched.
async function updateRepoIndex(
  githubGateway: GithubMetaTree,
  repoIndexRepository: RepoIndexRepository,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Result<Record<string, string> | null, GithubFailure>> {
  const existing = await repoIndexRepository.loadIndex(repoKey);
  if (existing?.treeSha === ref) return ok(existing.guids);
  // The stored sha→guid map is independent of the tree fetch. The two loads run in parallel.
  const [tree, known] = await Promise.all([
    githubGateway.listMetaTree(owner, repo, ref),
    repoIndexRepository.loadGuids(repoKey),
  ]);
  if (!tree.ok) return tree;
  if (tree.value.truncated || tree.value.metas.length > INDEX_MAX_METAS) return ok(null);
  // hasOwn: like the guid cache, avoids false prototype hits
  const missing = tree.value.metas.filter((m) => !Object.hasOwn(known, m.sha));
  const fetched: Record<string, string> = {};
  for (let i = 0; i < missing.length; i += GRAPHQL_BATCH) {
    const chunk = missing.slice(i, i + GRAPHQL_BATCH);
    const texts = await githubGateway.batchBlobTexts(
      owner,
      repo,
      chunk.map((m) => m.sha),
    );
    if (!texts.ok) return texts;
    for (const m of chunk) {
      const text = texts.value[m.sha];
      if (!text) continue; // skip binary / unfetchable
      const guid = parseGuidFromMeta(text);
      if (guid) fetched[m.sha] = guid;
    }
  }
  if (Object.keys(fetched).length) await repoIndexRepository.saveGuids(repoKey, fetched);
  const guids: Record<string, string> = {};
  for (const m of tree.value.metas) {
    // The sha keys are hex, so a plain lookup cannot hit Object.prototype.
    const guid = fetched[m.sha] ?? known[m.sha];
    if (guid) guids[guid] = assetPathFromMeta(m.path);
  }
  await repoIndexRepository.saveIndex(repoKey, { treeSha: ref, guids });
  return ok(guids);
}

// The memoized whole-repo index. Rate-limited repos stay on the fallback for the SW lifetime.
export async function getRepoIndex(
  repoIndexRepository: RepoIndexRepository,
  session: DiffSession,
  githubGateway: GithubMetaTree,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Record<string, string> | null> {
  if (session.indexFallback.has(repoKey)) return null;
  const result = await session.indexes.get(`${repoKey}@${ref}`, () =>
    updateRepoIndex(githubGateway, repoIndexRepository, owner, repo, repoKey, ref),
  );
  if (!result.ok) {
    // Cache already dropped the failure, so the next visit retries
    if (isRateLimited(result.error)) session.indexFallback.add(repoKey);
    return null;
  }
  return result.value;
}
