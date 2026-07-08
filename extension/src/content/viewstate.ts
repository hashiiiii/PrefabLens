import type { View } from "./toggle";

export type ViewState = {
  defaultView(): View;
  effective(path: string): View;
  setOverride(path: string, view: View): void;
  clearOverrides(): void;
  setDefault(view: View): void;
  applyExternal(view: View): void;
  onDefaultChange(fn: (view: View) => void): void;
};

/** Default mode (persistent) + per-file overrides while on the page. A global switch always resets the overrides. */
export function createViewState(initial: View, persist: (view: View) => void): ViewState {
  let def = initial;
  const overrides = new Map<string, View>();
  const listeners: Array<(view: View) => void> = [];
  const change = (view: View): void => {
    def = view;
    overrides.clear();
    for (const fn of listeners) fn(view);
  };
  return {
    defaultView: () => def,
    effective: (path) => overrides.get(path) ?? def,
    setOverride: (path, view) => void overrides.set(path, view),
    clearOverrides: () => overrides.clear(),
    setDefault: (view) => {
      if (view === def) {
        // Even a same-value click keeps "pressing global always lines everything up": clear overrides and re-apply, but don't write to storage
        if (overrides.size) change(view);
        return;
      }
      change(view);
      persist(view);
    },
    // storage.onChanged fires even on the originating set tab, so ignore a same value and don't persist
    applyExternal: (view) => {
      if (view !== def) change(view);
    },
    onDefaultChange: (fn) => void listeners.push(fn),
  };
}
