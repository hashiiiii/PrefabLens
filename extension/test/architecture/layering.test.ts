import { globSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = resolve(import.meta.dirname, "../../src");
const SEPARATOR = /[\\/]/;
const TS_FILES = globSync("**/*.ts", { cwd: SRC }).map((f) => join(SRC, f));

type Layer = "domain" | "application" | "infrastructure" | "presentation";

type ImportEdge = {
  spec: string;
  to: string;
  toLayer: Layer | null;
};

type RelativeImport = ImportEdge & {
  from: string;
  fromLayer: Layer | null;
};

type FileImports = {
  from: string;
  fromLayer: Layer | null;
  relative: ImportEdge[];
  external: string[];
};

const ALLOWED: Record<Layer, Layer[]> = {
  domain: [],
  application: ["domain"],
  infrastructure: ["domain", "application"],
  presentation: ["domain", "application"],
};

const PRESENTATION_ENTRY = /^presentation\/[^/]+\/index\.ts$/;
const CLIENT_DIR = /^infrastructure\/clients\//;
const CLIENT_FILE = /-client\.ts$/;
const APPLICATION_GATEWAY = /^application\/gateway\//;

function toRel(file: string): string {
  return relative(SRC, file).split(SEPARATOR).join("/");
}

function layerOf(relPath: string): Layer | null {
  const top = relPath.split("/")[0];
  return top === "domain" || top === "application" || top === "infrastructure" || top === "presentation" ? top : null;
}

function buildFileImports(): FileImports[] {
  return TS_FILES.map((file) => {
    const from = toRel(file);
    const fromLayer = layerOf(from);
    const relativeImports: ImportEdge[] = [];
    const external: string[] = [];

    for (const match of readFileSync(file, "utf8").matchAll(/(?:from\s*|import\s*\(?\s*)"([^"]+)"/g)) {
      const spec = match[1];
      if (spec === undefined) continue;
      if (!spec.startsWith(".")) {
        external.push(spec);
        continue;
      }
      const to = toRel(`${resolve(dirname(file), spec)}.ts`);
      relativeImports.push({ spec, to, toLayer: layerOf(to) });
    }

    return { from, fromLayer, relative: relativeImports, external };
  });
}

function expectNoViolations(violations: string[]) {
  expect(violations, violations.join("\n")).toEqual([]);
}

function edgeViolation({ from, spec }: { from: string; spec: string }): string {
  return `${from} -> ${spec}`;
}

const FILE_IMPORTS = buildFileImports();
const RELATIVE_IMPORTS: RelativeImport[] = FILE_IMPORTS.flatMap(({ from, fromLayer, relative: imports }) =>
  imports.map((edge) => ({ from, fromLayer, ...edge })),
);

describe("layer imports", () => {
  it("each layer imports only from allowed layers", () => {
    expectNoViolations(
      RELATIVE_IMPORTS.filter((relImport) => {
        if (relImport.fromLayer === null || relImport.toLayer === null || relImport.fromLayer === relImport.toLayer) {
          return false;
        }
        return !ALLOWED[relImport.fromLayer].includes(relImport.toLayer);
      }).map(edgeViolation),
    );
  });

  it("domain production files import only from domain/", () => {
    expectNoViolations(
      FILE_IMPORTS.filter((entry) => entry.fromLayer === "domain" && !entry.from.endsWith(".test.ts")).flatMap(
        (entry) => [
          ...entry.external.map((spec) => edgeViolation({ from: entry.from, spec })),
          ...entry.relative
            .filter((edge) => edge.toLayer !== "domain")
            .map((edge) => edgeViolation({ from: entry.from, spec: edge.spec })),
        ],
      ),
    );
  });
});

describe("application gateway", () => {
  it("infrastructure imports from application only through gateway/", () => {
    expectNoViolations(
      RELATIVE_IMPORTS.filter(
        (relImport) =>
          relImport.fromLayer === "infrastructure" &&
          relImport.toLayer === "application" &&
          !APPLICATION_GATEWAY.test(relImport.to),
      ).map(edgeViolation),
    );
  });
});

describe("access to internal/", () => {
  it("only files under a parent import from that parent/internal/", () => {
    expectNoViolations(
      RELATIVE_IMPORTS.flatMap((relImport) => {
        const parts = relImport.to.split("/");
        const index = parts.indexOf("internal");
        if (index < 1) return [];
        const parent = parts.slice(0, index).join("/");
        if (relImport.from.startsWith(`${parent}/`)) return [];
        return [edgeViolation(relImport)];
      }),
    );
  });
});

describe("composition root", () => {
  it("only presentation entry points import container.ts", () => {
    expectNoViolations(
      RELATIVE_IMPORTS.filter(
        (relImport) => relImport.to === "container.ts" && !PRESENTATION_ENTRY.test(relImport.from),
      ).map(edgeViolation),
    );
  });
});

describe("infrastructure clients", () => {
  it("each file in infrastructure/clients implements a gateway or a repository", () => {
    expectNoViolations(
      FILE_IMPORTS.filter((entry) => CLIENT_DIR.test(entry.from)).flatMap((entry) => {
        if (entry.from.endsWith(".test.ts")) return [];
        if (!CLIENT_FILE.test(entry.from)) return [entry.from];
        const implementsInterface = entry.relative.some(
          ({ to }) => APPLICATION_GATEWAY.test(to) || /^domain\/.*-repository\.ts$/.test(to),
        );
        return implementsInterface ? [] : [entry.from];
      }),
    );
  });
});
