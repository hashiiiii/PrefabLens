/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import { prefetchPr } from "../../../src/application/diff/prefetch-pr";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import type { AuthRepository } from "../../../src/domain/auth/auth-repository";
import type { PendingSignIn } from "../../../src/domain/auth/pending-sign-in";
import type { DiffRepository } from "../../../src/domain/diff/diff-repository";
import type { DiffV2 } from "../../../src/domain/diff/types";
import type { GuidMap } from "../../../src/domain/guid/guid-map";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../../src/domain/guid/repo-index-repository";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";
import { createDifferGateway } from "../../../src/infrastructure/clients/wasm-differ-client";
import { AFTER_PREFAB, BEFORE_PREFAB } from "../../fixtures/unity";

class MemoryAuthRepository implements AuthRepository {
  private accessToken = "token";
  private pendingSignIn: PendingSignIn | undefined;

  async loadAccessToken(): Promise<string> {
    return this.accessToken;
  }

  async saveAccessToken(token: string): Promise<void> {
    this.accessToken = token;
  }

  async savePendingSignIn(pending: PendingSignIn): Promise<void> {
    this.pendingSignIn = pending;
  }

  async loadPendingSignIn(): Promise<PendingSignIn | undefined> {
    return this.pendingSignIn;
  }

  async clearPendingSignIn(): Promise<void> {
    this.pendingSignIn = undefined;
  }
}

class MemoryDiffRepository implements DiffRepository {
  readonly data = new Map<string, DiffV2>();

  async load(key: string): Promise<DiffV2 | undefined> {
    return this.data.get(key);
  }

  async save(key: string, json: DiffV2): Promise<void> {
    this.data.set(key, json);
  }
}

class MemoryRepoIndexRepository implements RepoIndexRepository {
  private readonly guids = new Map<string, GuidMap>();
  private readonly indexes = new Map<string, RepoGuidIndex>();

  async loadGuids(repo: string): Promise<GuidMap> {
    return this.guids.get(repo) ?? {};
  }

  async saveGuids(repo: string, entries: GuidMap): Promise<void> {
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

describe("prefetchPr", () => {
  it("stores prefetched diffs in the diff repository", async () => {
    const client = createGithubGateway("https://api.github.com", "token", async (input) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/pulls/1") {
        return Response.json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return Response.json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return Response.json([{ filename: "Assets/Foo.prefab", status: "modified", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return Response.json({
          truncated: false,
          tree: [{ path: "Assets/Foo.prefab", type: "blob", sha: "base-blob" }],
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return Response.json({ truncated: true, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-blob") return new Response(BEFORE_PREFAB);
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return new Response(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryDiffRepository();

    await prefetchPr(
      new MemoryAuthRepository(),
      () => client,
      async () => differ,
      repository,
      new MemoryRepoIndexRepository(),
      createDiffSession(),
      { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
    );

    const stored = await repository.load("base-sha:head-sha:Assets/Foo.prefab");
    expect(stored?.loose[0]?.fields[0]).toEqual({
      path: "Volume",
      status: "modified",
      before: "0.5",
      after: "0.8",
    });
  });

  it("uses a stored diff after a worker restart", async () => {
    const requests: URL[] = [];
    const client = createGithubGateway("https://api.github.com", "token", async (input) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return Response.json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return Response.json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return Response.json([{ filename: "Assets/Foo.prefab", status: "modified", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return Response.json({
          truncated: false,
          tree: [{ path: "Assets/Foo.prefab", type: "blob", sha: "base-blob" }],
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return Response.json({ truncated: true, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-blob") return new Response(BEFORE_PREFAB);
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return new Response(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryDiffRepository();
    const authRepository = new MemoryAuthRepository();
    const indexRepository = new MemoryRepoIndexRepository();

    await prefetchPr(
      authRepository,
      () => client,
      async () => differ,
      repository,
      indexRepository,
      createDiffSession(),
      { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
    );
    const blobRequestsAfterFirstWorker = requests.filter((request) => request.pathname.includes("/git/blobs/")).length;

    await prefetchPr(
      authRepository,
      () => client,
      async () => differ,
      repository,
      indexRepository,
      createDiffSession(),
      { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
    );

    await expect(repository.load("base-sha:head-sha:Assets/Foo.prefab")).resolves.toBeDefined();
    expect(requests.filter((request) => request.pathname.includes("/git/blobs/"))).toHaveLength(
      blobRequestsAfterFirstWorker,
    );
  });

  it("prefetches only Unity files and stops at one hundred", async () => {
    const files = Array.from({ length: 120 }, (_, index) => ({
      filename: `Assets/F${index}.prefab`,
      status: "modified",
      sha: `head-${index}`,
    }));
    files.push({ filename: "README.md", status: "modified", sha: "readme-head" });
    const requests: URL[] = [];
    const client = createGithubGateway("https://api.github.com", "token", async (input) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return Response.json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return Response.json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        const page = Number(request.searchParams.get("page"));
        const pageFiles = page === 1 ? files.slice(0, 100) : files.slice(100);
        return Response.json(pageFiles);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return Response.json({
          truncated: false,
          tree: files.map((file, index) => ({ path: file.filename, type: "blob", sha: `base-${index}` })),
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return Response.json({ truncated: false, tree: [] });
      }
      if (request.pathname.startsWith("/repos/o/r/git/blobs/base-")) return new Response(BEFORE_PREFAB);
      if (request.pathname.startsWith("/repos/o/r/git/blobs/head-")) return new Response(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryDiffRepository();

    await prefetchPr(
      new MemoryAuthRepository(),
      () => client,
      async () => differ,
      repository,
      new MemoryRepoIndexRepository(),
      createDiffSession(),
      { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
    );

    expect(repository.data.size).toBe(100);
    expect(repository.data.has("base-sha:head-sha:README.md")).toBe(false);
    expect(requests.some((request) => request.pathname.endsWith("/git/blobs/head-100"))).toBe(false);
    expect(requests.some((request) => request.pathname.endsWith("/git/blobs/readme-head"))).toBe(false);
  });

  it("does not store an oversized file", async () => {
    const oversized = new Uint8Array(13 * 1024 * 1024);
    const client = createGithubGateway("https://api.github.com", "token", async (input) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/pulls/1") {
        return Response.json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return Response.json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return Response.json([{ filename: "Assets/Big.prefab", status: "modified", sha: "head-big" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return Response.json({
          truncated: false,
          tree: [{ path: "Assets/Big.prefab", type: "blob", sha: "base-big" }],
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return Response.json({ truncated: true, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-big") return new Response(oversized);
      if (request.pathname === "/repos/o/r/git/blobs/head-big") return new Response(oversized);
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryDiffRepository();

    await prefetchPr(
      new MemoryAuthRepository(),
      () => client,
      async () => differ,
      repository,
      new MemoryRepoIndexRepository(),
      createDiffSession(),
      { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
    );

    expect(repository.data.size).toBe(0);
  });

  it("stops the remaining prefetch work after a rate limit", async () => {
    const files = Array.from({ length: 12 }, (_, index) => ({
      filename: `Assets/F${index}.prefab`,
      status: "modified",
      sha: `head-${index}`,
    }));
    const requests: URL[] = [];
    const client = createGithubGateway("https://api.github.com", "token", async (input) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return Response.json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return Response.json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return Response.json(files);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return Response.json({
          truncated: false,
          tree: files.map((file, index) => ({ path: file.filename, type: "blob", sha: `base-${index}` })),
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return Response.json({ truncated: false, tree: [] });
      }
      if (request.pathname.includes("/git/blobs/")) {
        return new Response(null, { status: 429, headers: { "retry-after": "1" } });
      }
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryDiffRepository();

    await expect(
      prefetchPr(
        new MemoryAuthRepository(),
        () => client,
        async () => differ,
        repository,
        new MemoryRepoIndexRepository(),
        createDiffSession(),
        { type: "prefetch", owner: "o", repo: "r", prNumber: 1 },
      ),
    ).resolves.toBeUndefined();

    const blobRequests = requests.filter((request) => request.pathname.includes("/git/blobs/"));
    expect(blobRequests.length).toBeGreaterThan(0);
    expect(blobRequests.some((request) => /-(?:4|5|6|7|8|9|10|11)$/.test(request.pathname))).toBe(false);
    expect(repository.data.size).toBe(0);
  });
});
