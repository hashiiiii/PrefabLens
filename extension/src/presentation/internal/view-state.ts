import type { ViewMode } from "./view-mode";

export type ViewState = {
  readonly page: ViewMode;
  getFile(path: string): ViewMode;
  setFile(path: string, view: ViewMode): void;
  clearFiles(): void;
  savePage(view: ViewMode): void;
  setPage(view: ViewMode): void;
  subscribe(fn: (page: ViewMode) => void): () => void;
};

export function createViewState(page: ViewMode, save: (view: ViewMode) => void): ViewState {
  let current = page;
  const files = new Map<string, ViewMode>();
  const listeners = new Set<(page: ViewMode) => void>();

  const change = (next: ViewMode): void => {
    current = next;
    files.clear();
    for (const fn of listeners) fn(current);
  };

  return {
    get page() {
      return current;
    },
    getFile: (path) => files.get(path) ?? current,
    setFile: (path, view) => {
      files.set(path, view);
    },
    clearFiles: () => files.clear(),
    savePage: (view) => {
      if (view === current) {
        // A same-value click still realigns: clear overrides and re-apply, but do not save
        if (files.size) change(view);
        return;
      }
      change(view);
      save(view);
    },
    // storage.onChanged also fires on the originating tab. Ignore the same value and do not save.
    setPage: (view) => {
      if (view !== current) change(view);
    },
    subscribe: (fn) => {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
  };
}
