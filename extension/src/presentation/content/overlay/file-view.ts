import {
  type BackgroundError,
  type DiffV2,
  type SemanticDiffResponse,
  unresolvedRemaining,
} from "../../../domain/diff/types";
import { must } from "../../../domain/must";
import type { View } from "./view-mode";

// Per-file raw/semantic state machine (host + fetch latch); unit-testable without a browser.

export type FilePanel = {
  loading(): void;
  diff(json: DiffV2, resolving: number): void;
  incomplete(json: DiffV2, onRetry: () => void): void;
  tooLarge(bytes: number, onForce: () => void): void;
  authError(error: "access-token-missing" | "auth-failed"): void;
  error(error: BackgroundError): void;
};

export type FileHost = {
  attach(): void;
  attached(): boolean;
  setVisible(visible: boolean): void;
  panel: FilePanel;
};

// Push-target slot: index.ts adapts onto the view registry (guidResolved + watchdog)
export type FileResult = { json: DiffV2; retry(): void };

export type FileViewDeps = {
  file: { setRawHidden(hidden: boolean): void; collapsed(): boolean };
  createHost(): FileHost;
  requestDiff(force?: boolean): Promise<SemanticDiffResponse>; // must never reject: callers map channel loss to fetch-failed
  results: { set(result: FileResult): void; get(): FileResult | undefined; armWatchdog(): void };
  onAuthRetry(retry: () => void): void;
  effectiveView(): View;
};

export type FileView = {
  show(view: View): void; // may create host + fetch
  sync(view: View): void; // display-only; never fetches
};

export function createFileView(deps: FileViewDeps): FileView {
  let host: FileHost | undefined;
  // Success stays latched (re-toggle doesn't re-fetch); failures reset
  let requested = false;

  // Display-only: safe on every scan, even while a panel sits on an error
  const sync = (view: View): void => {
    if (view === "raw") {
      deps.file.setRawHidden(false);
      host?.setVisible(false);
      return;
    }
    if (!host) return; // semantic never rendered here: leave the raw diff alone
    deps.file.setRawHidden(true);
    if (!host.attached()) host.attach(); // react remount can drop the host with the old body
    // Follow github collapse (react); classic uses Details CSS in attachHost instead
    host.setVisible(!deps.file.collapsed());
  };

  const request = (force?: boolean): void => {
    requested = true;
    const panel = must(host).panel; // only reachable after show created the host
    panel.loading();
    void deps.requestDiff(force).then((res) => {
      if (res.ok) {
        deps.results.set({
          json: res.json,
          // Retry re-enters background resolution; reset latch or request() no-ops
          retry: () => {
            requested = false;
            request(force);
          },
        });
        if (res.pending) deps.results.armWatchdog();
        // Show while pending even if names are resolved (source merging may remain)
        panel.diff(res.json, res.pending ? Math.max(unresolvedRemaining(res.json).length, 1) : 0);
        return;
      }
      requested = false; // don't cache errors: next toggle re-fetches
      const prior = deps.results.get();
      if (prior) {
        // Failed retry must not wipe the diff the user is reading
        panel.incomplete(prior.json, prior.retry);
        return;
      }
      if (res.error === "too-large") panel.tooLarge(res.bytes, () => request(true));
      else if (res.error === "access-token-missing" || res.error === "auth-failed") {
        deps.onAuthRetry(() => {
          // First retry sets requested; duplicate registrations no-op
          if (!requested && deps.effectiveView() === "semantic") request();
        });
        panel.authError(res.error);
      } else panel.error(res.error);
    });
  };

  const show = (view: View): void => {
    if (view === "raw") {
      sync(view);
      return;
    }
    if (!host) {
      host = deps.createHost();
      host.attach();
    }
    sync(view);
    if (requested) return; // cache only successful results (re-toggle doesn't re-fetch)
    request();
  };

  return { show, sync };
}
