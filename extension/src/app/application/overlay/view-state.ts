import type { View } from "./view-mode";

export type ViewState = {
  defaultView(): View;
  effective(path: string): View;
  setOverride(path: string, view: View): void;
  clearOverrides(): void;
  setDefault(view: View): void;
  applyExternal(view: View): void;
  onDefaultChange(fn: (view: View) => void): void;
};

// Persistent default + per-file overrides; a global switch always clears overrides
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
        // Same-value click still realigns: clear overrides and re-apply, but don't persist
        if (overrides.size) change(view);
        return;
      }
      change(view);
      persist(view);
    },
    // storage.onChanged also fires on the originating tab; ignore same value, don't persist
    applyExternal: (view) => {
      if (view !== def) change(view);
    },
    onDefaultChange: (fn) => void listeners.push(fn),
  };
}
