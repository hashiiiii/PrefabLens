import { parseGuidFromMeta } from "../../domain/diff/meta-guid";
import { ok, type Result } from "../../domain/result";
import type { GithubFailure, GithubPort } from "../port/github";
import type { RepoIndexPort } from "../port/repo-index";

type ClientLike = Pick<GithubPort, "listMetaTree" | "batchBlobTexts">;

const INDEX_MAX_METAS = 50_000; // above this, give up on the index to protect the storage quota
const GRAPHQL_BATCH = 100;

// Whole-repo guid→asset path. Truncated / over cap → null (defer to Code Search).
// blobSha→guid is content-derived (cache forever); after a push only changed .meta are fetched.
export async function syncRepoIndex(
  client: ClientLike,
  store: RepoIndexPort,
  owner: string,
  repo: string,
  repoKey: string,
  ref: string,
): Promise<Result<Record<string, string> | null, GithubFailure>> {
  const existing = await store.loadIndex(repoKey);
  if (existing?.treeSha === ref) return ok(existing.guids);
  const tree = await client.listMetaTree(owner, repo, ref);
  if (!tree.ok) return tree;
  if (tree.value.truncated || tree.value.metas.length > INDEX_MAX_METAS) return ok(null);
  const known = await store.loadGuids(repoKey);
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
  const merged = { ...known, ...fetched };
  const guids: Record<string, string> = {};
  for (const m of tree.value.metas) {
    const guid = merged[m.sha];
    if (guid) guids[guid] = m.path.slice(0, -".meta".length);
  }
  await store.saveIndex(repoKey, { treeSha: ref, guids });
  return ok(guids);
}
