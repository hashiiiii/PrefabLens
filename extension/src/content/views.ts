import type { DiffV2 } from "../app/domain/diff/types";

// json is mutated in place by the push listener (merge resolved / replace on final push)
export type ViewEntry = {
  root: ShadowRoot;
  json: DiffV2;
  retry(): void; // re-request semantic diff (incomplete-resolution affordance)
  watchdog?: number; // flips to incomplete if the final push never arrives
};

export type ViewRegistry = {
  set(key: string, entry: ViewEntry): void;
  get(key: string): ViewEntry | undefined;
  pruneDisconnected(): void;
};

// path-keyed render targets for guidResolved pushes
export function createViewRegistry(): ViewRegistry {
  const views = new Map<string, ViewEntry>();
  return {
    set: (key, entry) => void views.set(key, entry),
    get: (key) => views.get(key),
    // SPA navigation: drop refs so late pushes can't revive dead views
    pruneDisconnected() {
      for (const [key, view] of views) {
        if (view.root.host.isConnected) continue;
        clearTimeout(view.watchdog); // orphaned timer must not render into a detached root
        views.delete(key);
      }
    },
  };
}
