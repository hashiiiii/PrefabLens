import { describe, expect, it } from "vitest";
import { applyResolved } from "../../../../src/domain/diff/fn/apply-resolved";
import { type DiffV2, emptyDiff } from "../../../../src/domain/diff/types";

describe("applyResolved", () => {
  it("attaches names only for GUIDs that the diff references", () => {
    const result = applyResolved(
      {
        ...emptyDiff(),
        unresolvedGuids: ["aaa", "bbb"],
        roots: [],
        loose: [],
      },
      new Map([
        ["aaa", "Assets/A.cs"],
        ["zzz", "Assets/Z.cs"],
      ]),
    );

    expect(result.resolved).toEqual({ aaa: "Assets/A.cs" });
  });

  it("returns a new diff without changing the input", () => {
    const input: DiffV2 = {
      ...emptyDiff(),
      unresolvedGuids: ["aaa"],
      roots: [],
      loose: [],
    };

    const result = applyResolved(input, new Map([["aaa", "Assets/A.cs"]]));

    expect(result).not.toBe(input);
    expect(input.resolved).toBeUndefined();
  });
});
