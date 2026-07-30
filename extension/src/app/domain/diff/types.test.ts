import { describe, expect, it } from "vitest";
import { unresolvedRemaining } from "./types";

describe("unresolvedRemaining", () => {
  it("returns the guids without a resolved name, in order", () => {
    expect(unresolvedRemaining({ unresolvedGuids: ["g1", "g2", "g3"], resolved: { g2: "Assets/B.mat" } })).toEqual([
      "g1",
      "g3",
    ]);
  });

  it("treats a missing resolved map as nothing resolved", () => {
    // resolved is optional on DiffV2 (attached later by applyResolved): absent means every guid remains.
    expect(unresolvedRemaining({ unresolvedGuids: ["g1"] })).toEqual(["g1"]);
  });

  it("returns empty when everything is resolved", () => {
    expect(unresolvedRemaining({ unresolvedGuids: ["g1"], resolved: { g1: "Assets/A.cs" } })).toEqual([]);
  });

  it("does not let Object.prototype keys count as resolved", () => {
    // Guids are arbitrary strings: with `in` or property access, "constructor" would hit
    // Object.prototype and silently drop out of the unresolved list. Object.hasOwn keeps it.
    expect(unresolvedRemaining({ unresolvedGuids: ["constructor", "hasOwnProperty"], resolved: {} })).toEqual([
      "constructor",
      "hasOwnProperty",
    ]);
  });
});
