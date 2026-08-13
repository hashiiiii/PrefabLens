import type { View } from "./view-mode";

export type ViewStateData = {
  def: View;
  overrides: Map<string, View>;
  listeners: Set<(view: View) => void>;
};

// The persistent default plus per-file overrides. A global switch always clears overrides.
export function emptyViewState(initial: View): ViewStateData {
  return { def: initial, overrides: new Map(), listeners: new Set() };
}

export function effectiveView(state: ViewStateData, path: string): View {
  return state.overrides.get(path) ?? state.def;
}

export function setOverride(state: ViewStateData, path: string, view: View): void {
  state.overrides.set(path, view);
}

export function clearOverrides(state: ViewStateData): void {
  state.overrides.clear();
}

function change(state: ViewStateData, view: View): void {
  state.def = view;
  state.overrides.clear();
  for (const fn of state.listeners) fn(view);
}

export function setDefault(state: ViewStateData, view: View, persist: (view: View) => void): void {
  if (view === state.def) {
    // A same-value click still realigns: clear overrides and re-apply, but do not persist
    if (state.overrides.size) change(state, view);
    return;
  }
  change(state, view);
  persist(view);
}

// storage.onChanged also fires on the originating tab. Ignore the same value and do not persist.
export function applyExternal(state: ViewStateData, view: View): void {
  if (view !== state.def) change(state, view);
}

export function subscribeDefault(state: ViewStateData, fn: (view: View) => void): () => void {
  state.listeners.add(fn);
  return () => state.listeners.delete(fn);
}
