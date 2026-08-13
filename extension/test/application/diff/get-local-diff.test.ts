/// <reference types="node" />
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { getLocalDiff } from "../../../src/application/diff/get-local-diff";
import type { DifferGateway } from "../../../src/application/gateway/differ";
import { createDifferGateway } from "../../../src/infrastructure/clients/wasm-differ-client";
import { AFTER_PREFAB, BEFORE_PREFAB, SOURCE_PREFAB, VARIANT_PREFAB } from "../../fixtures/unity";

let differ: DifferGateway;

beforeAll(async () => {
  const bytes = readFileSync(new URL("../../../../zig-out/bin/prefablens.wasm", import.meta.url));
  differ = await createDifferGateway(bytes);
});

describe("getLocalDiff", () => {
  it("diffs fixture files and applies names from the fixture index", async () => {
    const files = new Map([
      ["before.prefab", BEFORE_PREFAB],
      ["after.prefab", AFTER_PREFAB],
    ]);
    const sources = new Map<string, Uint8Array<ArrayBuffer>>();
    const fetchBytes = async (url: string): Promise<Uint8Array<ArrayBuffer>> => {
      const bytes = files.get(url);
      if (bytes === undefined) throw new Error(`${url}: HTTP 404`);
      return bytes;
    };
    const fetchSource = async (side: "before" | "after", path: string): Promise<Uint8Array> =>
      sources.get(`${side}/${path}`) ?? new Uint8Array();

    const result = await getLocalDiff(
      differ,
      new Map([["def", "Assets/S.cs"]]),
      fetchBytes,
      fetchSource,
      "before.prefab",
      "after.prefab",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.resolved).toEqual({ def: "Assets/S.cs" });
    expect(result.value.loose[0]?.fields[0]).toEqual({
      path: "Volume",
      status: "modified",
      before: "0.5",
      after: "0.8",
    });
  });

  it("uses an empty before side when the fixture URL is absent", async () => {
    const files = new Map([["after.prefab", AFTER_PREFAB]]);
    const sources = new Map<string, Uint8Array<ArrayBuffer>>();
    const fetchBytes = async (url: string): Promise<Uint8Array<ArrayBuffer>> => {
      const bytes = files.get(url);
      if (bytes === undefined) throw new Error(`${url}: HTTP 404`);
      return bytes;
    };
    const fetchSource = async (side: "before" | "after", path: string): Promise<Uint8Array> =>
      sources.get(`${side}/${path}`) ?? new Uint8Array();

    const result = await getLocalDiff(
      differ,
      new Map([["def", "Assets/S.cs"]]),
      fetchBytes,
      fetchSource,
      undefined,
      "after.prefab",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.loose[0]?.status).toBe("added");
  });

  it("re-diffs with a real source asset from the fixture routes", async () => {
    const files = new Map([["variant.prefab", VARIANT_PREFAB]]);
    const sources = new Map([["after/Assets/Source.prefab", SOURCE_PREFAB]]);
    const fetchBytes = async (url: string): Promise<Uint8Array<ArrayBuffer>> => {
      const bytes = files.get(url);
      if (bytes === undefined) throw new Error(`${url}: HTTP 404`);
      return bytes;
    };
    const fetchSource = async (side: "before" | "after", path: string): Promise<Uint8Array> =>
      sources.get(`${side}/${path}`) ?? new Uint8Array();

    const result = await getLocalDiff(
      differ,
      new Map([["src0", "Assets/Source.prefab"]]),
      fetchBytes,
      fetchSource,
      undefined,
      "variant.prefab",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.neededSources).toBeUndefined();
    expect(result.value.resolved).toEqual({ src0: "Assets/Source.prefab" });
    const instance = result.value.roots[0];
    expect(instance?.kind).toBe("prefabInstance");
    if (instance?.kind !== "prefabInstance") return;
    expect(instance.components[0]?.fields.find((field) => field.path === "Scale")?.after).toBe("(1, 2, 1)");
  });

  it("keeps the first diff when a source path is unresolved or absent", async () => {
    const files = new Map([["variant.prefab", VARIANT_PREFAB]]);
    const sources = new Map<string, Uint8Array<ArrayBuffer>>();
    const fetchBytes = async (url: string): Promise<Uint8Array<ArrayBuffer>> => {
      const bytes = files.get(url);
      if (bytes === undefined) throw new Error(`${url}: HTTP 404`);
      return bytes;
    };
    const fetchSource = async (side: "before" | "after", path: string): Promise<Uint8Array> =>
      sources.get(`${side}/${path}`) ?? new Uint8Array();

    const unresolved = await getLocalDiff(differ, new Map(), fetchBytes, fetchSource, undefined, "variant.prefab");
    const absent = await getLocalDiff(
      differ,
      new Map([["src0", "Assets/Missing.prefab"]]),
      fetchBytes,
      fetchSource,
      undefined,
      "variant.prefab",
    );

    expect(unresolved.ok).toBe(true);
    expect(absent.ok).toBe(true);
    if (!unresolved.ok || !absent.ok) return;
    expect(unresolved.value.neededSources).toEqual([{ guid: "src0", side: "after" }]);
    expect(unresolved.value.resolved).toEqual({});
    expect(absent.value.neededSources).toEqual([{ guid: "src0", side: "after" }]);
    expect(absent.value.resolved).toEqual({ src0: "Assets/Missing.prefab" });
  });
});
