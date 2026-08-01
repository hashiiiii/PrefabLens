import { globSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { expect, it } from "vitest";

const SRC = import.meta.dirname;
const SEPARATOR = /[\\/]/;
const TS_FILES = globSync("**/*.ts", { cwd: SRC }).map((f) => join(SRC, f));

type Layer = "domain" | "application" | "infrastructure" | "presentation";

// Allowed import targets per layer
const ALLOWED: Record<Layer, Layer[]> = {
  domain: [],
  application: ["domain"],
  infrastructure: ["domain", "application"],
  presentation: ["domain", "application"],
};

function layerOf(file: string): Layer | null {
  const top = relative(SRC, file).split(SEPARATOR)[0];
  return top === "domain" || top === "application" || top === "infrastructure" || top === "presentation" ? top : null; // globals.d.ts, this test
}

// e.g.
// presentation/background/index.ts
// presentation/content/index.ts
const ENTRY = /presentation[\\/][^\\/]+[\\/]index\.ts$/;
const CONTAINER = join(SRC, "infrastructure", "container.ts");

it("keeps imports pointing inward across layers", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    // [
    //   'from "./port/github"',
    //   './port/github',
    //   index: 18,
    //   input: '...full contents...',
    //   groups: undefined,
    // ]
    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      const target = `${resolve(dirname(file), spec)}.ts`;
      const to = layerOf(target);
      if (to === null || to === from) continue;
      const label = `${relative(SRC, file)} -> ${spec}`;
      // Entry points wire their app through the DI container
      if (to === "infrastructure" && target === CONTAINER && ENTRY.test(file)) continue;
      if (!ALLOWED[from].includes(to)) violations.push(label);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps presentation off application ports and non-container infra off use cases", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
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
