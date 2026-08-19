import { globSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = resolve(import.meta.dirname, "../../src");
const PRESENTATION = join(SRC, "presentation");
const DOCS = "docs/extension.md";
const SAMPLE = "sample.ts";

describe("presentation types", () => {
  it("rejects a Map field on an object type", () => {
    expect(
      mapOrSetFields(`
        export type Box = {
          files: Map<string, string>;
          setFile(): void;
        };
      `),
    ).toEqual(["sample.ts Box.files: keep Map and Set inside the factory. Call a method (docs/extension.md)"]);
  });

  it("rejects a Set field on an object type", () => {
    expect(
      mapOrSetFields(`
        export type Box = {
          listeners: Set<string>;
          subscribe(): void;
        };
      `),
    ).toEqual(["sample.ts Box.listeners: keep Map and Set inside the factory. Call a method (docs/extension.md)"]);
  });

  it("allows an object type with methods and no Map or Set field", () => {
    expect(
      mapOrSetFields(`
        export type Box = {
          setFile(): void;
        };
      `),
    ).toEqual([]);
  });

  it("allows a Map type alias", () => {
    expect(mapOrSetFields("export type FileRegistry = Map<string, string>;")).toEqual([]);
  });

  it("rejects an exported function that mutates a value", () => {
    expect(
      exportedMutators(`
        export type Page = { owner: string };
        export function setOwner(page: Page): void {}
      `),
    ).toEqual([
      "sample.ts setOwner(Page): do not export a function that takes a value and mutates it (docs/extension.md)",
    ]);
  });

  it("allows a factory that returns an object", () => {
    expect(
      exportedMutators(`
        export type Box = {
          setFile(): void;
        };
        export function createBox(): Box {
          return { setFile() {} };
        }
      `),
    ).toEqual([]);
  });

  it("src/presentation object types have no Map or Set fields", () => {
    expect(mapOrSetFieldsInPresentation()).toEqual([]);
  });

  it("src/presentation values have no exported functions that mutate them", () => {
    expect(exportedMutatorsInPresentation()).toEqual([]);
  });
});

type ExportedType = {
  name: string;
  hasMethod: boolean;
  mapOrSetFields: string[];
};

type ExportedFn = {
  name: string;
  firstParamType: string | undefined;
  returnsVoid: boolean;
};

function mapOrSetFields(source: string, file = SAMPLE): string[] {
  const out: string[] = [];
  for (const type of collect(source).types) {
    for (const field of type.mapOrSetFields) {
      out.push(`${file} ${type.name}.${field}: keep Map and Set inside the factory. Call a method (${DOCS})`);
    }
  }
  return out;
}

function exportedMutators(source: string, file = SAMPLE): string[] {
  const { types, fns } = collect(source);
  const out: string[] = [];
  for (const fn of fns) {
    if (!fn.returnsVoid || fn.firstParamType === undefined) continue;
    const type = types.find((candidate) => candidate.name === fn.firstParamType);
    if (!type || type.hasMethod) continue;
    out.push(
      `${file} ${fn.name}(${fn.firstParamType}): do not export a function that takes a value and mutates it (${DOCS})`,
    );
  }
  return out;
}

function mapOrSetFieldsInPresentation(): string[] {
  const out: string[] = [];
  for (const { file, source } of presentationSources()) {
    out.push(...mapOrSetFields(source, file));
  }
  return out;
}

function exportedMutatorsInPresentation(): string[] {
  const out: string[] = [];
  for (const { file, source } of presentationSources()) {
    out.push(...exportedMutators(source, file));
  }
  return out;
}

function presentationSources(): Array<{ file: string; source: string }> {
  return globSync("**/*.ts", { cwd: PRESENTATION }).map((rel) => {
    const abs = join(PRESENTATION, rel);
    return {
      file: relative(SRC, abs).split(/[\\/]/).join("/"),
      source: readFileSync(abs, "utf8"),
    };
  });
}

function collect(source: string): { types: ExportedType[]; fns: ExportedFn[] } {
  source = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const types: ExportedType[] = [];
  const fns: ExportedFn[] = [];

  const typeRe = /export type (\w+)\s*=\s*\{/g;
  for (const match of source.matchAll(typeRe)) {
    if (match.index === undefined || match[1] === undefined) continue;
    const body = sliceBalanced(source, match.index + match[0].length - 1, "{", "}");
    if (!body) continue;
    const inner = body.slice(1, -1);
    types.push({
      name: match[1],
      hasMethod: /^\s*\w+\s*\(/m.test(inner),
      mapOrSetFields: [...inner.matchAll(/^\s*(\w+)\s*\??\s*:\s*(?:Readonly)?(?:Map|Set)\s*</gm)].flatMap((field) =>
        field[1] ? [field[1]] : [],
      ),
    });
  }

  const fnRe = /export function (\w+)\(/g;
  for (const match of source.matchAll(fnRe)) {
    if (match.index === undefined || match[1] === undefined) continue;
    const params = sliceBalanced(source, match.index + match[0].length - 1, "(", ")");
    if (!params) continue;
    const after = source.slice(match.index + match[0].length - 1 + params.length);
    fns.push({
      name: match[1],
      firstParamType: firstParamType(params.slice(1, -1)),
      returnsVoid: /^\s*:\s*void\b/.test(after),
    });
  }

  return { types, fns };
}

function sliceBalanced(source: string, openIndex: number, open: string, close: string): string | undefined {
  let depth = 0;
  for (let i = openIndex; i < source.length; i++) {
    const ch = source[i];
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return source.slice(openIndex, i + 1);
    }
  }
  return undefined;
}

function firstParamType(params: string): string | undefined {
  let depth = 0;
  for (let i = 0; i < params.length; i++) {
    const ch = params[i];
    if (ch === "(" || ch === "<") depth++;
    else if (ch === ")" || ch === ">") depth--;
    else if (ch === "," && depth === 0) {
      params = params.slice(0, i);
      break;
    }
  }
  return /^\s*\w+\s*:\s*(\w+)\s*$/.exec(params)?.[1];
}
