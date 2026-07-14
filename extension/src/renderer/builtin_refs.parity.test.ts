import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { BUILTIN_EXTRA_GUID, BUILTIN_REFS, DEFAULT_RESOURCES_GUID } from "./builtin_refs";

// Both tables are generated from the same Unity dump (issue #104). This test
// fails when someone regenerates or edits one side without the other.

function zigEntries(section: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of section.matchAll(/\.\{ \.file_id = (\d+), \.name = "([^"]*)" \}/g)) {
    out[m[1]!] = m[2]!;
  }
  return out;
}

it("Zig table keeps the same (guid, fileID) → name entries as the TS table", () => {
  const zigPath = fileURLToPath(new URL("../../../cli/src/builtin_refs.zig", import.meta.url));
  const zig = readFileSync(zigPath, "utf8");
  // The file declares the default_resources array first, builtin_extra second.
  const extraStart = zig.indexOf("const builtin_extra = [_]Entry{");
  expect(extraStart).toBeGreaterThan(0);
  expect(zigEntries(zig.slice(0, extraStart))).toEqual(BUILTIN_REFS[DEFAULT_RESOURCES_GUID]);
  expect(zigEntries(zig.slice(extraStart))).toEqual(BUILTIN_REFS[BUILTIN_EXTRA_GUID]);
});

it("guid constants match between the Zig and TS tables", () => {
  const zigPath = fileURLToPath(new URL("../../../cli/src/builtin_refs.zig", import.meta.url));
  const zig = readFileSync(zigPath, "utf8");
  expect(zig).toContain(`pub const default_resources_guid = "${DEFAULT_RESOURCES_GUID}";`);
  expect(zig).toContain(`pub const builtin_extra_guid = "${BUILTIN_EXTRA_GUID}";`);
});
