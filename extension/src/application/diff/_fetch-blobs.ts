import { ok, type Result } from "../_result";
import type { GithubFailure, GithubPort } from "../port/github";
import type { DiffContext, DiffSession } from "./_diff-session";

const EMPTY = new Uint8Array(0);

export type BlobClient = Pick<GithubPort, "getBlobRaw" | "getFileAtRef">;

// Prefer blob-sha when known (#110); 404 (force push) falls back to path+ref
export function fetchBlob(
  session: DiffSession,
  client: BlobClient,
  owner: string,
  repo: string,
  path: string,
  sha: string,
  blobSha?: string,
): Promise<Result<Uint8Array | null, GithubFailure>> {
  // blob sha never collides with `${sha}:${path}`
  return session.blobs.get(blobSha ?? `${sha}:${path}`, async () => {
    if (!blobSha) return client.getFileAtRef(owner, repo, path, sha);
    const raw = await client.getBlobRaw(owner, repo, blobSha);
    if (!raw.ok) return raw;
    if (raw.value) return ok(raw.value);
    return client.getFileAtRef(owner, repo, path, sha);
  });
}

// Before/after blobs; status/previousPath follow the files API
export async function fetchPair(
  session: DiffSession,
  client: BlobClient,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
): Promise<Result<[Uint8Array, Uint8Array], GithubFailure>> {
  const file = ctx.files.find((f) => f.path === path);
  const status = file?.status ?? "modified";
  const beforePath = file?.previousPath ?? path;
  // files API sha is head blob, except removed where it is the base blob
  const beforeBlob = status === "removed" ? file?.sha : ctx.baseShas?.get(beforePath);
  const afterBlob = status === "removed" ? undefined : file?.sha;
  const fetchSide = async (p: string, ref: string, blob?: string): Promise<Result<Uint8Array, GithubFailure>> => {
    const bytes = await fetchBlob(session, client, owner, repo, p, ref, blob);
    if (!bytes.ok) return bytes;
    return ok(bytes.value ?? EMPTY);
  };
  if (status === "added") {
    const after = await fetchSide(path, ctx.refs.headSha, afterBlob);
    if (!after.ok) return after;
    return ok([EMPTY, after.value]);
  }
  if (status === "removed") {
    const before = await fetchSide(beforePath, ctx.refs.baseSha, beforeBlob);
    if (!before.ok) return before;
    return ok([before.value, EMPTY]);
  }
  const [before, after] = await Promise.all([
    fetchSide(beforePath, ctx.refs.baseSha, beforeBlob),
    fetchSide(path, ctx.refs.headSha, afterBlob),
  ]);
  if (!before.ok) return before;
  if (!after.ok) return after;
  return ok([before.value, after.value]);
}
