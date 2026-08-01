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

const CONTAINER = join(SRC, "infrastructure", "container.ts");

function* relativeImports(file: string): Generator<{ spec: string; target: string }> {
  for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
    const spec = match[1];
    if (spec === undefined) continue;
    yield { spec, target: `${resolve(dirname(file), spec)}.ts` };
  }
}

it("keeps imports pointing inward across layers", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    for (const { spec, target } of relativeImports(file)) {
      const to = layerOf(target);
      if (to === null || to === from) continue;
      // Entry points may import container.ts for DI wiring
      if (to === "infrastructure" && target === CONTAINER && /presentation[\\/][^\\/]+[\\/]index\.ts$/.test(file))
        continue;
      if (!ALLOWED[from].includes(to)) violations.push(`${relative(SRC, file)} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps non-container infrastructure off application use cases", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    for (const { spec, target } of relativeImports(file)) {
      const to = layerOf(target);
      if (from !== "infrastructure" || file === CONTAINER) continue;
      // Providers may import ports to implement them
      // Use cases are the violation
      if (to !== "application" || /application[\\/]port[\\/]/.test(relative(SRC, target))) continue;
      violations.push(`${relative(SRC, file)} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});
