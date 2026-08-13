/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import { getSemanticDiff } from "../../../src/application/diff/get-semantic-diff";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import type { SemanticDiffRequest } from "../../../src/application/gateway/messenger";
import type { PendingSignIn } from "../../../src/domain/auth/token";
import type { TokenRepository } from "../../../src/domain/auth/token-repository";
import type { DiffRepository } from "../../../src/domain/diff/diff-repository";
import type { DiffV2 } from "../../../src/domain/diff/types";
import type { GuidRepository } from "../../../src/domain/guid/guid-repository";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../../src/domain/guid/repo-index-repository";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";
import { createDifferGateway } from "../../../src/infrastructure/clients/wasm-differ-client";
import { AFTER_PREFAB, BEFORE_PREFAB } from "../../fixtures/unity";

const OWNER = "o";
const REPO = "r";
const REQUEST: SemanticDiffRequest = {
  type: "semanticDiff",
  owner: OWNER,
  repo: REPO,
  target: { kind: "pull", prNumber: 1 },
  path: "Assets/Foo.prefab",
};

class MemoryTokenRepository implements TokenRepository {
  private pendingSignIn: PendingSignIn | undefined;

  constructor(private accessToken: string | undefined) {}

  async readAccessToken(): Promise<string | undefined> {
    return this.accessToken;
  }

  async saveAccessToken(token: string): Promise<void> {
    this.accessToken = token;
  }

  async savePendingSignIn(pending: PendingSignIn): Promise<void> {
    this.pendingSignIn = pending;
  }

  async readPendingSignIn(): Promise<PendingSignIn | undefined> {
    return this.pendingSignIn;
  }

  async clearPendingSignIn(): Promise<void> {
    this.pendingSignIn = undefined;
  }
}

class MemoryDiffRepository implements DiffRepository {
  private readonly data = new Map<string, DiffV2>();

  async load(key: string): Promise<DiffV2 | undefined> {
    return this.data.get(key);
  }

  async save(key: string, json: DiffV2): Promise<void> {
    this.data.set(key, json);
  }
}

class MemoryGuidRepository implements GuidRepository {
  private readonly data = new Map<string, Record<string, string>>();

  async load(repo: string): Promise<Record<string, string>> {
    return this.data.get(repo) ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    this.data.set(repo, { ...this.data.get(repo), ...entries });
  }
}

class MemoryRepoIndexRepository implements RepoIndexRepository {
  private readonly guids = new Map<string, Record<string, string>>();
  private readonly indexes = new Map<string, RepoGuidIndex>();

  async loadGuids(repo: string): Promise<Record<string, string>> {
    return this.guids.get(repo) ?? {};
  }

  async saveGuids(repo: string, entries: Record<string, string>): Promise<void> {
    this.guids.set(repo, { ...this.guids.get(repo), ...entries });
  }

  async loadIndex(repo: string): Promise<RepoGuidIndex | undefined> {
    return this.indexes.get(repo);
  }

  async saveIndex(repo: string, index: RepoGuidIndex): Promise<void> {
    this.indexes.set(repo, index);
  }
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

describe("getSemanticDiff", () => {
  it("yields access-token-missing before network work", async () => {
    const requests: URL[] = [];
    const stream = getSemanticDiff(
      new MemoryTokenRepository(undefined),
      (base, token) =>
        createGithubGateway(base, token, async (input) => {
          requests.push(new URL(String(input)));
          return new Response(null, { status: 500 });
        }),
      async () => differ,
      new MemoryGuidRepository(),
      new MemoryDiffRepository(),
      new MemoryRepoIndexRepository(),
      createDiffSession(),
      REQUEST,
    );

    expect(typeof (stream as unknown as AsyncIterable<unknown>)[Symbol.asyncIterator]).toBe("function");
    expect(await collect(stream as unknown as AsyncIterable<unknown>)).toEqual([
      { type: "response", response: { ok: false, error: "access-token-missing" } },
    ]);
    expect(requests).toHaveLength(0);
  });

  it("returns a complete result when the PR meta index resolves every GUID", async () => {
    const events = await collect(
      getSemanticDiff(
        new MemoryTokenRepository("token"),
        (base, token) =>
          createGithubGateway(base, token, async (input) => {
            const request = new URL(String(input));
            if (request.pathname === "/repos/o/r/pulls/1") {
              return new Response(JSON.stringify({ base: { sha: "base-tip" }, head: { sha: "head-sha" } }), {
                status: 200,
                headers: { "content-type": "application/json" },
              });
            }
            if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
              return new Response(JSON.stringify({ merge_base_commit: { sha: "base-sha" }, files: [] }), {
                status: 200,
                headers: { "content-type": "application/json" },
              });
            }
            if (request.pathname === "/repos/o/r/pulls/1/files") {
              return new Response(
                JSON.stringify([
                  { filename: "Assets/Foo.prefab", status: "modified", sha: "head-blob" },
                  { filename: "Assets/S.cs.meta", status: "modified", sha: "meta-blob" },
                ]),
                { status: 200, headers: { "content-type": "application/json" } },
              );
            }
            if (request.pathname === "/repos/o/r/git/trees/base-sha") {
              return new Response(
                JSON.stringify({
                  truncated: false,
                  tree: [{ path: "Assets/Foo.prefab", type: "blob", sha: "base-blob" }],
                }),
                { status: 200, headers: { "content-type": "application/json" } },
              );
            }
            if (request.pathname === "/repos/o/r/git/blobs/meta-blob")
              return new Response("guid: def\n", { status: 200 });
            if (request.pathname === "/repos/o/r/git/blobs/base-blob")
              return new Response(BEFORE_PREFAB, { status: 200 });
            if (request.pathname === "/repos/o/r/git/blobs/head-blob")
              return new Response(AFTER_PREFAB, { status: 200 });
            return new Response(null, { status: 500 });
          }),
        async () => differ,
        new MemoryGuidRepository(),
        new MemoryDiffRepository(),
        new MemoryRepoIndexRepository(),
        createDiffSession(),
        REQUEST,
      ),
    );

    expect(events).toHaveLength(1);
    const response = events[0]?.type === "response" ? events[0].response : undefined;
    expect(response).toBeDefined();
    if (!response) return;
    expect(response.ok).toBe(true);
    if (!response.ok) return;
    expect(response.pending).toBeUndefined();
    expect(response.json.resolved).toEqual({ def: "Assets/S.cs" });
  });

  it("yields pending before it starts Code Search", async () => {
    let startSearch!: () => void;
    const searchStarted = new Promise<void>((resolve) => {
      startSearch = resolve;
    });
    let releaseSearch!: () => void;
    const searchReleased = new Promise<void>((resolve) => {
      releaseSearch = resolve;
    });
    const stream = getSemanticDiff(
      new MemoryTokenRepository("token"),
      (base, token) =>
        createGithubGateway(base, token, async (input) => {
          const request = new URL(String(input));
          if (request.pathname === "/repos/o/r/pulls/1") {
            return new Response(JSON.stringify({ base: { sha: "base-tip" }, head: { sha: "head-sha" } }), {
              status: 200,
              headers: { "content-type": "application/json" },
            });
          }
          if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
            return new Response(JSON.stringify({ merge_base_commit: { sha: "base-sha" }, files: [] }), {
              status: 200,
              headers: { "content-type": "application/json" },
            });
          }
          if (request.pathname === "/repos/o/r/pulls/1/files") {
            return new Response(
              JSON.stringify([{ filename: "Assets/Foo.prefab", status: "modified", sha: "head-blob" }]),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          }
          if (request.pathname === "/repos/o/r/git/trees/base-sha") {
            return new Response(
              JSON.stringify({
                truncated: false,
                tree: [{ path: "Assets/Foo.prefab", type: "blob", sha: "base-blob" }],
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            );
          }
          if (request.pathname === "/repos/o/r/git/trees/head-sha") {
            return new Response(JSON.stringify({ truncated: true, tree: [] }), {
              status: 200,
              headers: { "content-type": "application/json" },
            });
          }
          if (request.pathname === "/repos/o/r/git/blobs/base-blob")
            return new Response(BEFORE_PREFAB, { status: 200 });
          if (request.pathname === "/repos/o/r/git/blobs/head-blob") return new Response(AFTER_PREFAB, { status: 200 });
          if (request.pathname === "/search/code") {
            startSearch();
            await searchReleased;
            return new Response(JSON.stringify({ items: [{ path: "Assets/S.cs.meta" }] }), {
              status: 200,
              headers: { "content-type": "application/json" },
            });
          }
          return new Response(null, { status: 500 });
        }),
      async () => differ,
      new MemoryGuidRepository(),
      new MemoryDiffRepository(),
      new MemoryRepoIndexRepository(),
      createDiffSession(),
      REQUEST,
    );

    const first = await stream.next();
    expect(first.value).toMatchObject({ type: "response", response: { ok: true, pending: true } });
    let searchIsPending = true;
    void searchStarted.then(() => {
      searchIsPending = false;
    });
    await Promise.resolve();
    expect(searchIsPending).toBe(true);

    const remaining = collect(stream);
    await searchStarted;
    releaseSearch();
    expect((await remaining).at(-1)).toMatchObject({
      type: "resolution",
      message: { done: true, json: { resolved: { def: "Assets/S.cs" } } },
    });
  });
});
