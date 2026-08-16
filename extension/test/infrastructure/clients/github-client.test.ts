import { describe, expect, it } from "vitest";
import { isRateLimited } from "../../../src/application/gateway/github";
import { err, ok } from "../../../src/domain/result";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";
import { must } from "../../../src/internal/must";

const API = "https://api.github.test";

const json = (body: unknown, status = 200, headers?: HeadersInit) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...Object.fromEntries(new Headers(headers)) },
  });

function requestKey(input: RequestInfo | URL, init?: RequestInit): string {
  return `${init?.method ?? "GET"} ${String(input)}`;
}

function unexpectedRequest(input: RequestInfo | URL, init?: RequestInit): never {
  throw new Error(`Unexpected request: ${requestKey(input, init)}`);
}

class VirtualClock {
  now = 0;

  sleep = async (milliseconds: number) => {
    this.now += milliseconds;
  };
}

describe("createGithubGateway", () => {
  it("returns the merge base", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      switch (requestKey(input, init)) {
        case `GET ${API}/repos/o/r/pulls/7`:
          return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
        case `GET ${API}/repos/o/r/compare/base-tip...head-sha`:
          return json({ merge_base_commit: { sha: "merge-base" } });
        default:
          return unexpectedRequest(input, init);
      }
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 7);

    expect(result).toEqual(ok({ baseSha: "merge-base", headSha: "head-sha" }));
  });

  it("sends the required REST headers", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1/files?per_page=100&page=1`) {
        return unexpectedRequest(input, init);
      }
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer tok");
      expect(headers.get("accept")).toBe("application/vnd.github+json");
      expect(headers.get("x-github-api-version")).toBe("2022-11-28");
      return json([]);
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).listPrFiles("o", "r", 1);

    expect(result).toEqual(ok([]));
  });

  it("paginates pull request files after 100 entries", async () => {
    const firstPage = Array.from({ length: 100 }, (_, index) => ({
      filename: `f${index}.cs`,
      status: "modified",
    }));
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      switch (requestKey(input, init)) {
        case `GET ${API}/repos/o/r/pulls/1/files?per_page=100&page=1`:
          return json(firstPage);
        case `GET ${API}/repos/o/r/pulls/1/files?per_page=100&page=2`:
          return json([
            {
              filename: "Assets/Foo.prefab",
              status: "renamed",
              previous_filename: "Assets/Old.prefab",
              sha: "blob-head",
            },
          ]);
        default:
          return unexpectedRequest(input, init);
      }
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).listPrFiles("o", "r", 1);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value).toHaveLength(101);
    expect(result.value[100]).toEqual({
      path: "Assets/Foo.prefab",
      status: "modified",
      previousPath: "Assets/Old.prefab",
      sha: "blob-head",
    });
  });

  it("returns the first commit parent and maps its files", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) === `GET ${API}/repos/o/r/commits/abc1234?per_page=300&page=1`) {
        return json({
          sha: "abc1234full",
          parents: [{ sha: "parent-sha" }, { sha: "merge-second-parent" }],
          files: [{ filename: "Assets/Foo.prefab", status: "modified", sha: "blob-head" }],
        });
      }
      return unexpectedRequest(input, init);
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getCommit("o", "r", "abc1234");

    expect(result).toEqual(
      ok({
        sha: "abc1234full",
        parentSha: "parent-sha",
        files: [{ path: "Assets/Foo.prefab", status: "modified", previousPath: undefined, sha: "blob-head" }],
      }),
    );
  });

  it("stops commit pagination after ten full pages", async () => {
    const accepted = new Set(
      Array.from({ length: 10 }, (_, index) =>
        requestKey(`${API}/repos/o/r/commits/root?per_page=300&page=${index + 1}`),
      ),
    );
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (!accepted.has(requestKey(input, init))) return unexpectedRequest(input, init);
      const page = new URL(String(input)).searchParams.get("page");
      return json({
        sha: "root-full",
        parents: [],
        files: Array.from({ length: 300 }, (_, index) => ({
          filename: `page-${page}-file-${index}.cs`,
          status: "added",
        })),
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getCommit("o", "r", "root");

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.sha).toBe("root-full");
    expect(result.value.parentSha).toBeNull();
    expect(result.value.files).toHaveLength(3_000);
  });

  it("encodes compare refs and maps removed files", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) === `GET ${API}/repos/o/r/compare/feat%2Fx...main`) {
        return json({
          merge_base_commit: { sha: "merge-base" },
          files: [{ filename: "Assets/Foo.prefab", status: "removed", sha: "blob-base" }],
        });
      }
      return unexpectedRequest(input, init);
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).compareRefs("o", "r", "feat/x", "main");

    expect(result).toEqual(
      ok({
        mergeBaseSha: "merge-base",
        files: [{ path: "Assets/Foo.prefab", status: "removed", previousPath: undefined, sha: "blob-base" }],
      }),
    );
  });

  it("requests the SHA media type and trims the response", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/commits/feat%2Fx`) {
        return unexpectedRequest(input, init);
      }
      expect(new Headers(init?.headers).get("accept")).toBe("application/vnd.github.sha");
      return new Response("full-head-sha\n");
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).resolveRefSha("o", "r", "feat/x");

    expect(result).toEqual(ok("full-head-sha"));
  });

  it("requests raw file content with encoded path segments", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/contents/Assets/My%20Prefab%231.prefab?ref=sha1`) {
        return unexpectedRequest(input, init);
      }
      expect(new Headers(init?.headers).get("accept")).toBe("application/vnd.github.raw+json");
      return new Response(new Uint8Array([1, 2, 3]));
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getFileAtRef(
      "o",
      "r",
      "Assets/My Prefab#1.prefab",
      "sha1",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([...must(result.value)]).toEqual([1, 2, 3]);
  });

  it("returns null when file content is absent", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/contents/gone.prefab?ref=sha1`) {
        return unexpectedRequest(input, init);
      }
      return new Response("not found", { status: 404 });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getFileAtRef("o", "r", "gone.prefab", "sha1");

    expect(result).toEqual(ok(null));
  });

  it("requests raw bytes by blob SHA", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/git/blobs/blob1`) {
        return unexpectedRequest(input, init);
      }
      expect(new Headers(init?.headers).get("accept")).toBe("application/vnd.github.raw+json");
      return new Response(new Uint8Array([1, 2, 3]));
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getBlobRaw("o", "r", "blob1");

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([...must(result.value)]).toEqual([1, 2, 3]);
  });

  it("returns the asset path from metadata search", async () => {
    const url = `${API}/search/code?q=${encodeURIComponent('"abc123" repo:o/r extension:meta')}&per_page=1`;
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${url}`) return unexpectedRequest(input, init);
      return json({ items: [{ path: "Assets/Scripts/Player.cs.meta" }] });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).searchMetaByGuid("o", "r", "abc123");

    expect(result).toEqual(ok("Assets/Scripts/Player.cs"));
  });

  it("returns null for empty and non-metadata search results", async () => {
    const emptyUrl = `${API}/search/code?q=${encodeURIComponent('"empty" repo:o/r extension:meta')}&per_page=1`;
    const nonMetaUrl = `${API}/search/code?q=${encodeURIComponent('"odd" repo:o/r extension:meta')}&per_page=1`;
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      switch (requestKey(input, init)) {
        case `GET ${emptyUrl}`:
          return json({ items: [] });
        case `GET ${nonMetaUrl}`:
          return json({ items: [{ path: "README.md" }] });
        default:
          return unexpectedRequest(input, init);
      }
    }) as typeof fetch;
    const client = createGithubGateway(API, "tok", fetchFn);

    expect(await client.searchMetaByGuid("o", "r", "empty")).toEqual(ok(null));
    expect(await client.searchMetaByGuid("o", "r", "odd")).toEqual(ok(null));
  });

  it("keeps the residual metadata search fallback", async () => {
    const unindexedUrl = `${API}/search/code?q=${encodeURIComponent('"unindexed" repo:o/r extension:meta')}&per_page=1`;
    const failedUrl = `${API}/search/code?q=${encodeURIComponent('"failed" repo:o/r extension:meta')}&per_page=1`;
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      switch (requestKey(input, init)) {
        case `GET ${unindexedUrl}`:
          return json({ message: "Validation Failed" }, 422);
        case `GET ${failedUrl}`:
          return json({ message: "Server Error" }, 500);
        default:
          return unexpectedRequest(input, init);
      }
    }) as typeof fetch;
    const client = createGithubGateway(API, "tok", fetchFn);

    expect(await client.searchMetaByGuid("o", "r", "unindexed")).toEqual(ok(null));
    expect(await client.searchMetaByGuid("o", "r", "failed")).toEqual(ok(null));
  });

  it("returns metadata blobs with the truncation state", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/git/trees/H?recursive=1`) {
        return unexpectedRequest(input, init);
      }
      return json({
        truncated: true,
        tree: [
          { path: "Assets/S.cs.meta", type: "blob", sha: "sha1" },
          { path: "Assets/S.cs", type: "blob", sha: "sha2" },
          { path: "Assets/Dir.meta", type: "blob", sha: "sha3" },
          { path: "Assets", type: "tree", sha: "sha4" },
        ],
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).listMetaTree("o", "r", "H");

    expect(result).toEqual(
      ok({
        truncated: true,
        metas: [
          { path: "Assets/S.cs.meta", sha: "sha1" },
          { path: "Assets/Dir.meta", sha: "sha3" },
        ],
      }),
    );
  });

  it("maps every blob path with the truncation state", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/git/trees/merge-base?recursive=1`) {
        return unexpectedRequest(input, init);
      }
      return json({
        truncated: false,
        tree: [
          { path: "Assets/Foo.prefab", type: "blob", sha: "sha1" },
          { path: "Assets/S.cs.meta", type: "blob", sha: "sha2" },
          { path: "Assets", type: "tree", sha: "sha3" },
        ],
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).listBlobShas("o", "r", "merge-base");

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.truncated).toBe(false);
    expect([...result.value.byPath]).toEqual([
      ["Assets/Foo.prefab", "sha1"],
      ["Assets/S.cs.meta", "sha2"],
    ]);
  });

  it("posts a GraphQL query and maps blob text", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `POST ${API}/graphql`) return unexpectedRequest(input, init);
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer tok");
      expect(headers.get("accept")).toBe("application/json");
      expect(headers.get("content-type")).toBe("application/json");
      const body = JSON.parse(String(init?.body)) as { query: string };
      expect(body.query).toContain('b0: object(oid: "sha1")');
      expect(body.query).toContain('b1: object(oid: "sha2")');
      return json({ data: { repository: { b0: { text: "guid: g1\n" }, b1: null } } });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).batchBlobTexts("o", "r", ["sha1", "sha2"]);

    expect(result).toEqual(ok({ sha1: "guid: g1\n", sha2: null }));
  });

  it.each([
    ["429", 429, {}, ""],
    ["retry-after", 403, { "retry-after": "60" }, ""],
    ["zero remaining", 403, { "x-ratelimit-remaining": "0" }, ""],
    ["body advice", 403, { "x-ratelimit-remaining": "4999" }, '{"message":"Secondary rate limit"}'],
  ])("classifies %s REST responses as rate-limited", async (_name, status, headers, body) => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1`) return unexpectedRequest(input, init);
      return new Response(body, { status, headers });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 1);

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(isRateLimited(result.error)).toBe(true);
  });

  it("maps a permission response to auth-failed", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1`) return unexpectedRequest(input, init);
      return new Response('{"message":"Resource not accessible by personal access token"}', {
        status: 403,
        headers: { "x-ratelimit-remaining": "4999" },
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 1);

    expect(result).toEqual(err({ kind: "auth-failed" }));
  });

  it("maps a non-success response to fetch-failed", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1`) return unexpectedRequest(input, init);
      return new Response("server error", { status: 500 });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 1);

    expect(result).toEqual(err({ kind: "fetch-failed" }));
  });

  it("uses Retry-After before the reset time", async () => {
    const reset = Math.floor(Date.now() / 1000) + 30;
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/7`) return unexpectedRequest(input, init);
      return new Response("slow down", {
        status: 403,
        headers: { "retry-after": "12", "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(reset) },
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 7);

    expect(result).toEqual(err({ kind: "rate-limited", retryAfterMs: 12_000 }));
  });

  it("converts the reset time to a relative wait", async () => {
    const reset = Math.floor(Date.now() / 1000) + 30;
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/7`) return unexpectedRequest(input, init);
      return new Response("", {
        status: 403,
        headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(reset) },
      });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 7);

    expect(result.ok).toBe(false);
    if (result.ok || !isRateLimited(result.error)) return;
    expect(result.error.retryAfterMs).toBeGreaterThan(25_000);
    expect(result.error.retryAfterMs).toBeLessThanOrEqual(30_000);
  });

  it("omits advice when a rate-limit response has no advice header", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/7`) return unexpectedRequest(input, init);
      return new Response('{"message":"Secondary rate limit"}', { status: 403 });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).getPrRefs("o", "r", 7);

    expect(result).toEqual(err({ kind: "rate-limited", retryAfterMs: undefined }));
  });

  it("maps GraphQL RATE_LIMITED and keeps header advice", async () => {
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `POST ${API}/graphql`) return unexpectedRequest(input, init);
      return json({ errors: [{ type: "RATE_LIMITED" }] }, 200, { "retry-after": "4" });
    }) as typeof fetch;

    const result = await createGithubGateway(API, "tok", fetchFn).batchBlobTexts("o", "r", ["sha1"]);

    expect(result).toEqual(err({ kind: "rate-limited", retryAfterMs: 4_000 }));
  });
});

describe("createGithubGateway", () => {
  it("returns rate-limited after two queue backoffs", async () => {
    const clock = new VirtualClock();
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1`) return unexpectedRequest(input, init);
      if (![0, 30_000, 60_000].includes(clock.now)) {
        throw new Error(`Unexpected clock state: ${clock.now}`);
      }
      return new Response("limited", { status: 429 });
    }) as typeof fetch;
    const client = createGithubGateway(1, fetchFn, clock.sleep)(API, "tok", "user");

    const result = await client.getPrRefs("o", "r", 1);

    expect(result).toEqual(err({ kind: "rate-limited", retryAfterMs: undefined }));
    expect(clock.now).toBe(60_000);
  });

  it("does not retry an authentication response", async () => {
    const clock = new VirtualClock();
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (requestKey(input, init) !== `GET ${API}/repos/o/r/pulls/1`) return unexpectedRequest(input, init);
      if (clock.now !== 0) throw new Error(`Unexpected clock state: ${clock.now}`);
      return new Response("unauthorized", { status: 401 });
    }) as typeof fetch;
    const client = createGithubGateway(1, fetchFn, clock.sleep)(API, "tok", "user");

    const result = await client.getPrRefs("o", "r", 1);

    expect(result).toEqual(err({ kind: "auth-failed" }));
    expect(clock.now).toBe(0);
  });

  it("shares one queue and runs the user lane first", async () => {
    const activeResponse = Promise.withResolvers<Response>();
    const order: string[] = [];
    const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
      switch (requestKey(input, init)) {
        case `GET ${API}/repos/o/r/commits/active`:
          order.push("active");
          return activeResponse.promise;
        case `GET ${API}/repos/o/r/commits/user`:
          order.push("user");
          return new Response("user-sha");
        case `GET ${API}/repos/o/r/commits/prefetch`:
          order.push("prefetch");
          return new Response("prefetch-sha");
        default:
          return unexpectedRequest(input, init);
      }
    }) as typeof fetch;
    const makeGithubGateway = createGithubGateway(1, fetchFn, async () => {});
    const prefetch = makeGithubGateway(API, "tok", "prefetch");
    const user = makeGithubGateway(API, "tok", "user");
    const active = prefetch.resolveRefSha("o", "r", "active");
    while (order.length === 0) await Promise.resolve();

    const queuedPrefetch = prefetch.resolveRefSha("o", "r", "prefetch");
    const queuedUser = user.resolveRefSha("o", "r", "user");
    activeResponse.resolve(new Response("active-sha"));

    await expect(Promise.all([active, queuedPrefetch, queuedUser])).resolves.toEqual([
      ok("active-sha"),
      ok("prefetch-sha"),
      ok("user-sha"),
    ]);
    expect(order).toEqual(["active", "user", "prefetch"]);
  });
});
