import type { DiffV2 } from "../types";

// json is mutated in place by the push listener (merge resolved / replace on the final push)
export type ViewEntry = {
  root: ShadowRoot;
  json: DiffV2;
  /** Re-requests this file's semantic diff (incomplete-resolution affordance). */
  retry(): void;
  /** Timer that flips the view to the incomplete state if the final push never arrives. */
  watchdog?: number;
};

export type ViewRegistry = {
  set(key: string, entry: ViewEntry): void;
  get(key: string): ViewEntry | undefined;
  pruneDisconnected(): void;
};

/** path-keyed render targets: when a push (guidResolved) arrives, the matching entry re-renders. */
export function createViewRegistry(): ViewRegistry {
  const views = new Map<string, ViewEntry>();
  return {
    set: (key, entry) => void views.set(key, entry),
    get: (key) => views.get(key),
    // Views killed by an SPA navigation: not only ignore late pushes to them, but also cut the reference
    pruneDisconnected() {
      for (const [key, view] of views) if (!view.root.host.isConnected) views.delete(key);
    },
  };
}
