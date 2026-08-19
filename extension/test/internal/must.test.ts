import { describe, expect, it } from "vitest";
import { must } from "../../src/internal/must";

describe("must", () => {
  it("returns zero unchanged", () => {
    expect(must(0)).toBe(0);
  });

  it("returns an empty string unchanged", () => {
    expect(must("")).toBe("");
  });

  it("returns false unchanged", () => {
    expect(must(false)).toBe(false);
  });

  it("throws on null", () => {
    expect(() => must(null)).toThrowError(/invariant/);
  });

  it("throws on undefined", () => {
    expect(() => must(undefined)).toThrowError(/invariant/);
  });
});
