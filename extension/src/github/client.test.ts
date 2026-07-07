import { describe, expect, it, vi } from "vitest";
import { ApiError, AuthError, apiBase, GithubClient, graphqlUrl, RateLimitError } from "./client";

// パス→レスポンスの固定表を返す fetch フェイク。呼び出しも記録する。
// 照合は url.includes(key) なのでキーは一意な部分文字列にすること
// (例: 'page=1' は 'per_page=100' にもマッチしてしまう — '&page=1' を使う)。
function fakeFetch(routes: Record<string, () => Response>) {
  const calls: Array<{ url: string; headers: Record<string, string> }> = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, headers: Object.fromEntries(Object.entries(init?.headers ?? {})) });
    for (const [suffix, make] of Object.entries(routes)) {
      if (url.includes(suffix)) return make();
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { fn, calls };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("apiBase", () => {
  it("defaults to api.github.com", () => {
    expect(apiBase(undefined)).toBe("https://api.github.com");
    expect(apiBase("https://github.com")).toBe("https://api.github.com");
  });
  it("maps GHES origins to <origin>/api/v3", () => {
    expect(apiBase("https://ghe.example.com")).toBe("https://ghe.example.com/api/v3");
  });
  it("tolerates scheme-less and trailing-slash input from the options form", () => {
    // "github.com" と入力すると new URL が throw し fetch-failed に化けていた実障害の回帰テスト
    expect(apiBase("github.com")).toBe("https://api.github.com");
    expect(apiBase("github.com/")).toBe("https://api.github.com");
    expect(apiBase("https://github.com/")).toBe("https://api.github.com");
    expect(apiBase("ghe.example.com")).toBe("https://ghe.example.com/api/v3");
  });
});

describe("GithubClient", () => {
  it("default fetchFn survives strict-this runtimes (Chrome Illegal invocation)", async () => {
    // Chrome の fetch はグローバル以外の this で呼ばれると Illegal invocation を投げる。
    // Node の fetch は this を無視するため、この strict スタブで実機挙動を模す。
    const realFetch = globalThis.fetch;
    function strictFetch(this: unknown, ..._args: Parameters<typeof fetch>) {
      if (this !== undefined && this !== globalThis) {
        return Promise.reject(new TypeError("Failed to execute 'fetch': Illegal invocation"));
      }
      return Promise.resolve(new Response(new Uint8Array([1])));
    }
    globalThis.fetch = strictFetch as typeof fetch;
    try {
      const client = new GithubClient("https://api.github.com", "tok"); // fetchFn 省略 = 既定値
      await expect(client.getFileAtRef("o", "r", "a.prefab", "sha")).resolves.not.toBeNull();
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("getPrRefs returns the merge base as baseSha", async () => {
    const { fn, calls } = fakeFetch({
      "/compare/base-tip...head-sha": () => json({ merge_base_commit: { sha: "merge-base" } }),
      "/pulls/7": () => json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const refs = await client.getPrRefs("o", "r", 7);
    expect(refs).toEqual({ baseSha: "merge-base", headSha: "head-sha" });
    expect(calls[0]?.headers.authorization).toBe("Bearer tok");
  });

  it("listPrFiles paginates past 100 entries", async () => {
    const page1 = Array.from({ length: 100 }, (_, i) => ({ filename: `f${i}.cs`, status: "modified" }));
    const page2 = [{ filename: "Assets/Foo.prefab", status: "renamed", previous_filename: "Assets/Old.prefab" }];
    const { fn } = fakeFetch({
      "&page=1": () => json(page1),
      "&page=2": () => json(page2),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const files = await client.listPrFiles("o", "r", 1);
    expect(files).toHaveLength(101);
    expect(files[100]).toEqual({ path: "Assets/Foo.prefab", status: "renamed", previousPath: "Assets/Old.prefab" });
  });

  it("getFileAtRef requests raw content with URL-encoded path segments", async () => {
    const { fn, calls } = fakeFetch({ "/contents/": () => new Response(new Uint8Array([1, 2, 3])) });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const bytes = await client.getFileAtRef("o", "r", "Assets/My Prefab#1.prefab", "sha1");
    expect([...bytes!]).toEqual([1, 2, 3]);
    expect(calls[0]?.url).toContain("/contents/Assets/My%20Prefab%231.prefab?ref=sha1");
    expect(calls[0]?.headers.accept).toBe("application/vnd.github.raw+json");
  });

  it("getFileAtRef returns null on 404 (file absent on that side)", async () => {
    const { fn } = fakeFetch({});
    const client = new GithubClient("https://api.github.com", "tok", fn);
    expect(await client.getFileAtRef("o", "r", "gone.prefab", "sha1")).toBeNull();
  });

  it("maps 401/403 to AuthError and other failures to ApiError", async () => {
    const auth = new GithubClient("https://api.github.com", "bad", fakeFetch({ "/pulls/1": () => json({}, 401) }).fn);
    await expect(auth.getPrRefs("o", "r", 1)).rejects.toBeInstanceOf(AuthError);
    const boom = new GithubClient("https://api.github.com", "tok", fakeFetch({ "/pulls/1": () => json({}, 500) }).fn);
    await expect(boom.getPrRefs("o", "r", 1)).rejects.toBeInstanceOf(ApiError);
  });

  it("searchMetaByGuid queries code search and strips .meta from the hit", async () => {
    const { fn, calls } = fakeFetch({
      "/search/code": () => json({ items: [{ path: "Assets/Scripts/Player.cs.meta" }] }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    expect(await client.searchMetaByGuid("o", "r", "abc123")).toBe("Assets/Scripts/Player.cs");
    expect(calls[0]?.url).toContain(
      `/search/code?q=${encodeURIComponent('"abc123" repo:o/r extension:meta')}&per_page=1`,
    );
  });

  it("searchMetaByGuid returns null on no hits, non-meta hits, and 422", async () => {
    const empty = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => json({ items: [] }) }).fn,
    );
    expect(await empty.searchMetaByGuid("o", "r", "g")).toBeNull();
    const odd = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => json({ items: [{ path: "README.md" }] }) }).fn,
    );
    expect(await odd.searchMetaByGuid("o", "r", "g")).toBeNull();
    // 422: リポジトリ未インデックス等。ApiError ではなく「未解決」として扱う
    const unindexed = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => json({ message: "Validation Failed" }, 422) }).fn,
    );
    expect(await unindexed.searchMetaByGuid("o", "r", "g")).toBeNull();
  });

  it("searchMetaByGuid propagates rate limiting", async () => {
    const limited = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => new Response("", { status: 403, headers: { "retry-after": "60" } }) }).fn,
    );
    await expect(limited.searchMetaByGuid("o", "r", "g")).rejects.toBeInstanceOf(RateLimitError);
  });

  it("maps rate-limit responses to RateLimitError, not AuthError", async () => {
    // GitHub の rate limit: primary は 403 + x-ratelimit-remaining: 0、
    // secondary は 403 + retry-after、新しめの API は 429。
    // secondary はヘッダなし(ボディの message のみ)のこともある — octokit も message で判定している。
    const at = (status: number, headers: Record<string, string>, body = "") =>
      new GithubClient(
        "https://api.github.com",
        "tok",
        fakeFetch({ "/pulls/1": () => new Response(body, { status, headers }) }).fn,
      );
    await expect(at(403, { "x-ratelimit-remaining": "0" }).getPrRefs("o", "r", 1)).rejects.toBeInstanceOf(
      RateLimitError,
    );
    await expect(at(403, { "retry-after": "60" }).getPrRefs("o", "r", 1)).rejects.toBeInstanceOf(RateLimitError);
    await expect(at(429, {}).getPrRefs("o", "r", 1)).rejects.toBeInstanceOf(RateLimitError);
    await expect(
      at(403, { "x-ratelimit-remaining": "4999" }, '{"message":"You have exceeded a secondary rate limit."}').getPrRefs(
        "o",
        "r",
        1,
      ),
    ).rejects.toBeInstanceOf(RateLimitError);
    // 権限系 403(rate limit ではない)は引き続き AuthError
    await expect(
      at(
        403,
        { "x-ratelimit-remaining": "4999" },
        '{"message":"Resource not accessible by personal access token"}',
      ).getPrRefs("o", "r", 1),
    ).rejects.toBeInstanceOf(AuthError);
  });
});

describe("graphqlUrl", () => {
  it("maps github.com and GHES api bases to their graphql endpoints", () => {
    expect(graphqlUrl("https://api.github.com")).toBe("https://api.github.com/graphql");
    expect(graphqlUrl("https://ghes.example.com/api/v3")).toBe("https://ghes.example.com/api/graphql");
  });
});

describe("listMetaTree", () => {
  it("returns only .meta blobs with the truncated flag", async () => {
    const fetchFn = vi.fn(
      async (..._args: Parameters<typeof fetch>) =>
        new Response(
          JSON.stringify({
            truncated: false,
            tree: [
              { path: "Assets/S.cs.meta", type: "blob", sha: "sha1" },
              { path: "Assets/S.cs", type: "blob", sha: "sha2" }, // .meta 以外は除外
              { path: "Assets/Dir.meta", type: "blob", sha: "sha3" },
              { path: "Assets", type: "tree", sha: "sha4" }, // tree ノードは除外
            ],
          }),
          { status: 200 },
        ),
    );
    const client = new GithubClient("https://api.github.com", "tok", fetchFn);
    const res = await client.listMetaTree("o", "r", "H");
    expect(fetchFn.mock.calls[0]?.[0]).toBe("https://api.github.com/repos/o/r/git/trees/H?recursive=1");
    expect(res).toEqual({
      truncated: false,
      metas: [
        { path: "Assets/S.cs.meta", sha: "sha1" },
        { path: "Assets/Dir.meta", sha: "sha3" },
      ],
    });
  });
});

describe("batchBlobTexts", () => {
  it("posts an aliased graphql query and maps oids to texts", async () => {
    const fetchFn = vi.fn(
      async (..._args: Parameters<typeof fetch>) =>
        new Response(JSON.stringify({ data: { repository: { b0: { text: "guid: g1\n" }, b1: null } } }), {
          status: 200,
        }),
    );
    const client = new GithubClient("https://ghes.example.com/api/v3", "tok", fetchFn);
    const res = await client.batchBlobTexts("o", "r", ["sha1", "sha2"]);
    expect(fetchFn.mock.calls[0]?.[0]).toBe("https://ghes.example.com/api/graphql"); // GHES は /api/graphql
    const init = fetchFn.mock.calls[0]?.[1] as RequestInit;
    expect(init.method).toBe("POST");
    const body = JSON.parse(init.body as string) as { query: string };
    expect(body.query).toContain('b0: object(oid: "sha1")');
    expect(body.query).toContain('b1: object(oid: "sha2")');
    expect(res).toEqual({ sha1: "guid: g1\n", sha2: null }); // 取得不可の blob は null
  });

  it("maps graphql RATE_LIMITED errors to RateLimitError", async () => {
    // GraphQL は HTTP 200 で errors 配列を返すことがある: ここを見逃すと索引が黙って空になる
    const fetchFn = vi.fn(
      async () => new Response(JSON.stringify({ errors: [{ type: "RATE_LIMITED" }] }), { status: 200 }),
    );
    const client = new GithubClient("https://api.github.com", "tok", fetchFn);
    await expect(client.batchBlobTexts("o", "r", ["sha1"])).rejects.toBeInstanceOf(RateLimitError);
  });

  it("maps http 403 with retry-after to RateLimitError (shared classification)", async () => {
    const fetchFn = vi.fn(async () => new Response("slow down", { status: 403, headers: { "retry-after": "60" } }));
    const client = new GithubClient("https://api.github.com", "tok", fetchFn);
    await expect(client.batchBlobTexts("o", "r", ["sha1"])).rejects.toBeInstanceOf(RateLimitError);
  });
});
