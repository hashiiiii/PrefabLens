import { describe, expect, it } from "vitest";
import { applyResolved } from "./resolved";
import type { DiffV2 } from "./types";

describe("applyResolved", () => {
  const diff: DiffV2 = {
    schema: "prefablens.diff.v2",
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
