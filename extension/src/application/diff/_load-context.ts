import type { DiffTarget } from "../../domain/diff/types";
import { targetKey } from "../../domain/diff/types";
import { type ChangedFile, type GithubPort, RateLimitError, type RefPair } from "../port/github";
import type { DiffContext, DiffSession } from "./_diff-session";
import { fetchBlob } from "./_fetch-blobs";
import { buildGuidIndex } from "./build-guid-index";

// Per-kind: refs + changed-file discovery; everything downstream is target-agnostic
async function loadRefsAndFiles(
  client: GithubPort,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<{ refs: RefPair; files: ChangedFile[] }> {
  if (target.kind === "pull") {
    const [refs, files] = await Promise.all([
      client.getPrRefs(owner, repo, target.prNumber),
      client.listPrFiles(owner, repo, target.prNumber),
    ]);
    return { refs, files };
  }
  if (target.kind === "commit") {
    const commit = await client.getCommit(owner, repo, target.sha);
    // Root commit: before side is never fetched; own sha as baseSha keeps tree lookups harmless
    return { refs: { baseSha: commit.parentSha ?? commit.sha, headSha: commit.sha }, files: commit.files };
  }
  const [cmp, headSha] = await Promise.all([
    client.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha; compare commits truncate at 250 so last ≠ always head
    client.resolveRefSha(owner, repo, target.head),
  ]);
  return { refs: { baseSha: cmp.mergeBaseSha, headSha }, files: cmp.files };
}

export function loadContext(
  session: DiffSession,
  client: GithubPort,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<DiffContext> {
  return session.contexts.get(targetKey(owner, repo, target), async () => {
    const { refs, files } = await loadRefsAndFiles(client, owner, repo, target);
    const bySha = new Map(files.map((f) => [f.path, f.sha]));
    const [guidIndex, baseShas] = await Promise.all([
      buildGuidIndex(files, async (path, side) => {
        // files API sha matches the side buildGuidIndex reads (head, or base for removed metas)
        const bytes = await fetchBlob(
          session,
          client,
          owner,
          repo,
          path,
          side === "base" ? refs.baseSha : refs.headSha,
          bySha.get(path),
        );
        return bytes ? new TextDecoder().decode(bytes) : null;
      }),
      // Only rate limits propagate; anything else → null → contents-api fallback
      client.listBlobShas(owner, repo, refs.baseSha).then(
        (tree) => (tree.truncated ? null : tree.byPath),
        (err: unknown) => {
          if (err instanceof RateLimitError) throw err;
          return null;
        },
      ),
    ]);
    return { refs, files, guidIndex, baseShas };
  });
}
