import { expect, it } from "vitest";
import type { DiffV2 } from "../../domain/diff/types";
import { err, ok } from "../../domain/result";
import type { DifferPort } from "../port/differ";
import { getLocalDiff } from "./get-local-diff";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] };
const enc = (s: string) => new TextEncoder().encode(s) as Uint8Array<ArrayBuffer>;

function makeFakes(overrides?: {
  diff?: DifferPort["diff"];
  diffWithAssets?: DifferPort["diffWithAssets"];
  files?: Record<string, string>; // url → text
  sources?: Record<string, string>; // `${side}/${path}` → text
}) {
  const differ: DifferPort = {
    diff: overrides?.diff ?? (() => ok(DIFF)),
    diffWithAssets: overrides?.diffWithAssets ?? (() => ok(DIFF)),
    isUnityYaml: () => true,
  };
  const index = new Map([["g1", "Assets/S.cs"]]);
  const fetchBytes = async (url: string) => {
    const text = overrides?.files?.[url];
    if (text === undefined) throw new Error(`${url}: HTTP 404`);
    return enc(text);
  };
  const fetchSource = async (side: "before" | "after", path: string) => {
    const text = overrides?.sources?.[`${side}/${path}`];
    return text === undefined ? new Uint8Array() : enc(text);
  };
  return { differ, index, fetchBytes, fetchSource };
}

it("diffs both sides and applies names from the fixture index", async () => {
  const { differ, index, fetchBytes, fetchSource } = makeFakes({
    files: { "b.prefab": "b", "a.prefab": "a" },
  });
  const diff = await getLocalDiff(differ, index, fetchBytes, fetchSource, "b.prefab", "a.prefab");
  expect(diff).toEqual(ok({ ...DIFF, resolved: { g1: "Assets/S.cs" } }));
});

it("treats a missing url as the empty side (added/removed fixtures)", async () => {
  const seen: Array<[number, number]> = [];
  const { differ, index, fetchBytes, fetchSource } = makeFakes({
    files: { "a.prefab": "a" },
    diff: (before, after) => {
      seen.push([before.length, after.length]);
      return ok(DIFF);
    },
  });
  await getLocalDiff(differ, index, fetchBytes, fetchSource, undefined, "a.prefab");
  expect(seen).toEqual([[0, 1]]);
});

it("re-diffs with fetched source assets until sources are satisfied", async () => {
  const NEEDS: DiffV2 = { ...DIFF, neededSources: [{ guid: "g1", side: "after" }] };
  const assetsSeen: string[] = [];
  const { differ, index, fetchBytes, fetchSource } = makeFakes({
    files: { "b.prefab": "b", "a.prefab": "a" },
    sources: { "after/Assets/S.cs": "SRC" },
    diff: () => ok(NEEDS),
    diffWithAssets: (_b, _a, assets) => {
      for (const bytes of assets.values()) assetsSeen.push(new TextDecoder().decode(bytes));
      return ok(DIFF);
    },
  });
  const diff = await getLocalDiff(differ, index, fetchBytes, fetchSource, "b.prefab", "a.prefab");
  expect(assetsSeen).toEqual(["SRC"]);
  expect(diff).toEqual(ok({ ...DIFF, resolved: { g1: "Assets/S.cs" } }));
});

it("keeps the first-pass diff when a source path is unresolved or missing", async () => {
  const NEEDS: DiffV2 = {
    ...DIFF,
    unresolvedGuids: ["gX"],
    neededSources: [{ guid: "gX", side: "after" }],
  };
  const { differ, index, fetchBytes, fetchSource } = makeFakes({
    files: { "b.prefab": "b", "a.prefab": "a" },
    diff: () => ok(NEEDS),
  });
  const res = await getLocalDiff(differ, index, fetchBytes, fetchSource, "b.prefab", "a.prefab");
  // gX is not in the index and fixtures have no source: degrade, don't fail
  expect(res.ok && res.value.neededSources).toEqual(NEEDS.neededSources);
});

it("returns the differ failure as a result instead of throwing", async () => {
  // Expected failures travel as Result (docs/extension.md); the demo branches on ok
  const { differ, index, fetchBytes, fetchSource } = makeFakes({
    files: { "b.prefab": "b", "a.prefab": "a" },
    diff: () => err({ kind: "diff-failed", message: "bad yaml" }),
  });
  await expect(getLocalDiff(differ, index, fetchBytes, fetchSource, "b.prefab", "a.prefab")).resolves.toEqual(
    err({ kind: "diff-failed", message: "bad yaml" }),
  );
});
