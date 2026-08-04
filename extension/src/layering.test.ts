import { globSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = import.meta.dirname;
const SEPARATOR = /[\\/]/;
const TS_FILES = globSync("**/*.ts", { cwd: SRC }).map((f) => join(SRC, f));

type Layer = "domain" | "application" | "infrastructure" | "presentation";

const ALLOWED: Record<Layer, Layer[]> = {
  domain: [],
  application: ["domain"],
  infrastructure: ["domain", "application"],
  presentation: ["domain", "application"],
};

function layerOf(file: string): Layer | null {
  const top = relative(SRC, file).split(SEPARATOR)[0];
  return top === "domain" || top === "application" || top === "infrastructure" || top === "presentation" ? top : null;
}

function* relativeImports(file: string): Generator<{ spec: string; target: string }> {
  for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"(\.[^"]+)"/g)) {
    const spec = match[1];
    if (spec === undefined) continue;
    yield { spec, target: `${resolve(dirname(file), spec)}.ts` };
  }
}

describe("layer imports", () => {
  it("each layer imports only allowed layers", () => {
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

  it("domain production files import only from domain/", () => {
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
});

describe("application gateway", () => {
  it("infrastructure imports application only through gateway/", () => {
    const violations: string[] = [];
    for (const file of TS_FILES) {
      if (layerOf(file) !== "infrastructure") continue;
      for (const { spec, target } of relativeImports(file)) {
        if (layerOf(target) !== "application") continue;
        if (/application[\\/]gateway[\\/]/.test(relative(SRC, target))) continue;
        violations.push(`${relative(SRC, file)} -> ${spec}`);
      }
    }
    expect(violations).toEqual([]);
  });
});

describe("internal/ access", () => {
  it("a file imports internal/ only under its parent", () => {
    const violations: string[] = [];
    for (const file of TS_FILES) {
      const fileRel = relative(SRC, file).split(SEPARATOR).join("/");
      for (const { spec, target } of relativeImports(file)) {
        const parts = relative(SRC, target).split(SEPARATOR);
        const index = parts.indexOf("internal");
        if (index < 1) continue;
        const parent = parts.slice(0, index).join("/");
        if (!fileRel.startsWith(`${parent}/`)) violations.push(`${fileRel} -> ${spec}`);
      }
    }
    expect(violations).toEqual([]);
  });
});

describe("composition root", () => {
  it("only presentation entry points import container.ts", () => {
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
});

describe("infrastructure clients", () => {
  it("each file in infrastructure/clients implements a gateway or a repository", () => {
    const violations: string[] = [];
    for (const file of TS_FILES) {
      const rel = relative(SRC, file);
      if (!/^infrastructure[\\/]clients[\\/]/.test(rel)) continue;
      if (!/-client(\.test)?\.ts$/.test(rel)) {
        violations.push(rel);
        continue;
      }
      if (rel.endsWith(".test.ts")) continue;
      const targets = [...relativeImports(file)].map(({ target }) => relative(SRC, target));
      const implementsInterface = targets.some(
        (t) => /^application[\\/]gateway[\\/]/.test(t) || /^domain[\\/].*-repository\.ts$/.test(t),
      );
      if (!implementsInterface) violations.push(rel);
    }
    expect(violations).toEqual([]);
  });
});
