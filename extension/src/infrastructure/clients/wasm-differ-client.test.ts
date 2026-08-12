/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import type { DifferGateway } from "../../application/gateway/differ";
import { must } from "../../internal/must";
import { createDiffer, createDifferLoader } from "./wasm-differ-client";

const enc = new TextEncoder();
const BEFORE = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`);
const AFTER = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`);

let differ: DifferGateway;
beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
});

describe("createDifferLoader", () => {
  it("returns one real differ for repeated loads", async () => {
    const wasmBytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
    const fetchBytes = async (url: string): Promise<BufferSource> => {
      if (url !== "prefablens.wasm") throw new Error(`Unexpected URL: ${url}`);
      return wasmBytes;
    };
    const loadDiffer = createDifferLoader("prefablens.wasm", fetchBytes);

    const first = await loadDiffer();
    const second = await loadDiffer();

    expect(second).toBe(first);
    expect(first.diff(BEFORE, AFTER).ok).toBe(true);
  });
});

describe("createDiffer", () => {
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

  it("isUnityYaml sniffs content, not paths", () => {
    // The BEFORE fixture is a bare "--- !u!" document head.
    expect(differ.isUnityYaml(BEFORE)).toBe(true);
    // .meta-style plain YAML and binary bytes are both rejected.
    expect(differ.isUnityYaml(enc.encode("fileFormatVersion: 2\nguid: abc\n"))).toBe(false);
    expect(differ.isUnityYaml(new Uint8Array([0, 1, 2, 255]))).toBe(false);
    // An absent side (added/removed file) is empty bytes: never UnityYAML.
    expect(differ.isUnityYaml(new Uint8Array(0))).toBe(false);
  });

  it("is re-entrant across many calls", () => {
    for (let i = 0; i < 50; i++) {
      const result = differ.diff(BEFORE, AFTER);
      expect(result.ok).toBe(true);
      if (result.ok) expect(result.value.schema).toBe("prefablens.diff.v2");
    }
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

    // Without assets: core requests the supply.
    const first = differ.diff(new Uint8Array(0), variant);
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.value.neededSources).toEqual([{ guid: "srcguid", side: "after" }]);

    // With assets: merged, so neededSources disappears and it becomes a full enumeration with overrides applied.
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
