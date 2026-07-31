import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { expect, it } from "vitest";

// Source-grep enforcement of the layer rules in docs/extension.md. Same style
// as the parity tests: cheap, mechanical, and loud when a boundary breaks.

const SRC = import.meta.dirname;
const SEP = /[\\/]/;

type Layer = "domain" | "application" | "infrastructure" | "presentation";

// Layers each layer may import from (itself is always allowed)
const ALLOWED: Record<Layer, Layer[]> = {
  domain: [],
  application: ["domain"],
  infrastructure: ["domain", "application"],
  presentation: ["domain", "application"],
};

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) return walk(full);
    return entry.name.endsWith(".ts") ? [full] : [];
  });
}

function layerOf(file: string): Layer | null {
  const top = relative(SRC, file).split(SEP)[0];
  return top === "domain" || top === "application" || top === "infrastructure" || top === "presentation" ? top : null; // globals.d.ts, this test
}

const CONTAINER = join(SRC, "infrastructure", "container.ts");
const ENTRY = /presentation[\\/][^\\/]+[\\/]index\.ts$/;

it("keeps imports pointing inward across layers", () => {
  const violations: string[] = [];
  for (const file of walk(SRC)) {
    const from = layerOf(file);
    if (from === null) continue;
    // Matches `from "<spec>"` (import/export-from, incl. multiline), bare
    // `import "<spec>";` side effects, and dynamic `import("<spec>")`.
    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      const target = `${resolve(dirname(file), spec)}.ts`;
      const to = layerOf(target);
      if (to === null || to === from) continue;
      const label = `${relative(SRC, file)} -> ${spec}`;
      // Entry points wire their app through the DI container — the only allowed infra import
      if (to === "infrastructure" && target === CONTAINER && ENTRY.test(file)) continue;
      if (!ALLOWED[from].includes(to)) violations.push(label);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps presentation off application ports and non-container infra off use cases", () => {
  const violations: string[] = [];
  for (const file of walk(SRC)) {
    const from = layerOf(file);
    if (from === null) continue;
    // Matches `from "<spec>"` (import/export-from, incl. multiline), bare
    // `import "<spec>";` side effects, and dynamic `import("<spec>")`.
    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      const target = `${resolve(dirname(file), spec)}.ts`;
      const port = /application[\\/]port[\\/]/.test(relative(SRC, target));
      const application = layerOf(target) === "application";
      // Presentation reaches business logic through use cases, never ports
      if (from === "presentation" && port) violations.push(`${relative(SRC, file)} -> ${spec}`);
      // Infra implements ports; only container.ts may compose use cases
      if (from === "infrastructure" && file !== CONTAINER && application && !port) {
        violations.push(`${relative(SRC, file)} -> ${spec}`);
      }
    }
  }
  expect(violations).toEqual([]);
});
