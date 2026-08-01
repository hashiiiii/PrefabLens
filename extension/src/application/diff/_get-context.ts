import type { DiffTarget } from "../../domain/diff/types";
import { targetKey } from "../../domain/diff/types";
import { ok, type Result } from "../../domain/result";
import { type ChangedFile, type GithubFailure, type GithubPort, isRateLimited, type RefPair } from "../port/github";
import type { DiffContext, DiffSession } from "./_diff-session";
import { getBlob } from "./_get-blobs";
import { createGuidIndex } from "./create-guid-index";

// Per-kind: refs + changed-file discovery; everything downstream is target-agnostic
async function loadRefsAndFiles(
  client: GithubPort,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<{ refs: RefPair; files: ChangedFile[] }, GithubFailure>> {
  if (target.kind === "pull") {
    const [refs, files] = await Promise.all([
      client.getPrRefs(owner, repo, target.prNumber),
      client.listPrFiles(owner, repo, target.prNumber),
    ]);
    if (!refs.ok) return refs;
    if (!files.ok) return files;
    return ok({ refs: refs.value, files: files.value });
  }
  if (target.kind === "commit") {
    const commit = await client.getCommit(owner, repo, target.sha);
    if (!commit.ok) return commit;
    // Root commit: before side is never fetched; own sha as baseSha keeps tree lookups harmless
    return ok({
      refs: { baseSha: commit.value.parentSha ?? commit.value.sha, headSha: commit.value.sha },
      files: commit.value.files,
    });
  }
  const [cmp, headSha] = await Promise.all([
    client.compareRefs(owner, repo, target.base, target.head),
    // Cache keys need an immutable sha; compare commits truncate at 250 so last ≠ always head
    client.resolveRefSha(owner, repo, target.head),
  ]);
  if (!cmp.ok) return cmp;
  if (!headSha.ok) return headSha;
  return ok({ refs: { baseSha: cmp.value.mergeBaseSha, headSha: headSha.value }, files: cmp.value.files });
}

export function getContext(
  session: DiffSession,
  client: GithubPort,
  owner: string,
  repo: string,
  target: DiffTarget,
): Promise<Result<DiffContext, GithubFailure>> {
  return session.contexts.get(targetKey(owner, repo, target), async () => {
    const loaded = await loadRefsAndFiles(client, owner, repo, target);
    if (!loaded.ok) return loaded;
    const { refs, files } = loaded.value;
    const bySha = new Map(files.map((f) => [f.path, f.sha]));
    const [guidIndex, tree] = await Promise.all([
      createGuidIndex(files, async (path, side) => {
        // files API sha matches the side createGuidIndex reads (head, or base for removed metas)
        const bytes = await getBlob(
          session,
          client,
          owner,
          repo,
          path,
          side === "base" ? refs.baseSha : refs.headSha,
          bySha.get(path),
        );
        if (!bytes.ok) return bytes;
        return ok(bytes.value ? new TextDecoder().decode(bytes.value) : null);
      }),
      // Only rate limits propagate; anything else → null → contents-api fallback
      client.listBlobShas(owner, repo, refs.baseSha),
    ]);
    if (!guidIndex.ok) return guidIndex;
    let baseShas: Map<string, string> | null = null;
    if (tree.ok) {
      baseShas = tree.value.truncated ? null : tree.value.byPath;
    } else if (isRateLimited(tree.error)) {
      return tree;
    }
    return ok({ refs, files, guidIndex: guidIndex.value, baseShas });
  });
}
