import { describe, expect, it } from "vitest";
import { isAuthFailed, isRateLimited } from "../../application/gateway/github";
import { err, ok } from "../../domain/result";
import { must } from "../../internal/must";
import { createQueue } from "./fetch-queue-client";
import { createQueuedFetch, GithubClient } from "./github-client";

// fetch fake that returns a fixed path→response table. It also records calls.
// Matching is url.includes(key), so keys must be unique substrings
// (e.g. 'page=1' also matches 'per_page=100' — use '&page=1').
function fakeFetch(routes: Record<string, () => Response>) {
  const calls: Array<{ url: string; headers: Record<string, string>; init: RequestInit }> = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, headers: Object.fromEntries(Object.entries(init?.headers ?? {})), init: init ?? {} });
    for (const [suffix, make] of Object.entries(routes)) {
      if (url.includes(suffix)) return make();
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { fn, calls };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("GithubClient", () => {
  it("default fetchFn survives strict-this runtimes (Chrome Illegal invocation)", async () => {
    // Chrome's fetch throws Illegal invocation when called with a non-global this.
    // Node's fetch ignores this, so this strict stub mimics the real-runtime behavior.
    const realFetch = globalThis.fetch;
    function strictFetch(this: unknown, ..._args: Parameters<typeof fetch>) {
      if (this !== undefined && this !== globalThis) {
        return Promise.reject(new TypeError("Failed to execute 'fetch': Illegal invocation"));
      }
      return Promise.resolve(new Response(new Uint8Array([1])));
    }
    globalThis.fetch = strictFetch as typeof fetch;
    try {
      const client = new GithubClient("https://api.github.com", "tok"); // fetchFn omitted = default
      await expect(client.getFileAtRef("o", "r", "a.prefab", "sha")).resolves.toEqual(ok(new Uint8Array([1])));
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
    expect(refs).toEqual(ok({ baseSha: "merge-base", headSha: "head-sha" }));
    expect(calls[0]?.headers.authorization).toBe("Bearer tok");
  });

  it("listPrFiles paginates past 100 entries", async () => {
    const page1 = Array.from({ length: 100 }, (_, i) => ({ filename: `f${i}.cs`, status: "modified" }));
    const page2 = [
      { filename: "Assets/Foo.prefab", status: "renamed", previous_filename: "Assets/Old.prefab", sha: "blob-head" },
    ];
    const { fn } = fakeFetch({
      "&page=1": () => json(page1),
      "&page=2": () => json(page2),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const files = await client.listPrFiles("o", "r", 1);
    expect(files.ok).toBe(true);
    if (!files.ok) return;
    expect(files.value).toHaveLength(101);
    // sha is the head-side blob (base-side for removed files) — fetchPair fetches by it instead of path+ref
    expect(files.value[100]).toEqual({
      path: "Assets/Foo.prefab",
      status: "renamed",
      previousPath: "Assets/Old.prefab",
      sha: "blob-head",
    });
  });

  it("getBlobRaw requests raw bytes by blob sha", async () => {
    const { fn, calls } = fakeFetch({ "/git/blobs/": () => new Response(new Uint8Array([1, 2, 3])) });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const bytes = await client.getBlobRaw("o", "r", "blob1");
    expect(bytes.ok).toBe(true);
    if (!bytes.ok) return;
    expect([...must(bytes.value)]).toEqual([1, 2, 3]);
    expect(calls[0]?.url).toBe("https://api.github.com/repos/o/r/git/blobs/blob1");
    expect(calls[0]?.headers.accept).toBe("application/vnd.github.raw+json");
  });

  it("getBlobRaw returns null on 404 (sha gone after a force push)", async () => {
    const { fn } = fakeFetch({});
    const client = new GithubClient("https://api.github.com", "tok", fn);
    expect(await client.getBlobRaw("o", "r", "gone")).toEqual(ok(null));
  });

  it("getFileAtRef requests raw content with URL-encoded path segments", async () => {
    const { fn, calls } = fakeFetch({ "/contents/": () => new Response(new Uint8Array([1, 2, 3])) });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const bytes = await client.getFileAtRef("o", "r", "Assets/My Prefab#1.prefab", "sha1");
    expect(bytes.ok).toBe(true);
    if (!bytes.ok) return;
    expect([...must(bytes.value)]).toEqual([1, 2, 3]);
    expect(calls[0]?.url).toContain("/contents/Assets/My%20Prefab%231.prefab?ref=sha1");
    expect(calls[0]?.headers.accept).toBe("application/vnd.github.raw+json");
  });

  it("getFileAtRef returns null on 404 (file absent on that side)", async () => {
    const { fn } = fakeFetch({});
    const client = new GithubClient("https://api.github.com", "tok", fn);
    expect(await client.getFileAtRef("o", "r", "gone.prefab", "sha1")).toEqual(ok(null));
  });

  it("maps 401/403 to auth-failed and other failures to fetch-failed", async () => {
    const auth = new GithubClient("https://api.github.com", "bad", fakeFetch({ "/pulls/1": () => json({}, 401) }).fn);
    await expect(auth.getPrRefs("o", "r", 1)).resolves.toEqual(err({ kind: "auth-failed" }));
    const boom = new GithubClient("https://api.github.com", "tok", fakeFetch({ "/pulls/1": () => json({}, 500) }).fn);
    await expect(boom.getPrRefs("o", "r", 1)).resolves.toEqual(err({ kind: "fetch-failed" }));
  });

  it("searchMetaByGuid queries code search and strips .meta from the hit", async () => {
    const { fn, calls } = fakeFetch({
      "/search/code": () => json({ items: [{ path: "Assets/Scripts/Player.cs.meta" }] }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    expect(await client.searchMetaByGuid("o", "r", "abc123")).toEqual(ok("Assets/Scripts/Player.cs"));
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
    expect(await empty.searchMetaByGuid("o", "r", "g")).toEqual(ok(null));
    const odd = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => json({ items: [{ path: "README.md" }] }) }).fn,
    );
    expect(await odd.searchMetaByGuid("o", "r", "g")).toEqual(ok(null));
    // 422: repository not indexed, etc. Treated as "unresolved" rather than a fetch-failed
    const unindexed = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => json({ message: "Validation Failed" }, 422) }).fn,
    );
    expect(await unindexed.searchMetaByGuid("o", "r", "g")).toEqual(ok(null));
  });

  it("searchMetaByGuid propagates rate limiting", async () => {
    const limited = new GithubClient(
      "https://api.github.com",
      "tok",
      fakeFetch({ "/search/code": () => new Response("", { status: 403, headers: { "retry-after": "60" } }) }).fn,
    );
    await expect(limited.searchMetaByGuid("o", "r", "g")).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
  });

  it("maps rate-limit responses to rate-limited, not auth-failed", async () => {
    // GitHub rate limits: primary is 403 + x-ratelimit-remaining: 0,
    // secondary is 403 + retry-after, and newer APIs use 429.
    // secondary sometimes has no header (only the body message) — octokit also decides by the message.
    const at = (status: number, headers: Record<string, string>, body = "") =>
      new GithubClient(
        "https://api.github.com",
        "tok",
        fakeFetch({ "/pulls/1": () => new Response(body, { status, headers }) }).fn,
      );
    await expect(at(403, { "x-ratelimit-remaining": "0" }).getPrRefs("o", "r", 1)).resolves.toSatisfy(
      (r) => !r.ok && isRateLimited(r.error),
    );
    await expect(at(403, { "retry-after": "60" }).getPrRefs("o", "r", 1)).resolves.toSatisfy(
      (r) => !r.ok && isRateLimited(r.error),
    );
    await expect(at(429, {}).getPrRefs("o", "r", 1)).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
    await expect(
      at(403, { "x-ratelimit-remaining": "4999" }, '{"message":"You have exceeded a secondary rate limit."}').getPrRefs(
        "o",
        "r",
        1,
      ),
    ).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
    // Permission-related 403 (not a rate limit) is still auth-failed
    await expect(
      at(
        403,
        { "x-ratelimit-remaining": "4999" },
        '{"message":"Resource not accessible by personal access token"}',
      ).getPrRefs("o", "r", 1),
    ).resolves.toSatisfy((r) => !r.ok && isAuthFailed(r.error));
  });

  it("getCommit returns the first parent as base and maps files", async () => {
    const { fn } = fakeFetch({
      "/commits/abc1234?": () =>
        json({
          sha: "abc1234full",
          parents: [{ sha: "parent-sha" }, { sha: "merge-second-parent" }],
          files: [{ filename: "Assets/Foo.prefab", status: "modified", sha: "blob-head" }],
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const commit = await client.getCommit("o", "r", "abc1234");
    // GitHub's commit page diffs against the first parent; so do we
    expect(commit).toEqual(
      ok({
        sha: "abc1234full",
        parentSha: "parent-sha",
        files: [{ path: "Assets/Foo.prefab", status: "modified", previousPath: undefined, sha: "blob-head" }],
      }),
    );
  });

  it("getCommit paginates past 300 files and flags a root commit", async () => {
    // The commit API pages files 300 at a time (3,000-file cap on GitHub's side)
    const page1 = Array.from({ length: 300 }, (_, i) => ({ filename: `f${i}.cs`, status: "added" }));
    const { fn } = fakeFetch({
      "&page=1": () => json({ sha: "root-sha", parents: [], files: page1 }),
      "&page=2": () => json({ sha: "root-sha", parents: [], files: [{ filename: "last.cs", status: "added" }] }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const commit = await client.getCommit("o", "r", "root-sha");
    expect(commit.ok).toBe(true);
    if (!commit.ok) return;
    expect(commit.value.parentSha).toBeNull(); // root commit: every file is added, no base side exists
    expect(commit.value.files).toHaveLength(301);
  });

  it("compareRefs returns the merge base and maps files", async () => {
    const { fn, calls } = fakeFetch({
      "/compare/feat%2Fx...main": () =>
        json({
          merge_base_commit: { sha: "merge-base" },
          files: [{ filename: "Assets/Foo.prefab", status: "removed", sha: "blob-base" }],
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const cmp = await client.compareRefs("o", "r", "feat/x", "main");
    expect(cmp).toEqual(
      ok({
        mergeBaseSha: "merge-base",
        files: [{ path: "Assets/Foo.prefab", status: "removed", previousPath: undefined, sha: "blob-base" }],
      }),
    );
    // refs are encoded per side so branch slashes can't be misread as path segments
    expect(calls[0]?.url).toContain("/compare/feat%2Fx...main");
  });

  it("resolveRefSha asks for the sha media type and trims the text body", async () => {
    const { fn, calls } = fakeFetch({ "/commits/main": () => new Response("full-head-sha\n") });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    await expect(client.resolveRefSha("o", "r", "main")).resolves.toEqual(ok("full-head-sha"));
    expect(calls[0]?.headers.accept).toBe("application/vnd.github.sha");
  });

  it("carries retry-after advice on a secondary rate limit", async () => {
    const { fn } = fakeFetch({
      "/pulls/7": () => new Response("slow down", { status: 403, headers: { "retry-after": "12" } }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const result = await client.getPrRefs("o", "r", 7);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
    if (!isRateLimited(result.error)) return;
    // retry-after is seconds; the queue consumes milliseconds
    expect(result.error.retryAfterMs).toBe(12_000);
  });

  it("derives advice from x-ratelimit-reset when retry-after is absent", async () => {
    const reset = Math.floor(Date.now() / 1000) + 30;
    const { fn } = fakeFetch({
      "/pulls/7": () =>
        new Response("", {
          status: 403,
          headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(reset) },
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const result = await client.getPrRefs("o", "r", 7);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
    if (!isRateLimited(result.error)) return;
    // reset is an absolute epoch: allow scheduling slack around the 30s target
    expect(result.error.retryAfterMs).toBeGreaterThan(25_000);
    expect(result.error.retryAfterMs).toBeLessThanOrEqual(30_000);
  });

  it("leaves retryAfterMs undefined when no header advises a wait", async () => {
    const { fn } = fakeFetch({
      "/pulls/7": () => new Response('{"message":"You have exceeded a secondary rate limit."}', { status: 403 }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const result = await client.getPrRefs("o", "r", 7);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
    if (!isRateLimited(result.error)) return;
    expect(result.error.retryAfterMs).toBeUndefined();
  });

  it("attaches advice to graphql RATE_LIMITED errors", async () => {
    const reset = Math.floor(Date.now() / 1000) + 30;
    const { fn } = fakeFetch({
      "/graphql": () =>
        new Response(JSON.stringify({ errors: [{ type: "RATE_LIMITED" }] }), {
          status: 200,
          headers: { "content-type": "application/json", "x-ratelimit-reset": String(reset) },
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const result = await client.batchBlobTexts("o", "r", ["oid1"]);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
    if (!isRateLimited(result.error)) return;
    expect(result.error.retryAfterMs).toBeGreaterThan(0);
  });
});

describe("createQueuedFetch", () => {
  // The production regression that this suite pins: bare fetch resolved on 429/403,
  // so the queue's rate-limit backoff never saw a rejection and never ran. The wrapper
  // converts rate-limited responses into classified rejections that the queue retries.
  const swapFetch = async (impl: typeof fetch, run: () => Promise<void>) => {
    const realFetch = globalThis.fetch;
    globalThis.fetch = impl;
    try {
      await run();
    } finally {
      globalThis.fetch = realFetch;
    }
  };

  it("retries a rate-limited response through the queue", async () => {
    const queue = createQueue(1, async () => {}); // instant sleep: the backoff fires immediately
    let calls = 0;
    await swapFetch(
      (async () => {
        calls++;
        return calls === 1 ? new Response("", { status: 429 }) : new Response("ok", { status: 200 });
      }) as typeof fetch,
      async () => {
        const res = await createQueuedFetch(queue, true)("https://api.github.com/x", {});
        expect(res.status).toBe(200);
        expect(calls).toBe(2);
      },
    );
  });

  it("maps exhausted retries to a rate-limited result", async () => {
    const queue = createQueue(1, async () => {});
    let calls = 0;
    await swapFetch(
      (async () => {
        calls++;
        return new Response("", { status: 429 });
      }) as typeof fetch,
      async () => {
        const client = new GithubClient("https://api.github.com", "tok", createQueuedFetch(queue, true));
        await expect(client.getPrRefs("o", "r", 1)).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
        expect(calls).toBe(3); // initial attempt + MAX_RATE_LIMIT_RETRIES
      },
    );
  });

  it("passes non-rate-limited responses through without retry", async () => {
    const queue = createQueue(1, async () => {});
    let calls = 0;
    await swapFetch(
      (async () => {
        calls++;
        return new Response("", { status: 401 });
      }) as typeof fetch,
      async () => {
        const client = new GithubClient("https://api.github.com", "tok", createQueuedFetch(queue, true));
        await expect(client.getPrRefs("o", "r", 1)).resolves.toEqual(err({ kind: "auth-failed" }));
        expect(calls).toBe(1);
      },
    );
  });
});

describe("listMetaTree", () => {
  it("returns only .meta blobs with the truncated flag", async () => {
    const { fn, calls } = fakeFetch({
      "/git/trees/H": () =>
        json({
          truncated: false,
          tree: [
            { path: "Assets/S.cs.meta", type: "blob", sha: "sha1" },
            { path: "Assets/S.cs", type: "blob", sha: "sha2" }, // non-.meta is excluded
            { path: "Assets/Dir.meta", type: "blob", sha: "sha3" },
            { path: "Assets", type: "tree", sha: "sha4" }, // tree nodes are excluded
          ],
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const res = await client.listMetaTree("o", "r", "H");
    expect(calls[0]?.url).toBe("https://api.github.com/repos/o/r/git/trees/H?recursive=1");
    expect(res).toEqual(
      ok({
        truncated: false,
        metas: [
          { path: "Assets/S.cs.meta", sha: "sha1" },
          { path: "Assets/Dir.meta", sha: "sha3" },
        ],
      }),
    );
  });
});

describe("listBlobShas", () => {
  it("maps every blob path to its sha with the truncated flag", async () => {
    const { fn, calls } = fakeFetch({
      "/git/trees/merge-base": () =>
        json({
          truncated: false,
          tree: [
            { path: "Assets/Foo.prefab", type: "blob", sha: "sha1" },
            { path: "Assets/S.cs.meta", type: "blob", sha: "sha2" },
            { path: "Assets", type: "tree", sha: "sha3" }, // tree nodes are excluded
          ],
        }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const res = await client.listBlobShas("o", "r", "merge-base");
    expect(calls[0]?.url).toBe("https://api.github.com/repos/o/r/git/trees/merge-base?recursive=1");
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.value.truncated).toBe(false);
    expect(res.value.byPath.get("Assets/Foo.prefab")).toBe("sha1");
    expect(res.value.byPath.get("Assets/S.cs.meta")).toBe("sha2");
    expect(res.value.byPath.has("Assets")).toBe(false);
  });
});

describe("batchBlobTexts", () => {
  it("posts an aliased graphql query and maps oids to texts", async () => {
    const { fn, calls } = fakeFetch({
      "/graphql": () => json({ data: { repository: { b0: { text: "guid: g1\n" }, b1: null } } }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    const res = await client.batchBlobTexts("o", "r", ["sha1", "sha2"]);
    expect(calls[0]?.url).toBe("https://api.github.com/graphql");
    const init = must(calls[0]).init;
    expect(init.method).toBe("POST");
    const body = JSON.parse(init.body as string) as { query: string };
    expect(body.query).toContain('b0: object(oid: "sha1")');
    expect(body.query).toContain('b1: object(oid: "sha2")');
    expect(res).toEqual(ok({ sha1: "guid: g1\n", sha2: null })); // an unfetchable blob is null
  });

  it("maps graphql RATE_LIMITED errors to rate-limited", async () => {
    // GraphQL can return an errors array with HTTP 200: missing this silently empties the index
    const { fn } = fakeFetch({ "/graphql": () => json({ errors: [{ type: "RATE_LIMITED" }] }) });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    await expect(client.batchBlobTexts("o", "r", ["sha1"])).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
  });

  it("maps http 403 with retry-after to rate-limited (shared classification)", async () => {
    const { fn } = fakeFetch({
      "/graphql": () => new Response("slow down", { status: 403, headers: { "retry-after": "60" } }),
    });
    const client = new GithubClient("https://api.github.com", "tok", fn);
    await expect(client.batchBlobTexts("o", "r", ["sha1"])).resolves.toSatisfy((r) => !r.ok && isRateLimited(r.error));
  });
});
