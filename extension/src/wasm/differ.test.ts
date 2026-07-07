/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { createDiffer, DiffError, type Differ } from "./differ";

const enc = new TextEncoder();
const BEFORE = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`);
const AFTER = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`);

let differ: Differ;
beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDiffer(bytes);
});

describe("createDiffer", () => {
  it("returns a parsed diff.v2 document", () => {
    const json = differ.diff(BEFORE, AFTER);
    expect(json.schema).toBe("prefablens.diff.v2");
    expect(json.unresolvedGuids).toEqual(["def"]);
    expect(json.loose[0]?.fields[0]).toEqual({ path: "Volume", status: "modified", before: "0.5", after: "0.8" });
  });

  it("handles empty before (added file)", () => {
    expect(differ.diff(new Uint8Array(0), AFTER).schema).toBe("prefablens.diff.v2");
  });

  it("throws DiffError with the error name on core failure", () => {
    let src = "--- !u!1 &1\nGameObject:\n";
    for (let d = 1; d <= 200; d++) src += `${"  ".repeat(d)}a:\n`;
    const hostile = enc.encode(src);
    expect(() => differ.diff(hostile, hostile)).toThrowError(/NestingTooDeep/);
    expect(() => differ.diff(hostile, hostile)).toThrowError(DiffError);
  });

  it("is re-entrant across many calls", () => {
    for (let i = 0; i < 50; i++) expect(differ.diff(BEFORE, AFTER).schema).toBe("prefablens.diff.v2");
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

    // assets なし: core が供給を要求する。
    const first = differ.diff(new Uint8Array(0), variant);
    expect(first.neededSources).toEqual([{ guid: "srcguid", side: "after" }]);

    // assets あり: 合成されて neededSources は消え、override 適用済みの全列挙になる。
    const merged = differ.diffWithAssets(new Uint8Array(0), variant, new Map([["srcguid", source]]));
    expect(merged.neededSources).toBeUndefined();
    const inst = merged.roots[0]!;
    expect(inst.kind).toBe("prefabInstance");
    if (inst.kind !== "prefabInstance") return;
    expect(inst.overrides).toEqual([]);
    const scale = inst.components[0]?.fields.find((f) => f.path === "Scale");
    expect(scale?.after).toBe("(1, 2, 1)");
  });
});
