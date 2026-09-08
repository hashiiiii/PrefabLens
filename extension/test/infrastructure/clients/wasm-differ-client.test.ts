/// <reference types="node" />
import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import { createFixturesGateway } from "../../../src/infrastructure/clients/fixture-client";
import { createDifferGateway, createDifferLoader } from "../../../src/infrastructure/clients/wasm-differ-client";
import { must } from "../../../src/internal/must";

const enc = new TextEncoder();
const BEFORE = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`);
const AFTER = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`);
const wasmBytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));

let differ: DifferGateway;
beforeAll(async () => {
  differ = await createDifferGateway(wasmBytes);
});

describe("createDifferLoader", () => {
  let server: Server;
  let directory: string;
  let wasmPath: string;
  let wasmUrl: string;
  let requests: number;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), "prefablens-wasm-"));
    wasmPath = join(directory, "prefablens.wasm");
    requests = 0;
    // Real file replacements exercise recovery through fetch and WASM instantiation.
    server = createServer(async (_request, response) => {
      requests++;
      try {
        const bytes = await readFile(wasmPath);
        response.writeHead(200, { "content-type": "application/wasm" }).end(bytes);
      } catch {
        response.writeHead(404).end("Not found");
      }
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("Expected a TCP server address");
    wasmUrl = `http://127.0.0.1:${address.port}/prefablens.wasm`;
  });

  afterEach(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    await rm(directory, { recursive: true, force: true });
  });

  it("returns one real differ for repeated loads", async () => {
    await writeFile(wasmPath, wasmBytes);
    const loadDiffer = createDifferLoader(wasmUrl);

    const first = await loadDiffer();
    const second = await loadDiffer();

    expect(second).toBe(first);
    expect(requests).toBe(1);
    expect(first.diff(BEFORE, AFTER).ok).toBe(true);
  });

  it("shares one pending initialization between concurrent calls", async () => {
    await writeFile(wasmPath, wasmBytes);
    const loadDiffer = createDifferLoader(wasmUrl);

    // Both callers arrive before fetch can finish, so they must share initialization.
    const [first, second] = await Promise.all([loadDiffer(), loadDiffer()]);

    expect(second).toBe(first);
    expect(requests).toBe(1);
    expect(first.diff(BEFORE, AFTER).ok).toBe(true);
  });

  it("retries a failed fetch after the asset becomes available", async () => {
    // The demo fetcher rejects HTTP errors before WASM instantiation starts.
    const loadDiffer = createDifferLoader(wasmUrl, createFixturesGateway().fetchBytes);
    const [first, second] = await Promise.allSettled([loadDiffer(), loadDiffer()]);

    expect(first.status).toBe("rejected");
    expect(second.status).toBe("rejected");
    if (first.status !== "rejected" || second.status !== "rejected") return;
    expect(first.reason).toBeInstanceOf(Error);
    expect(first.reason.message).toContain("HTTP 404");
    expect(second.reason).toBe(first.reason);
    expect(requests).toBe(1);

    await writeFile(wasmPath, wasmBytes);
    const [recovered, concurrent] = await Promise.all([loadDiffer(), loadDiffer()]);

    expect(concurrent).toBe(recovered);
    expect(await loadDiffer()).toBe(recovered);
    expect(requests).toBe(2);
    expect(recovered.diff(BEFORE, AFTER).ok).toBe(true);
  });

  it("retries after invalid WASM bytes are replaced", async () => {
    await writeFile(wasmPath, "Invalid WASM");
    const loadDiffer = createDifferLoader(wasmUrl);

    await expect(loadDiffer()).rejects.toBeInstanceOf(WebAssembly.CompileError);
    expect(requests).toBe(1);

    await writeFile(wasmPath, wasmBytes);
    const recovered = await loadDiffer();

    expect(await loadDiffer()).toBe(recovered);
    expect(requests).toBe(2);
    expect(recovered.diff(BEFORE, AFTER).ok).toBe(true);
  });
});

describe("createDifferGateway", () => {
  it("returns a parsed diff.v2 document", () => {
    const result = differ.diff(BEFORE, AFTER);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.schema).toBe("prefablens.diff.v2");
    expect(result.value.unresolvedGuids).toEqual(["def"]);
    expect(result.value.loose[0]?.fields[0]).toEqual({
      path: "Volume",
      status: "modified",
      before: "0.5",
      after: "0.8",
    });
  });

  it("handles empty before (added file)", () => {
    const result = differ.diff(new Uint8Array(0), AFTER);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.schema).toBe("prefablens.diff.v2");
  });

  it("returns DiffFailure with the error name on core failure", () => {
    let src = "--- !u!1 &1\nGameObject:\n";
    for (let d = 1; d <= 200; d++) src += `${"  ".repeat(d)}a:\n`;
    const hostile = enc.encode(src);
    const result = differ.diff(hostile, hostile);
    expect(result).toEqual({ ok: false, error: { kind: "diff-failed", message: "NestingTooDeep" } });
  });

  it("accepts a UnityYAML document head", () => {
    expect(differ.isUnityYaml(BEFORE)).toBe(true);
  });

  it("rejects plain YAML metadata", () => {
    expect(differ.isUnityYaml(enc.encode("fileFormatVersion: 2\nguid: abc\n"))).toBe(false);
  });

  it("rejects binary data", () => {
    expect(differ.isUnityYaml(new Uint8Array([0, 1, 2, 255]))).toBe(false);
  });

  it("rejects an empty file side", () => {
    expect(differ.isUnityYaml(new Uint8Array(0))).toBe(false);
  });

  it("is re-entrant across many calls", () => {
    for (let i = 0; i < 50; i++) {
      const result = differ.diff(BEFORE, AFTER);
      expect(result.ok).toBe(true);
      if (result.ok) expect(result.value.schema).toBe("prefablens.diff.v2");
    }
  });

  it("requests a source prefab when the source is absent", () => {
    const variant = enc.encode(`--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: srcguid, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}`);

    const result = differ.diff(new Uint8Array(0), variant);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.neededSources).toEqual([{ guid: "srcguid", side: "after" }]);
  });

  it("diffWithAssets merges a source prefab into the instance node", () => {
    const variant = enc.encode(`--- !u!1001 &1001
PrefabInstance:
  m_Modification:
    m_Modifications:
    - target: {fileID: 40, guid: srcguid, type: 3}
      propertyPath: m_LocalScale.y
      value: 2
  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}`);
    const source = enc.encode(`--- !u!1 &10
GameObject:
  m_Name: Cyl
  m_Component:
  - component: {fileID: 40}
--- !u!4 &40
Transform:
  m_GameObject: {fileID: 10}
  m_LocalScale: {x: 1, y: 1, z: 1}`);

    const merged = differ.diffWithAssets(new Uint8Array(0), variant, new Map([["srcguid", source]]));
    expect(merged.ok).toBe(true);
    if (!merged.ok) return;
    expect(merged.value.neededSources).toBeUndefined();
    const inst = must(merged.value.roots[0]);
    expect(inst.kind).toBe("prefabInstance");
    if (inst.kind !== "prefabInstance") return;
    expect(inst.overrides).toEqual([]);
    const scale = inst.components[0]?.fields.find((f) => f.path === "Scale");
    expect(scale?.after).toBe("(1, 2, 1)");
  });
});
