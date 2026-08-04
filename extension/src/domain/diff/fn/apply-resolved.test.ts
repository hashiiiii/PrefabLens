import { describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../types";
import { applyResolved } from "./apply-resolved";

describe("applyResolved", () => {
  const diff: DiffV2 = {
    ...emptyDiff(),
    unresolvedGuids: ["aaa", "bbb"],
    roots: [],
    loose: [],
  };

  it("attaches only referenced-and-resolvable guids (scoped like core)", () => {
    const index = new Map([
      ["aaa", "Assets/A.cs"],
      ["zzz", "Assets/Z.cs"],
    ]);
    const out = applyResolved(diff, index);
    expect(out.resolved).toEqual({ aaa: "Assets/A.cs" }); // bbb unresolved, zzz not referenced
    expect(out).not.toBe(diff); // does not mutate the input
    expect(diff.resolved).toBeUndefined();
  });
});
