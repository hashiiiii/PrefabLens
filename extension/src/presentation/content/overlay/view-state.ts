import type { View } from "./view-mode";

export type ViewStateData = {
  def: View;
  overrides: Map<string, View>;
  listeners: Array<(view: View) => void>;
};

// Persistent default + per-file overrides; a global switch always clears overrides
export function emptyViewState(initial: View): ViewStateData {
  return { def: initial, overrides: new Map(), listeners: [] };
}

export function defaultView(state: ViewStateData): View {
  return state.def;
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
    // Same-value click still realigns: clear overrides and re-apply, but don't persist
    if (state.overrides.size) change(state, view);
    return;
  }
  change(state, view);
  persist(view);
}

// storage.onChanged also fires on the originating tab; ignore same value, don't persist
export function applyExternal(state: ViewStateData, view: View): void {
  if (view !== state.def) change(state, view);
}

export function onDefaultChange(state: ViewStateData, fn: (view: View) => void): void {
  state.listeners.push(fn);
}
