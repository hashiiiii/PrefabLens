import { describe, expect, it } from "vitest";
import { emptyDiff, type GuidResolvedPush } from "../types";
import { mergeResolvedPush } from "./merge-resolved-push";

const at = {
  type: "guidResolved",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "A.prefab",
} as const;

describe("mergeResolvedPush", () => {
  it("merges resolved names on an intermediate push without touching the tree", () => {
    const current = { ...emptyDiff(), unresolvedGuids: ["g1", "g2"], resolved: { g1: "A.prefab" } };
    const push: GuidResolvedPush = { ...at, resolved: { g2: "B.prefab" }, done: false };
    const next = mergeResolvedPush(current, push);
    expect(next.resolved).toEqual({ g1: "A.prefab", g2: "B.prefab" });
    expect(next.roots).toBe(current.roots);
  });

  it("replaces the whole diff when the final push carries json (updateSources reshapes)", () => {
    const current = { ...emptyDiff(), unresolvedGuids: ["g1"] };
    const reshaped = { ...emptyDiff(), unresolvedGuids: [] };
    const push: GuidResolvedPush = { ...at, resolved: {}, json: reshaped, done: true, status: "complete" };
    expect(mergeResolvedPush(current, push)).toBe(reshaped);
  });
});
