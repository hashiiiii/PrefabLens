export class AuthError extends Error {}
export class RateLimitError extends Error {}
export class ApiError extends Error {
  constructor(readonly status: number) {
    super(`GitHub API error (HTTP ${status})`); // raw ボディは持たない(漏洩防止)
  }
}

export type PrFile = { path: string; status: string; previousPath?: string };
export type PrRefs = { baseSha: string; headSha: string };

export type TokenProvider = { getToken(): Promise<string | undefined> };
export const patTokenProvider: TokenProvider = {
  async getToken() {
    const stored = await chrome.storage.local.get('pat');
    return stored['pat'] as string | undefined;
  },
};

export function apiBase(baseUrl: string | undefined): string {
  if (!baseUrl) return 'https://api.github.com';
  // Options フォームの入力はスキームなし("github.com")のことがある。
  // 素の new URL は throw し、握りつぶされて fetch-failed に化けるため補完する。
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(baseUrl) ? baseUrl : `https://${baseUrl}`;
  const origin = new URL(withScheme).origin;
  return origin === 'https://github.com' ? 'https://api.github.com' : `${origin}/api/v3`;
}

export class GithubClient {
  constructor(
    private readonly base: string,
    private readonly token: string,
    // 素の `fetch` を既定値にすると `this.fetchFn(...)` の this がインスタンスになり
    // Chrome では Illegal invocation で落ちる(Node の fetch は this を無視する)。
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  private async request(path: string, accept: string): Promise<Response> {
    const res = await this.fetchFn(`${this.base}${path}`, {
      headers: {
        accept,
        authorization: `Bearer ${this.token}`,
        'x-github-api-version': '2022-11-28',
      },
    });
    // primary limit は 403 + x-ratelimit-remaining: 0、secondary は 403 + retry-after、新 API は 429
    const rateLimited =
      res.status === 429 ||
      (res.status === 403 && (res.headers.get('x-ratelimit-remaining') === '0' || res.headers.has('retry-after')));
    if (rateLimited) throw new RateLimitError('GitHub rate limit exceeded');
    if (res.status === 401 || res.status === 403) throw new AuthError('GitHub authentication failed');
    return res;
  }

  private async json<T>(path: string): Promise<T> {
    const res = await this.request(path, 'application/vnd.github+json');
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

  /** ref 時点の生バイト列。その側にファイルが無ければ null。 */
  async getFileAtRef(owner: string, repo: string, path: string, ref: string): Promise<Uint8Array | null> {
    const encoded = path.split('/').map(encodeURIComponent).join('/');
    const res = await this.request(
      `/repos/${owner}/${repo}/contents/${encoded}?ref=${ref}`,
      'application/vnd.github.raw+json',
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new ApiError(res.status);
    return new Uint8Array(await res.arrayBuffer());
  }
}
