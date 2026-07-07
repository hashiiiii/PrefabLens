export class AuthError extends Error {}
export class RateLimitError extends Error {}
export class ApiError extends Error {
  constructor(readonly status: number) {
    super(`GitHub API error (HTTP ${status})`); // raw ボディは持たない(漏洩防止)
  }
}

export type PrFile = { path: string; status: string; previousPath?: string };
export type PrRefs = { baseSha: string; headSha: string };

// Options フォームの入力はスキームなし("github.com")のことがある。
// 素の new URL は throw し、握りつぶされて fetch-failed に化けるため補完する。
export function originOf(baseUrl: string): string {
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(baseUrl) ? baseUrl : `https://${baseUrl}`;
  return new URL(withScheme).origin;
}

export function apiBase(baseUrl: string | undefined): string {
  if (!baseUrl) return "https://api.github.com";
  const origin = originOf(baseUrl);
  return origin === "https://github.com" ? "https://api.github.com" : `${origin}/api/v3`;
}

/** REST の base から GraphQL エンドポイントを導く。GHES は /api/v3 → /api/graphql。
 *  引数名は apiBase 関数と紛れないよう restBase とする。 */
export function graphqlUrl(restBase: string): string {
  return restBase.endsWith("/api/v3") ? `${restBase.slice(0, -"/api/v3".length)}/api/graphql` : `${restBase}/graphql`;
}

export class GithubClient {
  constructor(
    private readonly base: string,
    private readonly token: string,
    // 素の `fetch` を既定値にすると `this.fetchFn(...)` の this がインスタンスになり
    // Chrome では Illegal invocation で落ちる(Node の fetch は this を無視する)。
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  private async rawRequest(url: string, init: RequestInit): Promise<Response> {
    const res = await this.fetchFn(url, init);
    if (res.status === 403 || res.status === 429) {
      // primary は 403 + x-ratelimit-remaining: 0、secondary は 403 + retry-after または
      // ヘッダなし(ボディの message のみ)、新 API は 429。ボディは分類にだけ使い、保持しない。
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

  // before 側は merge-base: GitHub の PR diff は base ブランチ先端ではなく merge-base 比較。
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
      const batch = await this.json<Array<{ filename: string; status: string; previous_filename?: string }>>(
        `/repos/${owner}/${repo}/pulls/${prNumber}/files?per_page=100&page=${page}`,
      );
      for (const f of batch) out.push({ path: f.filename, status: f.status, previousPath: f.previous_filename });
      if (batch.length < 100) return out;
    }
  }

  /** Code Search で guid → asset path(.meta を剥いだもの)を引く。未ヒット・未インデックス(422)は null。
   *  legacy 構文(extension:meta)= GHES 互換。索引はデフォルトブランチのみ・認証済み 10 req/min。 */
  async searchMetaByGuid(owner: string, repo: string, guid: string): Promise<string | null> {
    const q = encodeURIComponent(`"${guid}" repo:${owner}/${repo} extension:meta`);
    const res = await this.request(`/search/code?q=${q}&per_page=1`, "application/vnd.github+json");
    if (!res.ok) return null;
    const body = (await res.json()) as { items?: Array<{ path?: string }> };
    const path = body.items?.[0]?.path;
    return path?.endsWith(".meta") ? path.slice(0, -".meta".length) : null;
  }

  /** ref 時点の生バイト列。その側にファイルが無ければ null。 */
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

  /** ref(commit SHA 可)時点の全 .meta の path + blob SHA。truncated は 10 万エントリ超の打ち切り。 */
  async listMetaTree(
    owner: string,
    repo: string,
    ref: string,
  ): Promise<{ truncated: boolean; metas: Array<{ path: string; sha: string }> }> {
    const body = await this.json<{ truncated: boolean; tree: Array<{ path: string; type: string; sha: string }> }>(
      `/repos/${owner}/${repo}/git/trees/${ref}?recursive=1`,
    );
    const metas = body.tree
      .filter((e) => e.type === "blob" && e.path.endsWith(".meta"))
      .map((e) => ({ path: e.path, sha: e.sha }));
    return { truncated: body.truncated, metas };
  }

  /** GraphQL で blob text を一括取得(分割は呼び出し側)。GraphQL は 5,000 pt/h の独立枠。 */
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
    // GraphQL は HTTP 200 のまま errors を返す: RATE_LIMITED はここで拾う
    if (body.errors?.some((e) => e.type === "RATE_LIMITED")) throw new RateLimitError("GitHub rate limit exceeded");
    const blobs = body.data?.repository;
    if (!blobs) throw new ApiError(res.status);
    return Object.fromEntries(oids.map((oid, i) => [oid, blobs[`b${i}`]?.text ?? null]));
  }
}
