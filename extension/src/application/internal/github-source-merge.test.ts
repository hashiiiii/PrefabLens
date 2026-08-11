/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { BINARY_ASSET } from "../../../test-support/unity-fixtures";
import type { DiffV2 } from "../../domain/diff/types";
import type { GuidRepository } from "../../domain/guid/guid-repository";
import { GithubClient } from "../../infrastructure/clients/github-client";
import { createDiffer } from "../../infrastructure/clients/wasm-differ-client";
import { createDiffSession, type DiffContext } from "../diff/create-diff-session";
import type { DifferGateway } from "../gateway/differ";
import { mergeGithubSources } from "./github-source-merge";

const API_BASE = "https://api.github.test";
const OWNER = "o";
const REPO = "r";
const REPO_KEY = `${API_BASE}:${OWNER}/${REPO}`;
const enc = new TextEncoder();

const VARIANT = enc.encode(`--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: src0, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: src0, type: 3}`);

const SOURCE = enc.encode(`--- !u!1 &10
GameObject:
  m_Name: Source
  m_Component:
  - component: {fileID: 40}
--- !u!4 &40
Transform:
  m_GameObject: {fileID: 10}
  m_LocalScale: {x: 1, y: 1, z: 1}`);

function nestedSource(fileId: number, guid: string): Uint8Array {
  return enc.encode(`--- !u!1001 &${fileId}
PrefabInstance:
  m_Modification:
    m_Modifications: []
  m_SourcePrefab: {fileID: 100100000, guid: ${guid}, type: 3}`);
}

class MemoryGuidRepository implements GuidRepository {
  constructor(private readonly data: Record<string, Record<string, string>> = {}) {}

  async load(repo: string): Promise<Record<string, string>> {
    return this.data[repo] ?? {};
  }

  async save(repo: string, entries: Record<string, string>): Promise<void> {
    this.data[repo] = { ...this.data[repo], ...entries };
  }
}

function githubRoutes(respond: (request: URL) => Response) {
  const requests: URL[] = [];
  const fetchRoute = (async (input: RequestInfo | URL) => {
    const request = new URL(String(input));
    requests.push(request);
    return respond(request);
  }) as typeof fetch;
  return { requests, client: new GithubClient(API_BASE, "token", fetchRoute) };
}

function raw(bytes: Uint8Array): Response {
  const body = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(body).set(bytes);
  return new Response(body, { status: 200 });
}

function firstDiff(differ: DifferGateway, before: Uint8Array, after: Uint8Array, resolved?: Record<string, string>) {
  const result = differ.diff(before, after);
  if (!result.ok) throw new Error(result.error.message);
  return { ...result.value, resolved };
}

function context(baseShas: Map<string, string> | null = new Map()): DiffContext {
  return {
    refs: { baseSha: "base-sha", headSha: "head-sha" },
    files: [],
    guidIndex: new Map(),
    baseShas,
  };
}

function cached(paths: Record<string, string>): MemoryGuidRepository {
  return new MemoryGuidRepository({ [REPO_KEY]: paths });
}

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
});

describe("mergeGithubSources", () => {
  it("fetches a resolved source from the head and merges it", async () => {
    const path = "Assets/Source.prefab";
    const { client, requests } = githubRoutes((request) =>
      request.pathname === `/repos/${OWNER}/${REPO}/contents/Assets/Source.prefab` &&
      request.searchParams.get("ref") === "head-sha"
        ? raw(SOURCE)
        : new Response(null, { status: 404 }),
    );
    const first = firstDiff(differ, new Uint8Array(), VARIANT, { src0: path });

    const result = await mergeGithubSources(
      differ,
      cached({ src0: path }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT,
      first,
    );

    expect(result.status).toBe("complete");
    expect(result.json.neededSources).toBeUndefined();
    expect(result.json.resolved).toEqual({ src0: path });
    expect(requests.map((request) => `${request.pathname}${request.search}`)).toEqual([
      "/repos/o/r/contents/Assets/Source.prefab?ref=head-sha",
    ]);
  });

  it("fetches a removed source from the base", async () => {
    const path = "Assets/Source.prefab";
    const { client, requests } = githubRoutes((request) =>
      request.pathname === "/repos/o/r/git/blobs/source-base-blob" ? raw(SOURCE) : new Response(null, { status: 404 }),
    );
    const first = firstDiff(differ, VARIANT, new Uint8Array(), { src0: path });

    const result = await mergeGithubSources(
      differ,
      cached({ src0: path }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(new Map([[path, "source-base-blob"]])),
      VARIANT,
      new Uint8Array(),
      first,
    );

    expect(result.status).toBe("complete");
    expect(result.json.neededSources).toBeUndefined();
    expect(requests.map((request) => request.pathname)).toEqual(["/repos/o/r/git/blobs/source-base-blob"]);
  });

  it("skips a binary source and keeps the available diff", async () => {
    const path = "Assets/Source.prefab";
    const { client, requests } = githubRoutes(() => raw(BINARY_ASSET));
    const first = firstDiff(differ, new Uint8Array(), VARIANT, { src0: path });

    const result = await mergeGithubSources(
      differ,
      cached({ src0: path }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(1);
  });

  it("stops after three source rounds", async () => {
    const paths = {
      src0: "Assets/S0.prefab",
      src1: "Assets/S1.prefab",
      src2: "Assets/S2.prefab",
      src3: "Assets/S3.prefab",
    };
    const sources: Record<string, Uint8Array> = {
      "/repos/o/r/contents/Assets/S0.prefab": nestedSource(100, "src1"),
      "/repos/o/r/contents/Assets/S1.prefab": nestedSource(200, "src2"),
      "/repos/o/r/contents/Assets/S2.prefab": nestedSource(300, "src3"),
    };
    const { client, requests } = githubRoutes((request) => {
      const source = sources[request.pathname];
      return source ? raw(source) : new Response(null, { status: 404 });
    });
    const first = firstDiff(differ, new Uint8Array(), VARIANT, { src0: paths.src0 });

    const result = await mergeGithubSources(
      differ,
      cached(paths),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT,
      first,
    );

    expect(requests.map((request) => request.pathname)).toEqual([
      "/repos/o/r/contents/Assets/S0.prefab",
      "/repos/o/r/contents/Assets/S1.prefab",
      "/repos/o/r/contents/Assets/S2.prefab",
    ]);
    expect(result.json.neededSources).toEqual([{ guid: "src3", side: "after" }]);
    expect(result.status).toBe("complete");
  });

  it("does not repeat a source that makes no progress", async () => {
    const path = "Assets/Missing.prefab";
    const { client, requests } = githubRoutes(() => new Response(null, { status: 404 }));
    const first = firstDiff(differ, new Uint8Array(), VARIANT, { src0: path });

    const result = await mergeGithubSources(
      differ,
      cached({ src0: path }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(1);
  });

  it("keeps the first diff when the source path is unresolved", async () => {
    const { client, requests } = githubRoutes(() => new Response(null, { status: 500 }));
    const first: DiffV2 = firstDiff(differ, new Uint8Array(), VARIANT);

    const result = await mergeGithubSources(
      differ,
      cached({}),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(0);
  });
});
