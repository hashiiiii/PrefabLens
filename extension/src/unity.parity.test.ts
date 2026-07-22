import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { must } from "./util/must";

// The UnityYAML extension prefilter is hand-copied in two places: the CLI's
// git-side gate (unity_path.zig) and the extension's path check (unity.ts).
// Both match case-insensitively, so parity is over lowercased, sorted sets
// (issue #152). The site demo gate in build.mjs is fixture-only and not kept
// in lockstep here.

function read(rel: string): string {
  return readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
}

function tsExtensions(): string[] {
  // unity.ts encodes the list as a single alternation: /\.(prefab|unity|...)$/i
  const m = read("./unity.ts").match(/\/\\\.\(([^)]+)\)\$\/i/);
  expect(m, "UNITY_PATH regex not found in unity.ts").not.toBeNull();
  return must(m?.[1])
    .split("|")
    .map((e) => e.toLowerCase())
    .sort();
}

function zigExtensions(): string[] {
  const src = read("../../cli/src/unity_path.zig");
  const start = src.indexOf("const extensions = [_][]const u8{");
  expect(start, "extensions array not found in unity_path.zig").toBeGreaterThan(0);
  const body = src.slice(start, src.indexOf("};", start));
  return [...body.matchAll(/"\.([^"]+)"/g)].map((m) => must(m[1]).toLowerCase()).sort();
}

it("CLI unity_path.zig gates the same extensions as the extension", () => {
  const ts = tsExtensions();
  expect(ts).toContain("prefab"); // guard: an empty parse must not pass vacuously
  expect(zigExtensions()).toEqual(ts);
});
