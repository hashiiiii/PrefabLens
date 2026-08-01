import { describe, expect, it } from "vitest";
import { parseGuidFromMeta } from "./parse-guid-from-meta";

const META = `fileFormatVersion: 2
guid: 1234567890abcdef1234567890abcdef
MonoImporter:
  serializedVersion: 2`;

describe("parseGuidFromMeta", () => {
  it("extracts the guid line", () => {
    expect(parseGuidFromMeta(META)).toBe("1234567890abcdef1234567890abcdef");
  });
  it("returns undefined when absent", () => {
    expect(parseGuidFromMeta("fileFormatVersion: 2\n")).toBeUndefined();
  });
});
