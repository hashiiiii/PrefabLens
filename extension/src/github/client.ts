export class AuthError extends Error {}
export class RateLimitError extends Error {}
export class ApiError extends Error {
  constructor(readonly status: number) {
    super(`GitHub API error (HTTP ${status})`); // does not carry the raw body (leak prevention)
  }
}

// sha is the blob at head (at base for removed files) — the files API provides it for every status.
export type PrFile = { path: string; status: string; previousPath?: string; sha?: string };
export type PrRefs = { baseSha: string; headSha: string };

// GitHub's shared "diff entry" schema: PR files, commit files, and compare files all use it.
type DiffEntry = { filename: string; status: string; previous_filename?: string; sha?: string };
const toPrFile = (f: DiffEntry): PrFile => ({
  path: f.filename,
  status: f.status,
  previousPath: f.previous_filename,
  sha: f.sha,
});

// The REST base is fixed at build time (see build.mjs's esbuild define).
export const API_BASE = __API_BASE__;

/** Derives the GraphQL endpoint from the REST base. */
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
      // primary is 403 + x-ratelimit-remaining: 0, secondary is 403 + retry-after or
      // no header (only the body message), newer API is 429. The body is used only for classification, not retained.
      const body = await res.text().catch(() => "");
      const rateLimited =
        res.status === 429 ||
        res.headers.has("retry-after") ||
        res.headers.get("x-ratelimit-remaining") === "0" ||
        /rate limit|abuse/i.test(body);
      if (rateLimited) throw new RateLimitError("GitHub rate limit exceeded");
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

  // The before side is the merge-base: GitHub's PR diff compares against the merge-base, not the base branch tip.
  async getPrRefs(owner: string, repo: string, prNumber: number): Promise<PrRefs> {
    const pr = await this.json<{ base: { sha: string }; head: { sha: string } }>(
      `/repos/${owner}/${repo}/pulls/${prNumber}`,
    );
    const cmp = await this.json<{ merge_base_commit: { sha: string } }>(
      `/repos/${owner}/${repo}/compare/${pr.base.sha}...${pr.head.sha}`,
    );
    return { baseSha: cmp.merge_base_commit.sha, headSha: pr.head.sha };
  }

  async listPrFiles(owner: string, repo: string, prNumber: number): Promise<PrFile[]> {
    const out: PrFile[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.json<DiffEntry[]>(
        `/repos/${owner}/${repo}/pulls/${prNumber}/files?per_page=100&page=${page}`,
      );
      for (const f of batch) out.push(toPrFile(f));
      if (batch.length < 100) return out;
    }
  }

  /** Commit metadata + changed files vs the first parent (what GitHub's commit page shows).
   *  Files paginate 300 per page up to GitHub's 3,000-file cap; sha in the response is
   *  full-length even when the request ref is abbreviated. */
  async getCommit(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ sha: string; parentSha: string | null; files: PrFile[] }> {
    const files: PrFile[] = [];
    let sha = "";
    let parentSha: string | null = null;
    for (let page = 1; ; page++) {
      const body = await this.json<{ sha: string; parents: Array<{ sha: string }>; files?: DiffEntry[] }>(
        `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}?per_page=300&page=${page}`,
      );
      if (page === 1) {
        sha = body.sha;
        parentSha = body.parents[0]?.sha ?? null;
      }
      const batch = body.files ?? [];
      for (const f of batch) files.push(toPrFile(f));
      if (batch.length < 300) return { sha, parentSha, files };
    }
  }

  /** Three-dot comparison (what GitHub's compare page shows): merge base + changed files.
   *  GitHub returns compare files only on the first page, capped at 300 for the whole
   *  comparison — like the PR 3,000-file cap, unlisted files degrade to the handler's
   *  treat-as-modified / 404→EMPTY path. */
  async compareRefs(
    owner: string,
    repo: string,
    base: string,
    head: string,
  ): Promise<{ mergeBaseSha: string; files: PrFile[] }> {
    const basehead = `${encodeURIComponent(base)}...${encodeURIComponent(head)}`;
    const body = await this.json<{ merge_base_commit: { sha: string }; files?: DiffEntry[] }>(
      `/repos/${owner}/${repo}/compare/${basehead}`,
    );
    return { mergeBaseSha: body.merge_base_commit.sha, files: (body.files ?? []).map(toPrFile) };
  }

  /** Resolves a ref (branch, tag, abbreviated sha) to the full commit sha via the sha media type. */
  async resolveRefSha(owner: string, repo: string, ref: string): Promise<string> {
    const res = await this.request(
      `/repos/${owner}/${repo}/commits/${encodeURIComponent(ref)}`,
      "application/vnd.github.sha",
    );
    if (!res.ok) throw new ApiError(res.status);
    return (await res.text()).trim();
  }

  /** Looks up guid → asset path (with .meta stripped) via Code Search. No hit / not indexed (422) → null.
   *  The index covers only the default branch, authenticated 10 req/min. */
  async searchMetaByGuid(owner: string, repo: string, guid: string): Promise<string | null> {
    const q = encodeURIComponent(`"${guid}" repo:${owner}/${repo} extension:meta`);
    const res = await this.request(`/search/code?q=${q}&per_page=1`, "application/vnd.github+json");
    if (!res.ok) return null;
    const body = (await res.json()) as { items?: Array<{ path?: string }> };
    const path = body.items?.[0]?.path;
    return path?.endsWith(".meta") ? path.slice(0, -".meta".length) : null;
  }

  /** Raw bytes at ref. null if the file is absent on that side.
   *  Path resolution at an arbitrary ref has erratic multi-second TTFB on GitHub's side (#110):
   *  prefer getBlobRaw whenever the blob SHA is known. */
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

  /** Raw blob bytes by SHA — content-addressed, so latency stays flat where contents-by-path stalls.
   *  null on 404 (the SHA can vanish after a force push + gc). */
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

  /** path + blob SHA of every .meta at ref (a commit SHA is allowed). truncated means the listing was cut off past 100k entries. */
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

  /** path → blob SHA of every blob at ref. Feeds base-side getBlobRaw lookups; same truncation rule as listMetaTree. */
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

  /** Batch-fetches blob text via GraphQL (chunking is the caller's job). GraphQL has an independent 5,000 pt/h budget. */
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
    // GraphQL returns errors while still HTTP 200: RATE_LIMITED is caught here
    if (body.errors?.some((e) => e.type === "RATE_LIMITED")) throw new RateLimitError("GitHub rate limit exceeded");
    const blobs = body.data?.repository;
    if (!blobs) throw new ApiError(res.status);
    return Object.fromEntries(oids.map((oid, i) => [oid, blobs[`b${i}`]?.text ?? null]));
  }
}
