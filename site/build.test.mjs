import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

function buildWithColor(color) {
  // Per-command settings keep the real Git comparison independent of the user's configuration.
  execFileSync(process.execPath, ["build.mjs"], {
    cwd: import.meta.dirname,
    env: {
      ...process.env,
      GIT_CONFIG_COUNT: "2",
      GIT_CONFIG_KEY_0: "color.ui",
      GIT_CONFIG_VALUE_0: color,
      GIT_CONFIG_KEY_1: "color.diff",
      GIT_CONFIG_VALUE_1: color,
    },
  });
  const generated = join(import.meta.dirname, "generated");
  const pullRequest = JSON.parse(readFileSync(join(generated, "pull-request.json"), "utf8"));
  const readRawHtml = (path) => readFileSync(join(generated, "raw-html", path), "utf8");
  return {
    pullRequest,
    tables: pullRequest.files.map((file) => readRawHtml(file.table)),
    hero: readRawHtml("hero-diff.html"),
    terminal: readRawHtml("terminal.html"),
  };
}

test("Raw diffs retain fixture changes when Git forces color", () => {
  const plain = buildWithColor("never");
  const colored = buildWithColor("always");

  // Equality alone could pass if both builds silently lost the fixture changes.
  for (const result of [plain, colored]) {
    for (const file of result.pullRequest.files) {
      assert(file.added + file.removed > 0, `${file.path} has no Raw diff changes`);
    }
    assert.match(result.hero, /<tr class="add">/);
    assert.match(result.hero, /<tr class="del">/);
    assert.equal(result.hero, result.tables[0]);
    assert.match(result.terminal, /<span class="[^"]*\b(?:red|green|yellow)\b[^"]*">/);
  }
  assert.deepEqual(colored, plain);
});
