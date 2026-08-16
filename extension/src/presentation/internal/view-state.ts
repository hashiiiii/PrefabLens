import type { ViewMode } from "./view-mode";

export type ViewState = {
  page: ViewMode;
  files: Map<string, ViewMode>;
  listeners: Set<(file: ViewMode) => void>;
};

export function getDefault(page: ViewMode): ViewState {
  return { page: page, files: new Map(), listeners: new Set() };
}

export function resolve(state: ViewState, path: string): ViewMode {
  return state.files.get(path) ?? state.page;
}

export function setFileViewMode(state: ViewState, path: string, file: ViewMode): void {
  state.files.set(path, file);
}

export function clearFilesViewMode(state: ViewState): void {
  state.files.clear();
}

function change(state: ViewState, page: ViewMode): void {
  state.page = page;
  state.files.clear();
  for (const fn of state.listeners) fn(page);
}

export function setDefault(state: ViewState, view: ViewMode, persist: (view: ViewMode) => void): void {
  if (view === state.page) {
    // A same-value click still realigns: clear overrides and re-apply, but do not persist
    if (state.files.size) change(state, view);
    return;
  }
  change(state, view);
  persist(view);
}

// storage.onChanged also fires on the originating tab. Ignore the same value and do not persist.
export function applyExternal(state: ViewState, view: ViewMode): void {
  if (view !== state.page) change(state, view);
}

export function subscribe(state: ViewState, fn: (page: ViewMode) => void): () => void {
  state.listeners.add(fn);
  return () => state.listeners.delete(fn);
}
