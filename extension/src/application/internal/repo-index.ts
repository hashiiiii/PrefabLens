import { assetPathFromMeta } from "../../domain/diff/fn/asset-path-from-meta";
import { parseGuidFromMeta } from "../../domain/diff/fn/parse-guid-from-meta";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { ok, type Result } from "../../domain/result";
import type { DiffSession } from "../diff/create-diff-session";
import type { GithubFailure, GithubGateway } from "../gateway/github";
import { isRateLimited } from "../gateway/github";

type SearchClient = Pick<GithubGateway, "listMetaTree" | "batchBlobTexts">;

const INDEX_MAX_METAS = 50_000; // above this, give up on the index to protect the storage quota
const GRAPHQL_BATCH = 100;

// Whole-repo guid→asset path. Truncated / over cap → null (defer to Code Search).
// blobSha→guid is content-derived (cache forever); after a push only changed .meta are fetched.
async function updateRepoIndex(
  client: SearchClient,
  store: RepoIndexRepository,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Result<Record<string, string> | null, GithubFailure>> {
  const existing = await store.loadIndex(repoKey);
  if (existing?.treeSha === ref) return ok(existing.guids);
  // The stored sha→guid map is independent of the tree fetch; overlap them
  const [tree, known] = await Promise.all([client.listMetaTree(owner, repo, ref), store.loadGuids(repoKey)]);
  if (!tree.ok) return tree;
  if (tree.value.truncated || tree.value.metas.length > INDEX_MAX_METAS) return ok(null);
  // hasOwn: like the guid cache, avoids false prototype hits
  const missing = tree.value.metas.filter((m) => !Object.hasOwn(known, m.sha));
  const fetched: Record<string, string> = {};
  for (let i = 0; i < missing.length; i += GRAPHQL_BATCH) {
    const chunk = missing.slice(i, i + GRAPHQL_BATCH);
    const texts = await client.batchBlobTexts(
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
  if (Object.keys(fetched).length) await store.saveGuids(repoKey, fetched);
  const guids: Record<string, string> = {};
  for (const m of tree.value.metas) {
    // sha keys are hex, so plain lookup cannot hit Object.prototype
    const guid = fetched[m.sha] ?? known[m.sha];
    if (guid) guids[guid] = assetPathFromMeta(m.path);
  }
  await store.saveIndex(repoKey, { treeSha: ref, guids });
  return ok(guids);
}

// Memoized whole-repo index; rate-limited repos stay on fallback for the SW lifetime
export async function getRepoIndex(
  repoIndexStore: RepoIndexRepository,
  session: DiffSession,
  client: SearchClient,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Record<string, string> | null> {
  if (session.indexFallback.has(repoKey)) return null;
  const result = await session.indexes.get(`${repoKey}@${ref}`, () =>
    updateRepoIndex(client, repoIndexStore, owner, repo, repoKey, ref),
  );
  if (!result.ok) {
    // Cache already dropped the failure, so the next visit retries
    if (isRateLimited(result.error)) session.indexFallback.add(repoKey);
    return null;
  }
  return result.value;
}
