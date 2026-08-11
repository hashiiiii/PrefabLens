/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import type { RepoGuidIndex } from "../../domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../domain/guid/repo-index-repository";
import { GithubClient } from "../../infrastructure/clients/github-client";
import { createDiffer } from "../../infrastructure/clients/wasm-differ-client";
import { createDiffSession, type DiffContext } from "../diff/create-diff-session";
import type { DifferGateway } from "../gateway/differ";
import type { GuidResolvedPush, SemanticDiffRequest } from "../gateway/messenger";
import { pushSemanticResolution } from "./push-semantic-resolution";

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
const encoder = new TextEncoder();

const VARIANT = encoder.encode(`--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: src0, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: src0, type: 3}`);

const SOURCE = encoder.encode(`--- !u!1 &10
GameObject:
  m_Name: Source
  m_Component:
  - component: {fileID: 40}
--- !u!4 &40
Transform:
  m_GameObject: {fileID: 10}
  m_LocalScale: {x: 1, y: 1, z: 1}`);

class MemoryGuidRepository implements GuidRepository {
  constructor(private readonly data: Record<string, Record<string, string>> = {}) {}

  async load(repo: string): Promise<Record<string, string>> {
    return this.data[repo] ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    this.data[repo] = { ...this.data[repo], ...entries };
  }
}

class MemoryRepoIndexRepository implements RepoIndexRepository {
  private readonly guids: Record<string, Record<string, string>> = {};
  private readonly indexes: Record<string, RepoGuidIndex> = {};

  constructor(private readonly loadFailure?: Error) {}

  async loadGuids(repo: string): Promise<Record<string, string>> {
    return this.guids[repo] ?? {};
  }

  async saveGuids(repo: string, entries: Record<string, string>): Promise<void> {
    this.guids[repo] = { ...this.guids[repo], ...entries };
  }

  async loadIndex(repo: string): Promise<RepoGuidIndex | undefined> {
    if (this.loadFailure) throw this.loadFailure;
    return this.indexes[repo];
  }

  async saveIndex(repo: string, index: RepoGuidIndex): Promise<void> {
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
  const result = differ.diff(new Uint8Array(), VARIANT);
  if (!result.ok) throw new Error(result.error.message);
  return { ...result.value, resolved };
}

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
});

describe("pushSemanticResolution", () => {
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
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
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
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    expect(pushes).toHaveLength(2);
    expect(pushes[0]).toMatchObject({ resolved: { indexed: "Assets/Indexed.cs" }, done: false });
    expect(pushes[0]?.json).toBeUndefined();
    expect(pushes[1]).toMatchObject({
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
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
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
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    const searches = requests.filter((request) => request.url.pathname === "/search/code");
    expect(searches).toHaveLength(1);
    expect(searches[0]?.url.searchParams.get("q")).toBe('"searched" repo:o/r extension:meta');
    expect(pushes.at(-1)?.json?.resolved).toEqual({
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
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") {
        return new Response(null, { status: 500 });
      }
      return new Response(null, { status: 500 });
    });
    const first = sourceDiff({ src0: SOURCE_PATH });
    first.unresolvedGuids = [...first.unresolvedGuids, "limited"];
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
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
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    expect(pushes.at(-1)).toMatchObject({ done: true, status: "rateLimited" });
  });

  it("sends a failed final push after a source fetch failure", async () => {
    const { client, requests } = githubRoutes(({ url }) => {
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") {
        return new Response(null, { status: 500 });
      }
      return new Response(null, { status: 500 });
    });
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
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
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    expect(requests.some((request) => request.url.pathname.includes("/git/trees/"))).toBe(false);
    expect(pushes.at(-1)).toMatchObject({ done: true, status: "failed" });
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
      if (url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") return raw(VARIANT);
      if (url.pathname === "/repos/o/r/contents/Assets/Source.prefab") return raw(SOURCE);
      return new Response(null, { status: 500 });
    });
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
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
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    const final = pushes.at(-1);
    expect(final).toMatchObject({ done: true, status: "complete" });
    expect(final?.json?.neededSources).toBeUndefined();
    expect(final?.json?.resolved).toEqual({ src0: SOURCE_PATH });
  });

  it("sends a final push after an unexpected rejection", async () => {
    const { client, requests } = githubRoutes(() => new Response(null, { status: 500 }));
    const pushes: GuidResolvedPush[] = [];
    const finalPush = Promise.withResolvers<void>();
    const operation = pushSemanticResolution(
      new MemoryGuidRepository(),
      new MemoryRepoIndexRepository(new Error("storage unavailable")),
      async () => differ,
      createDiffSession(),
      client,
      context(),
      REPO_KEY,
      { ...emptyDiff(), unresolvedGuids: ["unknown"], resolved: {} },
      ["unknown"],
      REQUEST,
      (message) => {
        pushes.push(message);
        if (message.done) finalPush.resolve();
      },
    );

    await finalPush.promise;
    await operation;

    expect(requests).toHaveLength(0);
    expect(pushes).toEqual([
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
