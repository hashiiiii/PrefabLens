import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { STYLES } from "./styles";

// pl-dark is the extension-only theme marker: the CLI stylesheet replaces the
// .pl-root.pl-dark block with a prefers-color-scheme media query (documented
// delta 2 in cli/src/semantic_view.css), so it is excluded from the set.
const THEME_MARKERS = new Set(["pl-dark", "pl-light"]);

function plClasses(css: string): Set<string> {
  const found = new Set<string>();
  for (const m of css.matchAll(/pl-[a-z0-9-]+/g)) found.add(m[0]);
  for (const marker of THEME_MARKERS) found.delete(marker);
  return found;
}

it("CLI stylesheet keeps the same pl-* class set as the extension renderer", () => {
  const cssPath = fileURLToPath(new URL("../../../cli/src/semantic_view.css", import.meta.url));
  const cliCss = readFileSync(cssPath, "utf8");
  expect(plClasses(cliCss)).toEqual(plClasses(STYLES));
});
