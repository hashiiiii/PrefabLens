import {
  type ChangedFile,
  type GithubFailure,
  isAuthFailed,
  isGithubFailure,
  isRateLimited,
  type RefPair,
} from "../../application/port/github";
import { err, ok, type Result } from "../../domain/result";
import type { Queue } from "./fetch-queue";

export { type ChangedFile, isAuthFailed, isGithubFailure, isRateLimited, type RefPair };

// retry-after (seconds) wins; else x-ratelimit-reset (epoch seconds) relative to now.
// Number(null) is 0 and Number("") is NaN, so absent headers fail the > 0 guards.
function adviceMs(headers: Headers): number | undefined {
  const retryAfter = Number(headers.get("retry-after"));
  if (retryAfter > 0) return retryAfter * 1000;
  const reset = Number(headers.get("x-ratelimit-reset"));
  if (reset > 0) return Math.max(0, reset * 1000 - Date.now());
  return undefined;
}

// Single owner of GitHub's rate-limit shape: 429, or 403 with the telltale
// headers/body (secondary limits sometimes advise only in the body, like octokit).
export async function rateLimitFailure(
  res: Response,
): Promise<Extract<GithubFailure, { kind: "rate-limited" }> | null> {
  if (res.status !== 403 && res.status !== 429) return null;
  const body = await res
    .clone()
    .text()
    .catch(() => "");
  const limited =
    res.status === 429 ||
    res.headers.has("retry-after") ||
    res.headers.get("x-ratelimit-remaining") === "0" ||
    /rate limit|abuse/i.test(body);
  return limited ? { kind: "rate-limited", retryAfterMs: adviceMs(res.headers) } : null;
}

// Queue-aware fetch: rate-limited responses become classified rejections so the
// queue's backoff/retry machinery (fetch-queue.ts) actually sees them.
export function createQueuedFetch(queue: Queue, front: boolean): typeof fetch {
  return (input, init) =>
    queue(
      async () => {
        const res = await fetch(input, init);
        const limited = await rateLimitFailure(res);
        if (limited) throw limited;
        return res;
      },
      { front },
    );
}

// GitHub's shared "diff entry" schema: PR files, commit files, and compare files all use it.
type DiffEntry = { filename: string; status: string; previous_filename?: string; sha?: string };
const toChangedFile = (f: DiffEntry): ChangedFile => ({
  path: f.filename,
  status: f.status,
  previousPath: f.previous_filename,
  sha: f.sha,
});

const FETCH_FAILED = err({ kind: "fetch-failed" as const });

// Fixed at build time (see build.mjs's esbuild define).
export const API_BASE = __API_BASE__;

export function graphqlUrl(restBase: string): string {
  return `${restBase}/graphql`;
}

export class GithubClient {
  constructor(
    private readonly base: string,
    private readonly token: string,
    // Defaulting to bare `fetch` makes `this` in `this.fetchFn(...)` the instance,
    // which fails with Illegal invocation on Chrome (Node's fetch ignores this).
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  private async rawRequest(url: string, init: RequestInit): Promise<Result<Response, GithubFailure>> {
    let res: Response;
    try {
      res = await this.fetchFn(url, init);
    } catch (e) {
      // The queued fetch rejects with the classified failure once its retries are exhausted
      return isRateLimited(e) ? err(e) : FETCH_FAILED;
    }
    if (res.status === 403 || res.status === 429) {
      const limited = await rateLimitFailure(res);
      if (limited) return err(limited);
      return err({ kind: "auth-failed" });
    }
    if (res.status === 401) return err({ kind: "auth-failed" });
    return ok(res);
  }

  private async request(path: string, accept: string): Promise<Result<Response, GithubFailure>> {
    return this.rawRequest(`${this.base}${path}`, {
      headers: {
        accept,
        authorization: `Bearer ${this.token}`,
        "x-github-api-version": "2022-11-28",
      },
    });
  }

  private async json<T>(path: string): Promise<Result<T, GithubFailure>> {
    const res = await this.request(path, "application/vnd.github+json");
    if (!res.ok) return res;
    if (!res.value.ok) return FETCH_FAILED;
    try {
      return ok((await res.value.json()) as T);
    } catch {
      return FETCH_FAILED;
    }
  }

  // before = merge-base (GitHub's PR diff), not the base branch tip
  async getPrRefs(owner: string, repo: string, prNumber: number): Promise<Result<RefPair, GithubFailure>> {
    const pr = await this.json<{ base: { sha: string }; head: { sha: string } }>(
      `/repos/${owner}/${repo}/pulls/${prNumber}`,
    );
    if (!pr.ok) return pr;
    const cmp = await this.compareRefs(owner, repo, pr.value.base.sha, pr.value.head.sha);
    if (!cmp.ok) return cmp;
    return ok({ baseSha: cmp.value.mergeBaseSha, headSha: pr.value.head.sha });
  }

  async listPrFiles(owner: string, repo: string, prNumber: number): Promise<Result<ChangedFile[], GithubFailure>> {
    const out: ChangedFile[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.json<DiffEntry[]>(
        `/repos/${owner}/${repo}/pulls/${prNumber}/files?per_page=100&page=${page}`,
      );
      if (!batch.ok) return batch;
      for (const f of batch.value) out.push(toChangedFile(f));
      if (batch.value.length < 100) return ok(out);
    }
  }

  // Commit vs first parent (GitHub's commit page). Files: 300/page, 3,000-file cap;
  // response sha is full-length even when the request ref is abbreviated.
  async getCommit(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ sha: string; parentSha: string | null; files: ChangedFile[] }, GithubFailure>> {
    const files: ChangedFile[] = [];
    let sha = "";
    let parentSha: string | null = null;
    // 10×300 bounds the loop even if paging params stop being honored
    for (let page = 1; page <= 10; page++) {
      const body = await this.json<{ sha: string; parents: Array<{ sha: string }>; files?: DiffEntry[] }>(
        `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}?per_page=300&page=${page}`,
      );
      if (!body.ok) return body;
      if (page === 1) {
        sha = body.value.sha;
        parentSha = body.value.parents[0]?.sha ?? null;
      }
      const batch = body.value.files ?? [];
      for (const f of batch) files.push(toChangedFile(f));
      if (batch.length < 300) break;
    }
    return ok({ sha, parentSha, files });
  }

  // Three-dot compare (GitHub's compare page): merge base + files.
  // Files only on first page, capped at 300 — unlisted degrade to treat-as-modified / 404→EMPTY.
  async compareRefs(
    owner: string,
    repo: string,
    base: string,
    head: string,
  ): Promise<Result<{ mergeBaseSha: string; files: ChangedFile[] }, GithubFailure>> {
    const basehead = `${encodeURIComponent(base)}...${encodeURIComponent(head)}`;
    const body = await this.json<{ merge_base_commit: { sha: string }; files?: DiffEntry[] }>(
      `/repos/${owner}/${repo}/compare/${basehead}`,
    );
    if (!body.ok) return body;
    return ok({
      mergeBaseSha: body.value.merge_base_commit.sha,
      files: (body.value.files ?? []).map(toChangedFile),
    });
  }

  // branch / tag / abbreviated sha → full commit sha (sha media type)
  async resolveRefSha(owner: string, repo: string, ref: string): Promise<Result<string, GithubFailure>> {
    const res = await this.request(
      `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}`,
      "application/vnd.github.sha",
    );
    if (!res.ok) return res;
    if (!res.value.ok) return FETCH_FAILED;
    try {
      return ok((await res.value.text()).trim());
    } catch {
      return FETCH_FAILED;
    }
  }

  // guid → asset path via Code Search (.meta stripped). No hit / not indexed (422) → null.
  // Default branch only; authenticated 10 req/min.
  async searchMetaByGuid(owner: string, repo: string, guid: string): Promise<Result<string | null, GithubFailure>> {
    const q = encodeURIComponent(`"${guid}" repo:${owner}/${repo} extension:meta`);
    const res = await this.request(`/search/code?q=${q}&per_page=1`, "application/vnd.github+json");
    if (!res.ok) return res;
    if (!res.value.ok) return ok(null);
    try {
      const body = (await res.value.json()) as { items?: Array<{ path?: string }> };
      const path = body.items?.[0]?.path;
      return ok(path?.endsWith(".meta") ? path.slice(0, -".meta".length) : null);
    } catch {
      return FETCH_FAILED;
    }
  }

  // Raw bytes at ref; null if absent. Prefer getBlobRaw when sha known (#110 TTFB).
  async getFileAtRef(
    owner: string,
    repo: string,
    path: string,
    ref: string,
  ): Promise<Result<Uint8Array | null, GithubFailure>> {
    const encoded = path.split("/").map(encodeURIComponent).join("/");
    const res = await this.request(
      `/repos/${owner}/${repo}/contents/${encoded}?ref=${ref}`,
      "application/vnd.github.raw+json",
    );
    if (!res.ok) return res;
    if (res.value.status === 404) return ok(null);
    if (!res.value.ok) return FETCH_FAILED;
    try {
      return ok(new Uint8Array(await res.value.arrayBuffer()));
    } catch {
      return FETCH_FAILED;
    }
  }

  // Content-addressed blob bytes; latency stays flat where contents-by-path stalls.
  // null on 404 (sha can vanish after force push + gc).
  async getBlobRaw(owner: string, repo: string, sha: string): Promise<Result<Uint8Array | null, GithubFailure>> {
    const res = await this.request(`/repos/${owner}/${repo}/git/blobs/${sha}`, "application/vnd.github.raw+json");
    if (!res.ok) return res;
    if (res.value.status === 404) return ok(null);
    if (!res.value.ok) return FETCH_FAILED;
    try {
      return ok(new Uint8Array(await res.value.arrayBuffer()));
    } catch {
      return FETCH_FAILED;
    }
  }

  private async tree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ truncated: boolean; tree: Array<{ path: string; type: string; sha: string }> }, GithubFailure>> {
    return this.json(`/repos/${owner}/${repo}/git/trees/${ref}?recursive=1`);
  }

  // Every .meta path + blob sha at ref. truncated → listing cut past 100k entries.
  async listMetaTree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }, GithubFailure>> {
    const body = await this.tree(owner, repo, ref);
    if (!body.ok) return body;
    const metas = body.value.tree
      .filter((e) => e.type === "blob" && e.path.endsWith(".meta"))
      .map((e) => ({ path: e.path, sha: e.sha }));
    return ok({ truncated: body.value.truncated, metas });
  }

  // path → blob sha for every blob at ref (feeds base-side getBlobRaw). Same truncation as listMetaTree.
  async listBlobShas(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<Result<{ truncated: boolean; byPath: Map<string, string> }, GithubFailure>> {
    const body = await this.tree(owner, repo, ref);
    if (!body.ok) return body;
    const byPath = new Map<string, string>();
    for (const e of body.value.tree) if (e.type === "blob") byPath.set(e.path, e.sha);
    return ok({ truncated: body.value.truncated, byPath });
  }

  // GraphQL blob text batch (caller chunks). Independent 5,000 pt/h budget.
  async batchBlobTexts(
    owner: string,
    repo: string,
    oids: string[],
  ): Promise<Result<Record<string, string | null>, GithubFailure>> {
    const aliases = oids
      .map((oid, i) => `b${i}: object(oid: ${JSON.stringify(oid)}) { ... on Blob { text } }`)
      .join("\n");
    const query = `query { repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(repo)}) {\n${aliases}\n} }`;
    const res = await this.rawRequest(graphqlUrl(this.base), {
      method: "POST",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query }),
    });
    if (!res.ok) return res;
    if (!res.value.ok) return FETCH_FAILED;
    let body: {
      data?: { repository?: Record<string, { text?: string | null } | null> } | null;
      errors?: Array<{ type?: string }>;
    };
    try {
      body = (await res.value.json()) as typeof body;
    } catch {
      return FETCH_FAILED;
    }
    // GraphQL can be HTTP 200 with RATE_LIMITED in errors[]
    if (body.errors?.some((e) => e.type === "RATE_LIMITED"))
      return err({ kind: "rate-limited", retryAfterMs: adviceMs(res.value.headers) });
    const blobs = body.data?.repository;
    if (!blobs) return FETCH_FAILED;
    return ok(Object.fromEntries(oids.map((oid, i) => [oid, blobs[`b${i}`]?.text ?? null])));
  }
}
