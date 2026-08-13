/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession } from "../../../src/application/diff/create-diff-session";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import { getContext, getDiff } from "../../../src/application/internal/raw-diff";
import type { DiffRepository } from "../../../src/domain/diff/diff-repository";
import type { DiffV2 } from "../../../src/domain/diff/types";
import { GithubClient } from "../../../src/infrastructure/clients/github-client";
import { createDiffer } from "../../../src/infrastructure/clients/wasm-differ-client";
import { AFTER_PREFAB, BEFORE_PREFAB } from "../../fixtures/unity";

const API_BASE = "https://api.github.test";
const OWNER = "o";
const REPO = "r";
const PATH = "Assets/Foo.prefab";
const PULL = { kind: "pull", prNumber: 1 } as const;

class MemoryDiffRepository implements DiffRepository {
  private readonly data = new Map<string, DiffV2>();

  async load(key: string): Promise<DiffV2 | undefined> {
    return this.data.get(key);
  }

  async save(key: string, json: DiffV2): Promise<void> {
    this.data.set(key, json);
  }
}

function githubClient(respond: (request: URL) => Response | Promise<Response>): GithubClient {
  const fetchRoute = (async (input: RequestInfo | URL) => respond(new URL(String(input)))) as typeof fetch;
  return new GithubClient(API_BASE, "token", fetchRoute);
}

function json(value: unknown, status = 200, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function raw(bytes: Uint8Array): Response {
  const body = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(body).set(bytes);
  return new Response(body, { status: 200 });
}

function expectVolumeChange(json: DiffV2): void {
  expect(json.loose[0]?.fields[0]).toEqual({
    path: "Volume",
    status: "modified",
    before: "0.5",
    after: "0.8",
  });
}

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
});

describe("raw diff", () => {
  it("uses an empty before side for an added file", async () => {
    const requests: URL[] = [];
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([{ filename: PATH, status: "added", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return raw(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.json.loose[0]?.status).toBe("added");
    expect(
      requests.some(
        (request) => request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" && request.searchParams.has("ref"),
      ),
    ).toBe(false);
  });

  it("uses an empty after side for a removed file", async () => {
    const requests: URL[] = [];
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([{ filename: PATH, status: "removed", sha: "base-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [{ path: PATH, type: "blob", sha: "base-blob" }] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-blob") return raw(BEFORE_PREFAB);
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.json.loose[0]?.status).toBe("removed");
    expect(requests.filter((request) => request.pathname === "/repos/o/r/git/blobs/base-blob")).toHaveLength(1);
    expect(requests.some((request) => request.searchParams.get("ref") === "head-sha")).toBe(false);
  });

  it("treats a file missing from the PR list as modified", async () => {
    const client = githubClient((request) => {
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") return json([]);
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [{ path: PATH, type: "blob", sha: "base-blob" }] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-blob") return raw(BEFORE_PREFAB);
      if (
        request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" &&
        request.searchParams.get("ref") === "head-sha"
      ) {
        return raw(AFTER_PREFAB);
      }
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
    if (result.ok) expectVolumeChange(result.json);
  });

  it("reads a renamed base file from previousPath", async () => {
    const requests: URL[] = [];
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([
          {
            filename: PATH,
            previous_filename: "Assets/Old.prefab",
            status: "renamed",
            sha: "head-blob",
          },
        ]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: true, tree: [] });
      }
      if (
        request.pathname === "/repos/o/r/contents/Assets/Old.prefab" &&
        request.searchParams.get("ref") === "base-sha"
      ) {
        return raw(BEFORE_PREFAB);
      }
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return raw(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
    if (result.ok) expectVolumeChange(result.json);
    expect(
      requests.some(
        (request) =>
          request.pathname === "/repos/o/r/contents/Assets/Old.prefab" &&
          request.searchParams.get("ref") === "base-sha",
      ),
    ).toBe(true);
    expect(requests.some((request) => request.pathname === "/repos/o/r/contents/Assets/Foo.prefab")).toBe(false);
  });

  it("retries context after a transient failure", async () => {
    let filesAvailable = false;
    const client = githubClient((request) => {
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        if (!filesAvailable) return new Response(null, { status: 500 });
        return json([{ filename: PATH, status: "modified", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [] });
      }
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();

    await expect(getContext(session, client, OWNER, REPO, PULL)).resolves.toEqual({
      ok: false,
      error: { kind: "fetch-failed" },
    });
    filesAvailable = true;
    const retried = await getContext(session, client, OWNER, REPO, PULL);

    expect(retried.ok).toBe(true);
  });

  it("reads new PR data after the 60-second cache expires", async () => {
    let now = Date.parse("2026-08-12T00:00:00Z");
    let headSha = "head-one";
    let filePath = "Assets/First.prefab";
    const client = githubClient((request) => {
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: headSha } });
      }
      if (request.pathname === `/repos/o/r/compare/base-tip...${headSha}`) {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([{ filename: filePath, status: "modified", sha: `${headSha}-blob` }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [] });
      }
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession(() => now);

    const first = await getContext(session, client, OWNER, REPO, PULL);
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.value.refs.headSha).toBe("head-one");
    expect(first.value.files.map((file) => file.path)).toEqual(["Assets/First.prefab"]);

    headSha = "head-two";
    filePath = "Assets/Second.prefab";
    now += 59_999;
    const cached = await getContext(session, client, OWNER, REPO, PULL);
    expect(cached.ok).toBe(true);
    if (!cached.ok) return;
    expect(cached.value.refs.headSha).toBe("head-one");
    expect(cached.value.files.map((file) => file.path)).toEqual(["Assets/First.prefab"]);

    now += 2;
    const refreshed = await getContext(session, client, OWNER, REPO, PULL);
    expect(refreshed.ok).toBe(true);
    if (!refreshed.ok) return;
    expect(refreshed.value.refs.headSha).toBe("head-two");
    expect(refreshed.value.files.map((file) => file.path)).toEqual(["Assets/Second.prefab"]);
  });

  it("renders a root commit as an all-added diff", async () => {
    const requests: URL[] = [];
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/commits/head-sha") {
        return json({
          sha: "head-sha",
          parents: [],
          files: [{ filename: PATH, status: "added", sha: "head-blob" }],
        });
      }
      if (request.pathname === "/repos/o/r/git/trees/head-sha") {
        return json({ truncated: false, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return raw(AFTER_PREFAB);
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const target = { kind: "commit", sha: "head-sha" } as const;
    const context = await getContext(session, client, OWNER, REPO, target);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(context.value.refs).toEqual({ baseSha: "head-sha", headSha: "head-sha" });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.json.loose[0]?.status).toBe("added");
    expect(requests.some((request) => request.pathname.startsWith("/repos/o/r/pulls/"))).toBe(false);
  });

  it("renders exactly 25 MiB without the size gate", async () => {
    const largePrefab = new Uint8Array(25 * 1024 * 1024);
    largePrefab.fill(32);
    largePrefab.set(AFTER_PREFAB);
    const client = githubClient((request) => {
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([{ filename: PATH, status: "added", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return raw(largePrefab);
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
  });

  it("prefers blob SHA and falls back after a 404", async () => {
    const requests: URL[] = [];
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([{ filename: PATH, status: "modified", sha: "head-blob" }]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ truncated: false, tree: [{ path: PATH, type: "blob", sha: "base-blob" }] });
      }
      if (request.pathname === "/repos/o/r/git/blobs/base-blob") return raw(BEFORE_PREFAB);
      if (request.pathname === "/repos/o/r/git/blobs/head-blob") return new Response(null, { status: 404 });
      if (
        request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" &&
        request.searchParams.get("ref") === "head-sha"
      ) {
        return raw(AFTER_PREFAB);
      }
      return new Response(null, { status: 500 });
    });
    const session = createDiffSession();
    const context = await getContext(session, client, OWNER, REPO, PULL);
    expect(context.ok).toBe(true);
    if (!context.ok) return;

    const result = await getDiff(
      async () => differ,
      new MemoryDiffRepository(),
      session,
      client,
      context.value,
      OWNER,
      REPO,
      PATH,
      false,
    );

    expect(result.ok).toBe(true);
    if (result.ok) expectVolumeChange(result.json);
    expect(requests.map((request) => request.pathname)).toContain("/repos/o/r/git/blobs/base-blob");
    expect(requests.map((request) => request.pathname)).toContain("/repos/o/r/git/blobs/head-blob");
    expect(
      requests.some(
        (request) =>
          request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" &&
          request.searchParams.get("ref") === "head-sha",
      ),
    ).toBe(true);
    expect(requests.some((request) => request.searchParams.get("ref") === "base-sha")).toBe(false);
  });

  it("uses the contents API after a truncated or failed base tree", async () => {
    for (const treeResponse of [json({ truncated: true, tree: [] }), new Response(null, { status: 500 })]) {
      const requests: URL[] = [];
      const client = githubClient((request) => {
        requests.push(request);
        if (request.pathname === "/repos/o/r/pulls/1") {
          return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
        }
        if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
          return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
        }
        if (request.pathname === "/repos/o/r/pulls/1/files") {
          return json([{ filename: PATH, status: "modified", sha: "head-blob" }]);
        }
        if (request.pathname === "/repos/o/r/git/trees/base-sha") return treeResponse.clone();
        if (
          request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" &&
          request.searchParams.get("ref") === "base-sha"
        ) {
          return raw(BEFORE_PREFAB);
        }
        if (request.pathname === "/repos/o/r/git/blobs/head-blob") return raw(AFTER_PREFAB);
        return new Response(null, { status: 500 });
      });
      const session = createDiffSession();
      const context = await getContext(session, client, OWNER, REPO, PULL);
      expect(context.ok).toBe(true);
      if (!context.ok) continue;

      const result = await getDiff(
        async () => differ,
        new MemoryDiffRepository(),
        session,
        client,
        context.value,
        OWNER,
        REPO,
        PATH,
        false,
      );

      expect(result.ok).toBe(true);
      if (result.ok) expectVolumeChange(result.json);
      expect(
        requests.some(
          (request) =>
            request.pathname === "/repos/o/r/contents/Assets/Foo.prefab" &&
            request.searchParams.get("ref") === "base-sha",
        ),
      ).toBe(true);
    }
  });

  it("propagates a base-tree rate limit", async () => {
    const client = githubClient((request) => {
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") return json([]);
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({ message: "API rate limit exceeded" }, 429, { "retry-after": "2" });
      }
      return new Response(null, { status: 500 });
    });

    await expect(getContext(createDiffSession(), client, OWNER, REPO, PULL)).resolves.toEqual({
      ok: false,
      error: { kind: "rate-limited", retryAfterMs: 2000 },
    });
  });

  it("reads a removed meta file from its files API SHA", async () => {
    const requests: URL[] = [];
    const metaPath = "Assets/S.cs.meta";
    const client = githubClient((request) => {
      requests.push(request);
      if (request.pathname === "/repos/o/r/pulls/1") {
        return json({ base: { sha: "base-tip" }, head: { sha: "head-sha" } });
      }
      if (request.pathname === "/repos/o/r/compare/base-tip...head-sha") {
        return json({ merge_base_commit: { sha: "base-sha" }, files: [] });
      }
      if (request.pathname === "/repos/o/r/pulls/1/files") {
        return json([
          { filename: PATH, status: "modified", sha: "head-blob" },
          { filename: metaPath, status: "removed", sha: "meta-base-blob" },
        ]);
      }
      if (request.pathname === "/repos/o/r/git/trees/base-sha") {
        return json({
          truncated: false,
          tree: [
            { path: PATH, type: "blob", sha: "base-blob" },
            { path: metaPath, type: "blob", sha: "meta-base-blob" },
          ],
        });
      }
      if (request.pathname === "/repos/o/r/git/blobs/meta-base-blob") {
        return raw(new TextEncoder().encode("fileFormatVersion: 2\nguid: abc\n"));
      }
      return new Response(null, { status: 500 });
    });

    const context = await getContext(createDiffSession(), client, OWNER, REPO, PULL);

    expect(context.ok).toBe(true);
    if (!context.ok) return;
    expect(context.value.guidIndex).toEqual(new Map([["abc", "Assets/S.cs"]]));
    expect(requests.map((request) => request.pathname)).toContain("/repos/o/r/git/blobs/meta-base-blob");
    expect(requests.some((request) => request.pathname === "/repos/o/r/contents/Assets/S.cs.meta")).toBe(false);
  });
});
