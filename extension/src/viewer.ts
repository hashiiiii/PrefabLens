// Curated public surface of the embeddable semantic-diff viewer. Consumers
// outside the extension's own entry points (today: the site demo, src/demo.ts,
// bundled by `pnpm run demo`) import from this module only, so API drift is a
// type error instead of a broken page.
export { createToggle, injectPageStyles, type View } from "./content/toggle";
export { createViewState } from "./content/viewstate";
export { applyResolved } from "./github/resolved";
export { render, renderError, renderLoading } from "./renderer/render";
export type { DiffV2 } from "./types";
export { createDiffer, type Differ } from "./wasm/differ";
