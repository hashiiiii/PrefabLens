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
  return top === "domain" || top === "application" || top === "infrastructure" || top === "presentation" ? top : null; // globals.d.ts, container.ts, internal/, this test
}

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
      if (!ALLOWED[from].includes(to)) violations.push(`${relative(SRC, file)} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps infrastructure off application public functions", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    for (const { spec, target } of relativeImports(file)) {
      const to = layerOf(target);
      if (from !== "infrastructure") continue;
      // Clients can import gateways to implement them.
      // Public functions and internal helpers are the violation.
      if (to !== "application" || /application[\\/]gateway[\\/]/.test(relative(SRC, target))) continue;
      violations.push(`${relative(SRC, file)} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps presentation off application/internal", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    if (layerOf(file) !== "presentation") continue;
    for (const { spec, target } of relativeImports(file)) {
      if (/application[\\/]internal[\\/]/.test(relative(SRC, target))) {
        violations.push(`${relative(SRC, file)} -> ${spec}`);
      }
    }
  }
  expect(violations).toEqual([]);
});

it("keeps container.ts reachable only from presentation entry points", () => {
  // The composition root imports infrastructure. Any other importer leaks
  // infrastructure into its own layer.
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const rel = relative(SRC, file);
    if (/^presentation[\\/][^\\/]+[\\/]index\.ts$/.test(rel)) continue;
    for (const { spec, target } of relativeImports(file)) {
      if (target === join(SRC, "container.ts")) violations.push(`${rel} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});

it("keeps production domain files inside domain", () => {
  // Doc rule: "This layer imports nothing outside domain/." Tests are exempt
  // (parity tests read sources via node:fs and use must).
  const violations: string[] = [];
  for (const file of TS_FILES) {
    if (layerOf(file) !== "domain" || file.endsWith(".test.ts")) continue;
    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"([^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      const inside = spec.startsWith(".") && layerOf(`${resolve(dirname(file), spec)}.ts`) === "domain";
      if (!inside) violations.push(`${relative(SRC, file)} -> ${spec}`);
    }
  }
  expect(violations).toEqual([]);
});
