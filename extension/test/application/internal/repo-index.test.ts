import { describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import { getRepoIndex } from "../../../src/application/internal/repo-index";
import type { GuidMap } from "../../../src/domain/guid/guid-map";
import type { RepoGuidIndex } from "../../../src/domain/guid/repo-guid-index";
import type { RepoIndexRepository } from "../../../src/domain/guid/repo-index-repository";
import { GithubClient } from "../../../src/infrastructure/clients/github-client";

const API_BASE = "https://api.github.test";
const REPO_KEY = "repoKey";

class MemoryRepoIndexRepository implements RepoIndexRepository {
  constructor(
    private readonly guids: Record<string, GuidMap> = {},
    private readonly indexes: Record<string, RepoGuidIndex> = {},
  ) {}

  async loadGuids(repo: string): Promise<GuidMap> {
    return this.guids[repo] ?? {};
  }

  async saveGuids(repo: string, entries: GuidMap): Promise<void> {
    this.guids[repo] = { ...this.guids[repo], ...entries };
  }

  async loadIndex(repo: string): Promise<RepoGuidIndex | undefined> {
    return this.indexes[repo];
  }

  async saveIndex(repo: string, index: RepoGuidIndex): Promise<void> {
    this.indexes[repo] = index;
  }
}

describe("getRepoIndex", () => {
  it("builds and stores the GUID index from meta blobs", async () => {
    const requests: URL[] = [];
    const client = new GithubClient(API_BASE, "token", async (input, init) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({
          truncated: false,
          tree: [{ path: "Assets/S.cs.meta", type: "blob", sha: "sha1" }],
        });
      }
      if (request.pathname === "/graphql") {
        expect(init?.method).toBe("POST");
        return Response.json({ data: { repository: { b0: { text: "fileFormatVersion: 2\nguid: g1\n" } } } });
      }
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryRepoIndexRepository();

    const result = await getRepoIndex(repository, createDiffSession(), client, "o", "r", REPO_KEY, "H");

    expect(result).toEqual({ g1: "Assets/S.cs" });
    await expect(repository.loadGuids(REPO_KEY)).resolves.toEqual({ sha1: "g1" });
    await expect(repository.loadIndex(REPO_KEY)).resolves.toEqual({
      treeSha: "H",
      guids: { g1: "Assets/S.cs" },
    });
    expect(requests.map((request) => request.pathname)).toEqual(["/repos/o/r/git/trees/H", "/graphql"]);
  });

  it("uses the stored index when the tree SHA is unchanged", async () => {
    const requests: URL[] = [];
    const client = new GithubClient(API_BASE, "token", async (input) => {
      requests.push(new URL(String(input)));
      return new Response(null, { status: 500 });
    });
    const stored = { treeSha: "H", guids: { g1: "Assets/S.cs" } };
    const repository = new MemoryRepoIndexRepository({}, { [REPO_KEY]: stored });

    expect(await getRepoIndex(repository, createDiffSession(), client, "o", "r", REPO_KEY, "H")).toEqual(stored.guids);
    expect(requests).toHaveLength(0);
  });

  it("fetches only meta blobs missing from the stored SHA cache", async () => {
    const graphqlQueries: string[] = [];
    const client = new GithubClient(API_BASE, "token", async (input, init) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({
          truncated: false,
          tree: [
            { path: "Assets/A.cs.meta", type: "blob", sha: "known-sha" },
            { path: "Assets/B.cs.meta", type: "blob", sha: "new-sha" },
          ],
        });
      }
      if (request.pathname === "/graphql") {
        const body = JSON.parse(String(init?.body)) as { query: string };
        graphqlQueries.push(body.query);
        return Response.json({ data: { repository: { b0: { text: "guid: gB\n" } } } });
      }
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryRepoIndexRepository({ [REPO_KEY]: { "known-sha": "gA" } });

    const result = await getRepoIndex(repository, createDiffSession(), client, "o", "r", REPO_KEY, "H");

    expect(graphqlQueries).toHaveLength(1);
    expect(graphqlQueries[0]).toContain('object(oid: "new-sha")');
    expect(graphqlQueries[0]).not.toContain('object(oid: "known-sha")');
    expect(result).toEqual({ gA: "Assets/A.cs", gB: "Assets/B.cs" });
  });

  it("fetches GraphQL blobs in groups of one hundred", async () => {
    const metas = Array.from({ length: 250 }, (_, index) => ({
      path: `Assets/F${index}.cs.meta`,
      type: "blob",
      sha: `s${index}`,
    }));
    const graphqlBatchSizes: number[] = [];
    const client = new GithubClient(API_BASE, "token", async (input, init) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({ truncated: false, tree: metas });
      }
      if (request.pathname === "/graphql") {
        const body = JSON.parse(String(init?.body)) as { query: string };
        graphqlBatchSizes.push(body.query.match(/object\(oid:/g)?.length ?? 0);
        return Response.json({ data: { repository: {} } });
      }
      return new Response(null, { status: 500 });
    });

    await getRepoIndex(new MemoryRepoIndexRepository(), createDiffSession(), client, "o", "r", REPO_KEY, "H");

    expect(graphqlBatchSizes).toEqual([100, 100, 50]);
  });

  it("returns null for a truncated tree", async () => {
    const requests: URL[] = [];
    const client = new GithubClient(API_BASE, "token", async (input) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({ truncated: true, tree: [] });
      }
      return new Response(null, { status: 500 });
    });

    expect(
      await getRepoIndex(new MemoryRepoIndexRepository(), createDiffSession(), client, "o", "r", REPO_KEY, "H"),
    ).toBeNull();
    expect(requests.map((request) => request.pathname)).toEqual(["/repos/o/r/git/trees/H"]);
  });

  it("returns null for more than fifty thousand meta files", async () => {
    const metas = Array.from({ length: 50_001 }, (_, index) => ({
      path: `Assets/F${index}.meta`,
      type: "blob",
      sha: `s${index}`,
    }));
    const requests: URL[] = [];
    const client = new GithubClient(API_BASE, "token", async (input) => {
      const request = new URL(String(input));
      requests.push(request);
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({ truncated: false, tree: metas });
      }
      return new Response(null, { status: 500 });
    });
    const repository = new MemoryRepoIndexRepository();

    expect(await getRepoIndex(repository, createDiffSession(), client, "o", "r", REPO_KEY, "H")).toBeNull();
    await expect(repository.loadIndex(REPO_KEY)).resolves.toBeUndefined();
    expect(requests.map((request) => request.pathname)).toEqual(["/repos/o/r/git/trees/H"]);
  });

  it("skips meta files without a GUID", async () => {
    const client = new GithubClient(API_BASE, "token", async (input) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/git/trees/H") {
        return Response.json({
          truncated: false,
          tree: [
            { path: "Assets/A.cs.meta", type: "blob", sha: "sha1" },
            { path: "Assets/B.cs.meta", type: "blob", sha: "sha2" },
          ],
        });
      }
      if (request.pathname === "/graphql") {
        return Response.json({
          data: { repository: { b0: { text: "guid: g1\n" }, b1: { text: "not yaml at all" } } },
        });
      }
      return new Response(null, { status: 500 });
    });

    expect(
      await getRepoIndex(new MemoryRepoIndexRepository(), createDiffSession(), client, "o", "r", REPO_KEY, "H"),
    ).toEqual({ g1: "Assets/A.cs" });
  });

  it("pins session fallback after a rate limit", async () => {
    const requests: URL[] = [];
    const client = new GithubClient(API_BASE, "token", async (input) => {
      requests.push(new URL(String(input)));
      return new Response(null, { status: 429 });
    });
    const session = createDiffSession();
    const repository = new MemoryRepoIndexRepository();

    expect(await getRepoIndex(repository, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(await getRepoIndex(repository, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    expect(requests).toHaveLength(1);
  });

  it("retries after a non-rate-limit failure", async () => {
    let treeAvailable = false;
    const client = new GithubClient(API_BASE, "token", async (input) => {
      const request = new URL(String(input));
      if (request.pathname === "/repos/o/r/git/trees/H") {
        if (!treeAvailable) return new Response(null, { status: 500 });
        return Response.json({
          truncated: false,
          tree: [{ path: "Assets/S.cs.meta", type: "blob", sha: "sha1" }],
        });
      }
      if (request.pathname === "/graphql") {
        return Response.json({ data: { repository: { b0: { text: "guid: g1\n" } } } });
      }
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const repository = new MemoryRepoIndexRepository();

    expect(await getRepoIndex(repository, session, client, "o", "r", REPO_KEY, "H")).toBeNull();
    treeAvailable = true;
    expect(await getRepoIndex(repository, session, client, "o", "r", REPO_KEY, "H")).toEqual({
      g1: "Assets/S.cs",
    });
  });
});
