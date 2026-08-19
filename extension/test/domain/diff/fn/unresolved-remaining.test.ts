import { describe, expect, it } from "vitest";
import { unresolvedRemaining } from "../../../../src/domain/diff/fn/unresolved-remaining";

describe("unresolvedRemaining", () => {
  it("returns unresolved GUIDs in source order", () => {
    expect(unresolvedRemaining({ unresolvedGuids: ["g1", "g2", "g3"], resolved: { g2: "Assets/B.mat" } })).toEqual([
      "g1",
      "g3",
    ]);
  });

  it("treats a missing resolved map as nothing resolved", () => {
    // applyResolved attaches the optional resolved map after the initial diff.
    expect(unresolvedRemaining({ unresolvedGuids: ["g1"] })).toEqual(["g1"]);
  });

  it("does not let Object.prototype keys count as resolved", () => {
    // A GUID can equal an Object.prototype key. Only an own property represents a resolved GUID.
    expect(unresolvedRemaining({ unresolvedGuids: ["constructor", "hasOwnProperty"], resolved: {} })).toEqual([
      "constructor",
      "hasOwnProperty",
    ]);
  });
});
