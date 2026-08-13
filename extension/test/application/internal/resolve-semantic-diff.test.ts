/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession, type DiffContext } from "../../../src/application/diff/create-diff-session";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import type { SemanticDiffRequest } from "../../../src/application/gateway/messenger";
import { resolveSemanticDiff } from "../../../src/application/internal/resolve-semantic-diff";
import { type DiffV2, emptyDiff } from "../../../src/domain/diff/types";
import type { GuidRepository } from "../../../src/domain/guid/guid-repository";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../../src/domain/guid/repo-index-repository";
import { GithubClient } from "../../../src/infrastructure/clients/github-client";
import { createDiffer } from "../../../src/infrastructure/clients/wasm-differ-client";
import { SOURCE_PREFAB, VARIANT_PREFAB } from "../../fixtures/unity";

const API_BASE = "https://api.github.test";
const OWNER = "o";
const REPO = "r";
const REPO_KEY = `${API_BASE}:${OWNER}/${REPO}`;
const MAIN_PATH = "Assets/Foo.prefab";
const SOURCE_PATH = "Assets/Source.prefab";
const REQUEST: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: OWNER,
  repo: REPO,
  target: { kind: "pull", prNumber: 1 },
  path: MAIN_PATH,
};
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
  return { requests, client: new GithubClient(API_BASE, "token", fetchRoute) };
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

function context(): DiffContext {
  return {
    refs: { baseSha: "base-sha", headSha: "head-sha" },
    files: [{ path: MAIN_PATH, status: "added" }],
    guidIndex: new Map(),
    baseShas: new Map(),
  };
}

function sourceDiff(resolved?: Record<string, string>): DiffV2 {
  const result = differ.diff(new Uint8Array(), VARIANT_PREFAB);
  if (!result.ok) throw new Error(result.error.message);
  return { ...result.value, resolved };
}

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
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
      context(),
      REPO_KEY,
      { ...emptyDiff(), unresolvedGuids: ["indexed"], resolved: {} },
      ["indexed"],
      REQUEST,
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
        context(),
        REPO_KEY,
        { ...emptyDiff(), unresolvedGuids: ["indexed", "searched"], resolved: {} },
        ["indexed", "searched"],
        REQUEST,
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
    const first = sourceDiff({ src0: SOURCE_PATH });
    first.unresolvedGuids = [...first.unresolvedGuids, "limited"];
    const messages = await collect(
      resolveSemanticDiff(
        new MemoryGuidRepository({ [REPO_KEY]: { src0: SOURCE_PATH } }),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        context(),
        REPO_KEY,
        first,
        ["limited"],
        REQUEST,
      ),
    );

    expect(messages.at(-1)).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("keeps rateLimited after a later rejection", async () => {
    const guidRepository = new MemoryGuidRepository({ [REPO_KEY]: { src0: SOURCE_PATH } });
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
    const first = sourceDiff({ src0: SOURCE_PATH });
    first.unresolvedGuids = [...first.unresolvedGuids, "limited"];
    const messages = await collect(
      resolveSemanticDiff(
        guidRepository,
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        context(),
        REPO_KEY,
        first,
        ["limited"],
        REQUEST,
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
        new MemoryGuidRepository({ [REPO_KEY]: { src0: SOURCE_PATH } }),
        new MemoryRepoIndexRepository(),
        async () => differ,
        createDiffSession(),
        client,
        context(),
        REPO_KEY,
        sourceDiff({ src0: SOURCE_PATH }),
        [],
        REQUEST,
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
        context(),
        REPO_KEY,
        sourceDiff(),
        ["src0"],
        REQUEST,
      ),
    );

    const final = messages.at(-1);
    expect(final).toMatchObject({ done: true, status: "complete" });
    expect(final?.json?.neededSources).toBeUndefined();
    expect(final?.json?.resolved).toEqual({ src0: SOURCE_PATH });
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
        context(),
        REPO_KEY,
        { ...emptyDiff(), unresolvedGuids: ["unknown"], resolved: {} },
        ["unknown"],
        REQUEST,
      ),
    );

    expect(requests).toHaveLength(0);
    expect(messages).toEqual([
      {
        type: "guidResolved",
        owner: OWNER,
        repo: REPO,
        target: REQUEST.target,
        path: MAIN_PATH,
        resolved: {},
        done: true,
        status: "failed",
      },
    ]);
  });
});
