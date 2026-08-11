import { mergeResolvedPush } from "../../../domain/diff/fn/merge-resolved-push";
import { targetKey } from "../../../domain/diff/fn/target-key";
import { unresolvedRemaining } from "../../../domain/diff/fn/unresolved-remaining";
import type { DiffTarget, DiffV2, GuidResolvedPush } from "../../../domain/diff/types";
import { render } from "../../internal/render";

export type ViewEntry = {
  root: ShadowRoot;
  json: DiffV2;
  retry(): void;
  watchdog?: number;
};

export type ViewRegistry = Map<string, ViewEntry>;

const WATCHDOG_MS = 120_000;

export function viewKey(owner: string, repo: string, target: DiffTarget, path: string): string {
  return `${targetKey(owner, repo, target)}:${path}`;
}

export function armViewWatchdog(view: ViewEntry): void {
  clearTimeout(view.watchdog);
  view.watchdog = window.setTimeout(() => {
    void render(view.root, view.json, { incomplete: true }).then(() => view.retry());
  }, WATCHDOG_MS);
}

export function applyGuidResolvedPush(view: ViewEntry, message: GuidResolvedPush): void {
  clearTimeout(view.watchdog);
  view.json = mergeResolvedPush(view.json, message);
  if (message.done && message.status !== undefined && message.status !== "complete") {
    void render(view.root, view.json, { incomplete: true }).then(() => view.retry());
    return;
  }
  if (!message.done) armViewWatchdog(view);
  void render(view.root, view.json, {
    resolving: message.done ? 0 : Math.max(unresolvedRemaining(view.json).length, 1),
  });
}

// Remove detached roots so late pushes cannot render after SPA navigation.
export function pruneDisconnectedViews(views: ViewRegistry): void {
  for (const [key, view] of views) {
    if (view.root.host.isConnected) continue;
    clearTimeout(view.watchdog);
    views.delete(key);
  }
}
