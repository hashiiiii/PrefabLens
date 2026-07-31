export type GithubFailure =
  | { kind: "auth-failed" }
  | { kind: "rate-limited"; retryAfterMs?: number }
  | { kind: "fetch-failed" };

export function isRateLimited(e: unknown): e is Extract<GithubFailure, { kind: "rate-limited" }> {
  return typeof e === "object" && e !== null && (e as { kind?: string }).kind === "rate-limited";
}
export function isAuthFailed(e: unknown): e is Extract<GithubFailure, { kind: "auth-failed" }> {
  return typeof e === "object" && e !== null && (e as { kind?: string }).kind === "auth-failed";
}
export function isGithubFailure(e: unknown): e is GithubFailure {
  return (
    isRateLimited(e) ||
    isAuthFailed(e) ||
    (typeof e === "object" && e !== null && (e as { kind?: string }).kind === "fetch-failed")
  );
}

// sha is the blob at head (at base for removed files) — the files API provides it for every status.
export type ChangedFile = { path: string; status: string; previousPath?: string; sha?: string };
export type RefPair = { baseSha: string; headSha: string };

// Method set = today's ClientLike on handler.ts
export type GithubPort = {
  getPrRefs(owner: string, repo: string, prNumber: number): Promise<RefPair>;
  listPrFiles(owner: string, repo: string, prNumber: number): Promise<ChangedFile[]>;
  getCommit(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ sha: string; parentSha: string | null; files: ChangedFile[] }>;
  compareRefs(
    owner: string,
    repo: string,
    base: string,
    head: string,
  ): Promise<{ mergeBaseSha: string; files: ChangedFile[] }>;
  resolveRefSha(owner: string, repo: string, ref: string): Promise<string>;
  getFileAtRef(owner: string, repo: string, path: string, ref: string): Promise<Uint8Array | null>;
  getBlobRaw(owner: string, repo: string, sha: string): Promise<Uint8Array | null>;
  listBlobShas(owner: string, repo: string, ref: string): Promise<{ truncated: boolean; byPath: Map<string, string> }>;
  searchMetaByGuid(owner: string, repo: string, guid: string): Promise<string | null>;
  listMetaTree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }>;
  batchBlobTexts(owner: string, repo: string, oids: string[]): Promise<Record<string, string | null>>;
};
