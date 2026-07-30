export class AuthError extends Error {}
export class RateLimitError extends Error {
  // Backoff from headers; undefined when GitHub gave none
  constructor(
    message: string,
    readonly retryAfterMs?: number,
  ) {
    super(message);
  }
}

// retry-after (seconds) wins; else x-ratelimit-reset (epoch seconds) relative to now.
// Number(null) is 0 and Number("") is NaN, so absent headers fail the > 0 guards.
function adviceMs(headers: Headers): number | undefined {
  const retryAfter = Number(headers.get("retry-after"));
  if (retryAfter > 0) return retryAfter * 1000;
  const reset = Number(headers.get("x-ratelimit-reset"));
  if (reset > 0) return Math.max(0, reset * 1000 - Date.now());
  return undefined;
}
export class ApiError extends Error {
  constructor(readonly status: number) {
    super(`GitHub API error (HTTP ${status})`); // does not carry the raw body (leak prevention)
  }
}

// sha is the blob at head (at base for removed files) — the files API provides it for every status.
export type ChangedFile = { path: string; status: string; previousPath?: string; sha?: string };
export type RefPair = { baseSha: string; headSha: string };

// GitHub's shared "diff entry" schema: PR files, commit files, and compare files all use it.
type DiffEntry = { filename: string; status: string; previous_filename?: string; sha?: string };
const toChangedFile = (f: DiffEntry): ChangedFile => ({
  path: f.filename,
  status: f.status,
  previousPath: f.previous_filename,
  sha: f.sha,
});

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

  private async rawRequest(url: string, init: RequestInit): Promise<Response> {
    const res = await this.fetchFn(url, init);
    if (res.status === 403 || res.status === 429) {
      // 403 + remaining 0 / retry-after, or 429; body classifies only (not retained)
      const body = await res.text().catch(() => "");
      const rateLimited =
        res.status === 429 ||
        res.headers.has("retry-after") ||
        res.headers.get("x-ratelimit-remaining") === "0" ||
        /rate limit|abuse/i.test(body);
      if (rateLimited) throw new RateLimitError("GitHub rate limit exceeded", adviceMs(res.headers));
      throw new AuthError("GitHub authentication failed");
    }
    if (res.status === 401) throw new AuthError("GitHub authentication failed");
    return res;
  }

  private async request(path: string, accept: string): Promise<Response> {
    return this.rawRequest(`${this.base}${path}`, {
      headers: {
        accept,
        authorization: `Bearer ${this.token}`,
        "x-github-api-version": "2022-11-28",
      },
    });
  }

  private async json<T>(path: string): Promise<T> {
    const res = await this.request(path, "application/vnd.github+json");
    if (!res.ok) throw new ApiError(res.status);
    return res.json() as Promise<T>;
  }

  // before = merge-base (GitHub's PR diff), not the base branch tip
  async getPrRefs(owner: string, repo: string, prNumber: number): Promise<RefPair> {
    const pr = await this.json<{ base: { sha: string }; head: { sha: string } }>(
      `/repos/${owner}/${repo}/pulls/${prNumber}`,
    );
    const cmp = await this.compareRefs(owner, repo, pr.base.sha, pr.head.sha);
    return { baseSha: cmp.mergeBaseSha, headSha: pr.head.sha };
  }

  async listPrFiles(owner: string, repo: string, prNumber: number): Promise<ChangedFile[]> {
    const out: ChangedFile[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.json<DiffEntry[]>(
        `/repos/${owner}/${repo}/pulls/${prNumber}/files?per_page=100&page=${page}`,
      );
      for (const f of batch) out.push(toChangedFile(f));
      if (batch.length < 100) return out;
    }
  }

  // Commit vs first parent (GitHub's commit page). Files: 300/page, 3,000-file cap;
  // response sha is full-length even when the request ref is abbreviated.
  async getCommit(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ sha: string; parentSha: string | null; files: ChangedFile[] }> {
    const files: ChangedFile[] = [];
    let sha = "";
    let parentSha: string | null = null;
    // 10×300 bounds the loop even if paging params stop being honored
    for (let page = 1; page <= 10; page++) {
      const body = await this.json<{ sha: string; parents: Array<{ sha: string }>; files?: DiffEntry[] }>(
        `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}?per_page=300&page=${page}`,
      );
      if (page === 1) {
        sha = body.sha;
        parentSha = body.parents[0]?.sha ?? null;
      }
      const batch = body.files ?? [];
      for (const f of batch) files.push(toChangedFile(f));
      if (batch.length < 300) break;
    }
    return { sha, parentSha, files };
  }

  // Three-dot compare (GitHub's compare page): merge base + files.
  // Files only on first page, capped at 300 — unlisted degrade to treat-as-modified / 404→EMPTY.
  async compareRefs(
    owner: string,
    repo: string,
    base: string,
    head: string,
  ): Promise<{ mergeBaseSha: string; files: ChangedFile[] }> {
    const basehead = `${encodeURIComponent(base)}...${encodeURIComponent(head)}`;
    const body = await this.json<{ merge_base_commit: { sha: string }; files?: DiffEntry[] }>(
      `/repos/${owner}/${repo}/compare/${basehead}`,
    );
    return { mergeBaseSha: body.merge_base_commit.sha, files: (body.files ?? []).map(toChangedFile) };
  }

  // branch / tag / abbreviated sha → full commit sha (sha media type)
  async resolveRefSha(owner: string, repo: string, ref: string): Promise<string> {
    const res = await this.request(
      `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}`,
      "application/vnd.github.sha",
    );
    if (!res.ok) throw new ApiError(res.status);
    return (await res.text()).trim();
  }

  // guid → asset path via Code Search (.meta stripped). No hit / not indexed (422) → null.
  // Default branch only; authenticated 10 req/min.
  async searchMetaByGuid(owner: string, repo: string, guid: string): Promise<string | null> {
    const q = encodeURIComponent(`"${guid}" repo:${owner}/${repo} extension:meta`);
    const res = await this.request(`/search/code?q=${q}&per_page=1`, "application/vnd.github+json");
    if (!res.ok) return null;
    const body = (await res.json()) as { items?: Array<{ path?: string }> };
    const path = body.items?.[0]?.path;
    return path?.endsWith(".meta") ? path.slice(0, -".meta".length) : null;
  }

  // Raw bytes at ref; null if absent. Prefer getBlobRaw when sha known (#110 TTFB).
  async getFileAtRef(owner: string, repo: string, path: string, ref: string): Promise<Uint8Array | null> {
    const encoded = path.split("/").map(encodeURIComponent).join("/");
    const res = await this.request(
      `/repos/${owner}/${repo}/contents/${encoded}?ref=${ref}`,
      "application/vnd.github.raw+json",
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new ApiError(res.status);
    return new Uint8Array(await res.arrayBuffer());
  }

  // Content-addressed blob bytes; latency stays flat where contents-by-path stalls.
  // null on 404 (sha can vanish after force push + gc).
  async getBlobRaw(owner: string, repo: string, sha: string): Promise<Uint8Array | null> {
    const res = await this.request(`/repos/${owner}/${repo}/git/blobs/${sha}`, "application/vnd.github.raw+json");
    if (res.status === 404) return null;
    if (!res.ok) throw new ApiError(res.status);
    return new Uint8Array(await res.arrayBuffer());
  }

  private async tree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ truncated: boolean; tree: Array<{ path: string; type: string; sha: string }> }> {
    return this.json(`/repos/${owner}/${repo}/git/trees/${ref}?recursive=1`);
  }

  // Every .meta path + blob sha at ref. truncated → listing cut past 100k entries.
  async listMetaTree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }> {
    const body = await this.tree(owner, repo, ref);
    const metas = body.tree
      .filter((e) => e.type === "blob" && e.path.endsWith(".meta"))
      .map((e) => ({ path: e.path, sha: e.sha }));
    return { truncated: body.truncated, metas };
  }

  // path → blob sha for every blob at ref (feeds base-side getBlobRaw). Same truncation as listMetaTree.
  async listBlobShas(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ truncated: boolean; byPath: Map<string, string> }> {
    const body = await this.tree(owner, repo, ref);
    const byPath = new Map<string, string>();
    for (const e of body.tree) if (e.type === "blob") byPath.set(e.path, e.sha);
    return { truncated: body.truncated, byPath };
  }

  // GraphQL blob text batch (caller chunks). Independent 5,000 pt/h budget.
  async batchBlobTexts(owner: string, repo: string, oids: string[]): Promise<Record<string, string | null>> {
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
    if (!res.ok) throw new ApiError(res.status);
    const body = (await res.json()) as {
      data?: { repository?: Record<string, { text?: string | null } | null> } | null;
      errors?: Array<{ type?: string }>;
    };
    // GraphQL can be HTTP 200 with RATE_LIMITED in errors[]
    if (body.errors?.some((e) => e.type === "RATE_LIMITED"))
      throw new RateLimitError("GitHub rate limit exceeded", adviceMs(res.headers));
    const blobs = body.data?.repository;
    if (!blobs) throw new ApiError(res.status);
    return Object.fromEntries(oids.map((oid, i) => [oid, blobs[`b${i}`]?.text ?? null]));
  }
}
