/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffSession, type DiffContext } from "../../../src/application/diff/create-diff-session";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import { mergeGithubSources } from "../../../src/application/internal/github-source-merge";
import type { DiffV2 } from "../../../src/domain/diff/types";
import type { GuidRepository } from "../../../src/domain/guid/guid-repository";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";
import { createDifferGateway } from "../../../src/infrastructure/clients/wasm-differ-client";
import { BINARY_ASSET, SOURCE_PREFAB, VARIANT_PREFAB } from "../../fixtures/unity";

const API_BASE = "https://api.github.test";
const OWNER = "o";
const REPO = "r";
const REPO_KEY = `${API_BASE}:${OWNER}/${REPO}`;
const enc = new TextEncoder();

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
  return { requests, client: createGithubGateway(API_BASE, "token", fetchRoute) };
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

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDifferGateway(bytes);
});

describe("mergeGithubSources", () => {
  it("fetches a resolved source from the head and merges it", async () => {
    const { client, requests } = githubRoutes((request) =>
      request.pathname === "/repos/o/r/contents/Assets/Source.prefab" && request.searchParams.get("ref") === "head-sha"
        ? raw(SOURCE_PREFAB)
        : new Response(null, { status: 404 }),
    );
    const first = firstDiff(differ, new Uint8Array(), VARIANT_PREFAB, { src0: "Assets/Source.prefab" });

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository({ [REPO_KEY]: { src0: "Assets/Source.prefab" } }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT_PREFAB,
      first,
    );

    expect(result.status).toBe("complete");
    expect(result.json.neededSources).toBeUndefined();
    expect(result.json.resolved).toEqual({ src0: "Assets/Source.prefab" });
    expect(requests.map((request) => `${request.pathname}${request.search}`)).toEqual([
      "/repos/o/r/contents/Assets/Source.prefab?ref=head-sha",
    ]);
  });

  it("fetches a removed source from the base", async () => {
    const { client, requests } = githubRoutes((request) =>
      request.pathname === "/repos/o/r/git/blobs/source-base-blob"
        ? raw(SOURCE_PREFAB)
        : new Response(null, { status: 404 }),
    );
    const first = firstDiff(differ, VARIANT_PREFAB, new Uint8Array(), { src0: "Assets/Source.prefab" });

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository({ [REPO_KEY]: { src0: "Assets/Source.prefab" } }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(new Map([["Assets/Source.prefab", "source-base-blob"]])),
      VARIANT_PREFAB,
      new Uint8Array(),
      first,
    );

    expect(result.status).toBe("complete");
    expect(result.json.neededSources).toBeUndefined();
    expect(requests.map((request) => request.pathname)).toEqual(["/repos/o/r/git/blobs/source-base-blob"]);
  });

  it("skips a binary source and keeps the available diff", async () => {
    const { client, requests } = githubRoutes(() => raw(BINARY_ASSET));
    const first = firstDiff(differ, new Uint8Array(), VARIANT_PREFAB, { src0: "Assets/Source.prefab" });

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository({ [REPO_KEY]: { src0: "Assets/Source.prefab" } }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT_PREFAB,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(1);
  });

  it("stops after three source rounds", async () => {
    const sources: Record<string, Uint8Array> = {
      "/repos/o/r/contents/Assets/S0.prefab": nestedSource(100, "src1"),
      "/repos/o/r/contents/Assets/S1.prefab": nestedSource(200, "src2"),
      "/repos/o/r/contents/Assets/S2.prefab": nestedSource(300, "src3"),
    };
    const { client, requests } = githubRoutes((request) => {
      const source = sources[request.pathname];
      return source ? raw(source) : new Response(null, { status: 404 });
    });
    const first = firstDiff(differ, new Uint8Array(), VARIANT_PREFAB, { src0: "Assets/S0.prefab" });

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository({
        [REPO_KEY]: {
          src0: "Assets/S0.prefab",
          src1: "Assets/S1.prefab",
          src2: "Assets/S2.prefab",
          src3: "Assets/S3.prefab",
        },
      }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT_PREFAB,
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
    const { client, requests } = githubRoutes(() => new Response(null, { status: 404 }));
    const first = firstDiff(differ, new Uint8Array(), VARIANT_PREFAB, { src0: "Assets/Missing.prefab" });

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository({ [REPO_KEY]: { src0: "Assets/Missing.prefab" } }),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT_PREFAB,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(1);
  });

  it("keeps the first diff when the source path is unresolved", async () => {
    const { client, requests } = githubRoutes(() => new Response(null, { status: 500 }));
    const first: DiffV2 = firstDiff(differ, new Uint8Array(), VARIANT_PREFAB);

    const result = await mergeGithubSources(
      differ,
      new MemoryGuidRepository(),
      createDiffSession(),
      client,
      OWNER,
      REPO,
      REPO_KEY,
      context(),
      new Uint8Array(),
      VARIANT_PREFAB,
      first,
    );

    expect(result).toEqual({ json: first, status: "complete" });
    expect(requests).toHaveLength(0);
  });
});
