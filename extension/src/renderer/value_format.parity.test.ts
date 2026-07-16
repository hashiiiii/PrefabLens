import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

// The diff.v2 value display rules are hand-copied in four places: the
// extension's formatValue (render.ts), the Unity editor's ValueFormat.cs, and
// the CLI's writeValueText (render_tree.zig) / writeValue (render_html.zig).
// Each parser below pulls the output literal of every branch out of one
// implementation's source; the tests compare those records against the
// extension's, so changing e.g. "None" in one place fails until all four move
// together (issue #152). The guid resolution order (resolved path, then
// built-in name, then raw guid) is checked via source positions.

type Rules = {
  missing: string; // absent side of an added/removed row
  nullRef: string; // {fileID: 0}, Unity's null reference
  localRefPrefix: string; // other document-local fileIDs
  guidPrefix: string; // unresolved external reference
  builtinSuffix: string; // built-in asset, after the object name
};

function read(rel: string): string {
  return readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
}

// Slice one top-level function out of a source file: from its header to the
// first closing brace at column 0.
function fnSlice(src: string, header: string): string {
  const start = src.indexOf(header);
  expect(start, `${header} not found`).toBeGreaterThanOrEqual(0);
  return src.slice(start, src.indexOf("\n}", start));
}

function extract(src: string, re: RegExp, what: string): string {
  const m = src.match(re);
  expect(m, `${what} not found`).not.toBeNull();
  return m![1]!;
}

// Assert the guid branch tries its lookups in order: resolved → built-in → raw.
function expectResolveOrder(src: string, resolved: string, builtin: string, raw: string): void {
  const a = src.indexOf(resolved);
  const b = src.indexOf(builtin);
  const c = src.indexOf(raw);
  expect(a, `${resolved} not found`).toBeGreaterThanOrEqual(0);
  expect(b, `${builtin} after ${resolved}`).toBeGreaterThan(a);
  expect(c, `${raw} after ${builtin}`).toBeGreaterThan(b);
}

function tsRules(): Rules {
  const fn = fnSlice(read("./render.ts"), "function formatValue");
  expectResolveOrder(fn, "diff.resolved", "builtinName(", "`guid:");
  return {
    missing: extract(fn, /value === null\) return "([^"]*)"/, "null branch"),
    nullRef: extract(fn, /\? "([^"]*)" :/, "fileID 0 branch"),
    localRefPrefix: extract(fn, /: `([^`$]*)\$\{fileId\}`/, "local ref branch"),
    guidPrefix: extract(fn, /return `([^`$]*)\$\{guid\}`/, "raw guid branch"),
    builtinSuffix: extract(fn, /`\$\{builtin\}([^`]*)`/, "built-in branch"),
  };
}

function csRules(): Rules {
  const src = read("../../../editor/Editor/ValueFormat.cs");
  expectResolveOrder(src, "m.Resolved.TryGetValue", "BuiltinRefs.Name", '"guid:"');
  return {
    missing: extract(src, /IsNull\)\s*return "([^"]*)"/, "null branch"),
    nullRef: extract(src, /== "0" \? "([^"]*)"/, "fileID 0 branch"),
    localRefPrefix: extract(src, /: "([^"]*)" \+ v\.RefFileId/, "local ref branch"),
    guidPrefix: extract(src, /return "([^"]*)" \+ v\.RefGuid/, "raw guid branch"),
    builtinSuffix: extract(src, /return builtin \+ "([^"]*)"/, "built-in branch"),
  };
}

function zigTreeRules(): Rules {
  const fn = fnSlice(read("../../../cli/src/render_tree.zig"), "fn writeValueText");
  expectResolveOrder(fn, "rr.get(g)", "builtin_refs.name(", "guid:");
  return {
    missing: extract(fn, /orelse \{\s*try w\.writeAll\("([^"]*)"\)/, "null branch"),
    nullRef: extract(fn, /file_id == 0\) \{[\s\S]*?writeAll\("([^"]*)"\)/, "fileID 0 branch"),
    localRefPrefix: extract(fn, /print\("([^"{]*)\{d\}"/, "local ref branch"),
    guidPrefix: extract(fn, /print\("([^"{]*)\{s\}", \.\{g\}\)/, "raw guid branch"),
    builtinSuffix: extract(fn, /print\("\{s\}([^"]*)"/, "built-in branch"),
  };
}

function zigHtmlRules(): Rules {
  const fn = fnSlice(read("../../../cli/src/render_html.zig"), "fn writeValue(");
  expectResolveOrder(fn, "rr.get(g)", "builtin_refs.name(", "guid:");
  return {
    missing: extract(fn, /orelse \{\s*try w\.writeAll\("([^"]*)"\)/, "null branch"),
    nullRef: extract(fn, /file_id == 0\) \{[\s\S]*?writeAll\("([^"]*)"\)/, "fileID 0 branch"),
    localRefPrefix: extract(fn, /print\("([^"{]*)\{d\}"/, "local ref branch"),
    guidPrefix: extract(fn, /writeAll\("([^"]*)"\);\s*try writeEscaped\(w, g\)/, "raw guid branch"),
    builtinSuffix: extract(fn, /writeEscaped\(w, builtin\);\s*try w\.writeAll\("([^"]*)"\)/, "built-in branch"),
  };
}

it("editor ValueFormat.cs formats values like the extension's formatValue", () => {
  expect(csRules()).toEqual(tsRules());
});

it("CLI render_tree.zig formats values like the extension's formatValue", () => {
  expect(zigTreeRules()).toEqual(tsRules());
});

it("CLI render_html.zig formats values like the extension's formatValue", () => {
  expect(zigHtmlRules()).toEqual(tsRules());
});

it("both CLI renderers collapse composite nodes the same way", () => {
  // diff.v2 flattens vectors and the like into scalars before they reach the
  // extension or the editor, so map/seq fallbacks exist only in the two CLI
  // renderers that walk the model tree directly.
  const tree = fnSlice(read("../../../cli/src/render_tree.zig"), "fn writeValueText");
  const html = fnSlice(read("../../../cli/src/render_html.zig"), "fn writeValue(");
  const collapse = (src: string) => ({
    map: extract(src, /\.map => try w\.writeAll\("([^"]*)"\)/, "map branch"),
    seq: extract(src, /\.seq => try w\.writeAll\("([^"]*)"\)/, "seq branch"),
  });
  expect(collapse(html)).toEqual(collapse(tree));
});
