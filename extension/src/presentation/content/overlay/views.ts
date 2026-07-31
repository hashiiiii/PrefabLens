import type { DiffV2 } from "../../../domain/diff/types";

// json is mutated in place by the push listener (merge resolved / replace on final push)
export type ViewEntry = {
  root: ShadowRoot;
  json: DiffV2;
  retry(): void; // re-request semantic diff (incomplete-resolution affordance)
  watchdog?: number; // flips to incomplete if the final push never arrives
};

export type ViewRegistryState = { views: Map<string, ViewEntry> };

// path-keyed render targets for guidResolved pushes
export function emptyViewRegistry(): ViewRegistryState {
  return { views: new Map() };
}

export function setView(state: ViewRegistryState, key: string, entry: ViewEntry): void {
  state.views.set(key, entry);
}

export function getView(state: ViewRegistryState, key: string): ViewEntry | undefined {
  return state.views.get(key);
}

// SPA navigation: drop refs so late pushes can't revive dead views
export function pruneDisconnectedViews(state: ViewRegistryState): void {
  for (const [key, view] of state.views) {
    if (view.root.host.isConnected) continue;
    clearTimeout(view.watchdog); // orphaned timer must not render into a detached root
    state.views.delete(key);
  }
}
