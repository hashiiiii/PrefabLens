/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import { resolveSemanticDiff } from "../../../src/application/internal/resolve-semantic-diff";
import { type DiffV2, emptyDiff } from "../../../src/domain/diff/types";
import type { GuidRepository } from "../../../src/domain/guid/guid-repository";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../../src/domain/guid/repo-index-repository";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";
import { createDifferGateway } from "../../../src/infrastructure/clients/wasm-differ-client";
import { SOURCE_PREFAB, VARIANT_PREFAB } from "../../fixtures/unity";

const API_BASE = "https://api.github.test";

class MemoryGuidRepository implements GuidRepository {
  storageAvailable = true;

  constructor(private readonly data: Record<string, Record<string, string>> = {}) {}

  async load(repo: string): Promise<Record<string, string>> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    return this.data[repo] ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    this.data[repo] = { ...this.data[repo], ...entries };
  }
}

class MemoryRepoIndexRepository implements RepoIndexRepository {
  private readonly guids: Record<string, Record<string, string>> = {};
  private readonly indexes: Record<string, RepoGuidIndex> = {};
  storageAvailable = true;

  async loadGuids(repo: string): Promise<Record<string, string>> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    return this.guids[repo] ?? {};
  }

  async saveGuids(repo: string, entries: Record<string, string>): Promise<void> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    this.guids[repo] = { ...this.guids[repo], ...entries };
  }

  async loadIndex(repo: string): Promise<RepoGuidIndex | undefined> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    return this.indexes[repo];
  }

  async saveIndex(repo: string, index: RepoGuidIndex): Promise<void> {
    if (!this.storageAvailable) throw new Error("storage unavailable");
    this.indexes[repo] = index;
  }
}

type RoutedRequest = { url: URL; init?: RequestInit };

function githubRoutes(respond: (request: RoutedRequest) => Response | Promise<Response>) {
  const requests: RoutedRequest[] = [];
  const fetchRoute = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = { url: new URL(String(input)), init };
    requests.push(request);
    return respond(request);
  }) as typeof fetch;
  return { requests, client: createGithubGateway(API_BASE, "token", fetchRoute) };
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function raw(bytes: Uint8Array): Response {
  const body = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(body).set(bytes);
  return new Response(body, { status: 200 });
}

function sourceDiff(resolved?: Record<string, string>): DiffV2 {
  const result = differ.diff(new Uint8Array(), VARIANT_PREFAB);
  if (!result.ok) throw new Error(result.error.message);
  return { ...result.value, resolved };
}

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDifferGateway(bytes);
});

async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = [];
  for await (const value of stream) values.push(value);
  return values;
}

describe("resolveSemanticDiff", () => {
  it("pushes repo-index names before the final JSON", async () => {
    const { client } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({
          truncated: false,
          tree: [{ path: "Assets/Indexed.cs.meta", type: "blob", sha: "meta-sha" }],
        });
      }
      if (url.pathname === "/graphql") {
        return json({ data: { repository: { b0: { text: "guid: indexed\n" } } } });
      }
      return new Response(null, { status: 500 });
    });
    const operation = resolveSemanticDiff(
      new MemoryGuidRepository(),
      new MemoryRepoIndexRepository(),
      async () => differ,
      createDiffSession(),
      client,
      {
        refs: { baseSha: "base-sha", headSha: "head-sha" },
        files: [{ path: "Assets/Foo.prefab", status: "added" }],
        guidIndex: new Map(),
        baseShas: new Map(),
      },
      "https://api.github.test:o/r",
      { ...emptyDiff(), unresolvedGuids: ["indexed"], resolved: {} },
      ["indexed"],
      {
        type: "semanticDiff",
        owner: "o",
        repo: "r",
        target: { kind: "pull", prNumber: 1 },
        path: "Assets/Foo.prefab",
      },
    );

    expect(typeof (operation as unknown as AsyncIterable<unknown>)[Symbol.asyncIterator]).toBe("function");
    const messages = await collect(operation);

    expect(messages).toHaveLength(2);
    expect(messages[0]).toMatchObject({ resolved: { indexed: "Assets/Indexed.cs" }, done: false });
    expect(messages[0]?.json).toBeUndefined();
    expect(messages[1]).toMatchObject({
      resolved: {},
      json: { resolved: { indexed: "Assets/Indexed.cs" } },
      done: true,
      status: "complete",
    });
  });

  it("uses Code Search only for GUIDs missing from the repo index", async () => {
    const { client, requests } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({
          truncated: false,
          tree: [{ path: "Assets/Indexed.cs.meta", type: "blob", sha: "meta-sha" }],
        });
      }
      if (url.pathname === "/graphql") {
        return json({ data: { repository: { b0: { text: "guid: indexed\n" } } } });
      }
      if (url.pathname === "/search/code") {
        return json({ items: [{ path: "Assets/Searched.cs.meta" }] });
      }
      return new Response(null, { status: 500 });
    });
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository(),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        { ...emptyDiff(), unresolvedGuids: ["indexed", "searched"], resolved: {} },
        ["indexed", "searched"],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    const searches = requests.filter((request) => request.url.pathname === "/search/code");
    expect(searches).toHaveLength(1);
    expect(searches[0]?.url.searchParams.get("q")).toBe('"searched" repo:o/r extension:meta');
    expect(messages.at(-1)?.json?.resolved).toEqual({
      indexed: "Assets/Indexed.cs",
      searched: "Assets/Searched.cs",
    });
  });

  it("marks the final push rateLimited after a Code Search limit", async () => {
    const { client } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({ truncated: false, tree: [] });
      }
      if (url.pathname === "/search/code") {
        return new Response(null, { status: 429, headers: { "retry-after": "1" } });
      }
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") {
        return new Response(null, { status: 500 });
      }
      return new Response(null, { status: 500 });
    });
    const first = sourceDiff({ src0: "Assets/Source.prefab" });
    first.unresolvedGuids = [...first.unresolvedGuids, "limited"];
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository({
          "https://api.github.test:o/r": { src0: "Assets/Source.prefab" },
        }),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        first,
        ["limited"],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    expect(messages.at(-1)).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("keeps rateLimited after a later rejection", async () => {
    const guidRepository = new MemoryGuidRepository({
      "https://api.github.test:o/r": { src0: "Assets/Source.prefab" },
    });
    const { client } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({ truncated: false, tree: [] });
      }
      if (url.pathname === "/search/code") {
        guidRepository.storageAvailable = false;
        return new Response(null, { status: 429, headers: { "retry-after": "1" } });
      }
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT_PREFAB);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") return raw(SOURCE_PREFAB);
      return new Response(null, { status: 500 });
    });
    const first = sourceDiff({ src0: "Assets/Source.prefab" });
    first.unresolvedGuids = [...first.unresolvedGuids, "limited"];
    const messages = await collect(
      resolveSemanticDiff(
        guidRepository,
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        first,
        ["limited"],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    expect(messages.at(-1)).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("sends a failed final push after a source fetch failure", async () => {
    const { client, requests } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT_PREFAB);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") {
        return new Response(null, { status: 500 });
      }
      return new Response(null, { status: 500 });
    });
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository({
          "https://api.github.test:o/r": { src0: "Assets/Source.prefab" },
        }),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        sourceDiff({ src0: "Assets/Source.prefab" }),
        [],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    expect(requests.some((request) => request.url.pathname.includes("/git/trees/"))).toBe(false);
    expect(messages.at(-1)).toMatchObject({ done: true, status: "failed" });
  });

  it("merges a source after its GUID resolves asynchronously", async () => {
    const { client } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({
          truncated: false,
          tree: [{ path: "Assets/Source.prefab.meta", type: "blob", sha: "source-meta-sha" }],
        });
      }
      if (url.pathname === "/graphql") {
        return json({ data: { repository: { b0: { text: "guid: src0\n" } } } });
      }
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT_PREFAB);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") return raw(SOURCE_PREFAB);
      return new Response(null, { status: 500 });
    });
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository(),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        sourceDiff(),
        ["src0"],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    const final = messages.at(-1);
    expect(final).toMatchObject({ done: true, status: "complete" });
    expect(final?.json?.neededSources).toBeUndefined();
    expect(final?.json?.resolved).toEqual({ src0: "Assets/Source.prefab" });
  });

  it("sends a final push after an unexpected rejection", async () => {
    const { client, requests } = githubRoutes(() => new Response(null, { status: 500 }));
    const indexRepository = new MemoryRepoIndexRepository();
    indexRepository.storageAvailable = false;
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository(),
        indexRepository,
        async () => differ,
        createDiffSession(),
        client,
        {
          refs: { baseSha: "base-sha", headSha: "head-sha" },
          files: [{ path: "Assets/Foo.prefab", status: "added" }],
          guidIndex: new Map(),
          baseShas: new Map(),
        },
        "https://api.github.test:o/r",
        { ...emptyDiff(), unresolvedGuids: ["unknown"], resolved: {} },
        ["unknown"],
        {
          type: "semanticDiff",
          owner: "o",
          repo: "r",
          target: { kind: "pull", prNumber: 1 },
          path: "Assets/Foo.prefab",
        },
      ),
    );

    expect(requests).toHaveLength(0);
    expect(messages).toEqual([
      {
        type: "guidResolved",
        owner: "o",
        repo: "r",
        target: { kind: "pull", prNumber: 1 },
        path: "Assets/Foo.prefab",
        resolved: {},
        done: true,
        status: "failed",
      },
    ]);
  });
});
