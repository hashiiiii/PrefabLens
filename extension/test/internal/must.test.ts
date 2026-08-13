import { describe, expect, it } from "vitest";
import { must } from "../../src/internal/must";

describe("must", () => {
  it("returns present values unchanged, including falsy ones", () => {
    // 0 / "" / false are valid payloads. Only null and undefined are absent.
    expect(must(0)).toBe(0);
    expect(must("")).toBe("");
    expect(must(false)).toBe(false);
  });

  it("throws on null and on undefined", () => {
    expect(() => must(null)).toThrowError(/invariant/);
    expect(() => must(undefined)).toThrowError(/invariant/);
  });
});
