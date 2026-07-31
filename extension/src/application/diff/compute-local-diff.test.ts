import { expect, it } from "vitest";
import type { DiffV2 } from "../../domain/diff/types";
import { ok } from "../../domain/result";
import type { DifferPort } from "../port/differ";
import { type ComputeLocalDiffDeps, computeLocalDiff } from "./compute-local-diff";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };
const enc = (s: string) => new TextEncoder().encode(s) as Uint8Array<ArrayBuffer>;

function makeDeps(overrides?: {
  diff?: DifferPort["diff"];
  diffWithAssets?: DifferPort["diffWithAssets"];
  files?: Record<string, string>; // url → text
  sources?: Record<string, string>; // `${side}/${path}` → text
}): ComputeLocalDiffDeps {
  return {
    differ: {
      diff: overrides?.diff ?? (() => ok(DIFF)),
      diffWithAssets: overrides?.diffWithAssets ?? (() => ok(DIFF)),
      isUnityYaml: () => true,
    },
    index: new Map([["g1", "Assets/S.cs"]]),
    fetchBytes: async (url) => {
      const text = overrides?.files?.[url];
      if (text === undefined) throw new Error(`${url}: HTTP 404`);
      return enc(text);
    },
    fetchSource: async (side, path) => {
      const text = overrides?.sources?.[`${side}/${path}`];
      return text === undefined ? new Uint8Array() : enc(text);
    },
  };
}

it("diffs both sides and applies names from the fixture index", async () => {
  const deps = makeDeps({ files: { "b.prefab": "b", "a.prefab": "a" } });
  const diff = await computeLocalDiff(deps, "b.prefab", "a.prefab");
  expect(diff).toEqual({ ...DIFF, resolved: { g1: "Assets/S.cs" } });
});

it("treats a missing url as the empty side (added/removed fixtures)", async () => {
  const seen: Array<[number, number]> = [];
  const deps = makeDeps({
    files: { "a.prefab": "a" },
    diff: (before, after) => {
      seen.push([before.length, after.length]);
      return ok(DIFF);
    },
  });
  await computeLocalDiff(deps, undefined, "a.prefab");
  expect(seen).toEqual([[0, 1]]);
});

it("re-diffs with fetched source assets until sources are satisfied", async () => {
  const NEEDS: DiffV2 = { ...DIFF, neededSources: [{ guid: "g1", side: "after" }] };
  const assetsSeen: string[] = [];
  const deps = makeDeps({
    files: { "b.prefab": "b", "a.prefab": "a" },
    sources: { "after/Assets/S.cs": "SRC" },
    diff: () => ok(NEEDS),
    diffWithAssets: (_b, _a, assets) => {
      for (const bytes of assets.values()) assetsSeen.push(new TextDecoder().decode(bytes));
      return ok(DIFF);
    },
  });
  const diff = await computeLocalDiff(deps, "b.prefab", "a.prefab");
  expect(assetsSeen).toEqual(["SRC"]);
  expect(diff).toEqual({ ...DIFF, resolved: { g1: "Assets/S.cs" } });
});

it("keeps the first-pass diff when a source path is unresolved or missing", async () => {
  const NEEDS: DiffV2 = {
    ...DIFF,
    unresolvedGuids: ["gX"],
    neededSources: [{ guid: "gX", side: "after" }],
  };
  const deps = makeDeps({ files: { "b.prefab": "b", "a.prefab": "a" }, diff: () => ok(NEEDS) });
  const diff = await computeLocalDiff(deps, "b.prefab", "a.prefab");
  // gX is not in the index and fixtures have no source: degrade, don't throw
  expect(diff.neededSources).toEqual(NEEDS.neededSources);
});
