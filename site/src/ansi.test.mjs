import assert from "node:assert/strict";
import test from "node:test";
import { ansiToHtml } from "./ansi.mjs";

test("plain text passes through with HTML special chars escaped", () => {
  assert.equal(ansiToHtml("a <b> & c"), "a &lt;b&gt; &amp; c");
});

test("a colored run is wrapped and reset closes it", () => {
  // \x1b[32m…\x1b[0m is exactly what render_tree.zig emits for an added row sign.
  assert.equal(ansiToHtml("\x1b[32m+\x1b[0m Cylinder"), '<span class="green">+</span> Cylinder');
});

test("styles accumulate until reset", () => {
  // Dim and yellow stack (e.g. a modified sign inside a dimmed label).
  assert.equal(ansiToHtml("\x1b[2m\x1b[33mhint\x1b[0m done"), '<span class="dim yellow">hint</span> done');
});

test("an SGR code the CLI never emits fails loudly", () => {
  // The converter covers exactly the six codes in render_tree.zig; anything new
  // must break the site build instead of silently dropping styling.
  assert.throws(() => ansiToHtml("\x1b[35mx"), /unsupported/);
});
