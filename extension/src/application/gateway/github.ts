import type { Result } from "../../domain/result";

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
// sha is the blob at head (at base for removed files) — the files API provides it for every status.
export type ChangedFile = { path: string; status: string; previousPath?: string; sha?: string };
export type RefPair = { baseSha: string; headSha: string };

export type GithubGateway = {
  getPrRefs(owner: string, repo: string, prNumber: number): Promise<Result<RefPair, GithubFailure>>;
  listPrFiles(owner: string, repo: string, prNumber: number): Promise<Result<ChangedFile[], GithubFailure>>;
  getCommit(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ sha: string; parentSha: string | null; files: ChangedFile[] }, GithubFailure>>;
  compareRefs(
    owner: string,
    repo: string,
    base: string,
    head: string,
  ): Promise<Result<{ mergeBaseSha: string; files: ChangedFile[] }, GithubFailure>>;
  resolveRefSha(owner: string, repo: string, ref: string): Promise<Result<string, GithubFailure>>;
  getFileAtRef(
    owner: string,
    repo: string,
    path: string,
    ref: string,
  ): Promise<Result<Uint8Array | null, GithubFailure>>;
  getBlobRaw(owner: string, repo: string, sha: string): Promise<Result<Uint8Array | null, GithubFailure>>;
  listBlobShas(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ truncated: boolean; byPath: Map<string, string> }, GithubFailure>>;
  searchMetaByGuid(owner: string, repo: string, guid: string): Promise<Result<string | null, GithubFailure>>;
  listMetaTree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }, GithubFailure>>;
  batchBlobTexts(
    owner: string,
    repo: string,
    oids: string[],
  ): Promise<Result<Record<string, string | null>, GithubFailure>>;
};
