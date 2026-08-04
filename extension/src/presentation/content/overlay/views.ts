import type { DiffV2 } from "../../../domain/diff/types";

// json is mutated in place by the push listener (merge resolved / replace on final push)
export type ViewEntry = {
  root: ShadowRoot;
  json: DiffV2;
  retry(): void; // re-request semantic diff (incomplete-resolution affordance)
  watchdog?: number; // flips to incomplete if the final push never arrives
};

// path-keyed render targets for guidResolved pushes
export type ViewRegistry = Map<string, ViewEntry>;

// SPA navigation: drop refs so late pushes can't revive dead views
export function pruneDisconnectedViews(views: ViewRegistry): void {
  for (const [key, view] of views) {
    if (view.root.host.isConnected) continue;
    clearTimeout(view.watchdog); // orphaned timer must not render into a detached root
    views.delete(key);
  }
}
