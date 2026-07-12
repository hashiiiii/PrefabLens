// Public surface of the embeddable semantic-diff viewer. `pnpm run viewer`
// builds this entry standalone (dist/viewer.js, global PrefabLensViewer) so
// external consumers like site/ depend on a built artifact with a declared
// API instead of reaching into extension sources.
export { createToggle, injectPageStyles, type View } from "./content/toggle";
export { createViewState } from "./content/viewstate";
export { applyResolved } from "./github/resolved";
export { render, renderError, renderLoading } from "./renderer/render";
export { createDiffer } from "./wasm/differ";
