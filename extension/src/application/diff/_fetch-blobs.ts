import type { GithubPort } from "../port/github";
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
): Promise<Uint8Array | null> {
  // blob sha never collides with `${sha}:${path}`
  return session.blobs.get(blobSha ?? `${sha}:${path}`, () =>
    blobSha
      ? client.getBlobRaw(owner, repo, blobSha).then((bytes) => bytes ?? client.getFileAtRef(owner, repo, path, sha))
      : client.getFileAtRef(owner, repo, path, sha),
  );
}

// Before/after blobs; status/previousPath follow the files API
export async function fetchPair(
  session: DiffSession,
  client: BlobClient,
  ctx: DiffContext,
  owner: string,
  repo: string,
  path: string,
): Promise<[Uint8Array, Uint8Array]> {
  const file = ctx.files.find((f) => f.path === path);
  const status = file?.status ?? "modified";
  const beforePath = file?.previousPath ?? path;
  // files API sha is head blob, except removed where it is the base blob
  const beforeBlob = status === "removed" ? file?.sha : ctx.baseShas?.get(beforePath);
  const afterBlob = status === "removed" ? undefined : file?.sha;
  const fetchSide = (p: string, sha: string, blobSha?: string): Promise<Uint8Array> =>
    fetchBlob(session, client, owner, repo, p, sha, blobSha).then((bytes) => bytes ?? EMPTY);
  return Promise.all([
    status === "added" ? Promise.resolve(EMPTY) : fetchSide(beforePath, ctx.refs.baseSha, beforeBlob),
    status === "removed" ? Promise.resolve(EMPTY) : fetchSide(path, ctx.refs.headSha, afterBlob),
  ]);
}
