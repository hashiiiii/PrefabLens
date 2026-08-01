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

it("keeps imports pointing inward across layers", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    // [
    //   'from "../port/github"',
    //   '../port/github',
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
      if (to === "infrastructure" && target === CONTAINER && /presentation[\\/][^\\/]+[\\/]index\.ts$/.test(file))
        continue;
      if (!ALLOWED[from].includes(to)) violations.push(label);
    }
  }
  expect(violations).toEqual([]);
});

// Infra implements ports; only container.ts may compose use cases.
// Presentation may call application/port for transport-shaped outbound work.
it("keeps non-container infra off application use cases", () => {
  const violations: string[] = [];
  for (const file of TS_FILES) {
    const from = layerOf(file);
    if (from === null) continue;
    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      const target = `${resolve(dirname(file), spec)}.ts`;
      const port = /application[\\/]port[\\/]/.test(relative(SRC, target));
      const application = layerOf(target) === "application";
      if (from === "infrastructure" && file !== CONTAINER && application && !port) {
        violations.push(`${relative(SRC, file)} -> ${spec}`);
      }
    }
  }
  expect(violations).toEqual([]);
});
