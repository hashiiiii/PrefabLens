import { unresolvedRemaining } from "../../../domain/diff/fn/unresolved-remaining";
import {
  type AuthError,
  type BackgroundError,
  type DiffV2,
  isAuthError,
  type SemanticDiffResponse,
} from "../../../domain/diff/types";
import { must } from "../../../internal/must";
import type { View } from "../../internal/view-mode";

// Per-file raw/semantic state machine (host + fetch latch); unit-testable without a browser.

export type FilePanel = {
  loading(): void;
  diff(json: DiffV2, resolving: number): void;
  incomplete(json: DiffV2, onRetry: () => void): void;
  tooLarge(bytes: number, onForce: () => void): void;
  authError(error: AuthError): void;
  error(error: BackgroundError): void;
};

// Floor of 1: show the spinner even when every name resolved but source merging continues
export function resolvingCount(json: DiffV2): number {
  return Math.max(unresolvedRemaining(json).length, 1);
}

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
  requestDiff(force?: boolean): Promise<SemanticDiffResponse>; // never rejects: the messenger client maps channel loss to fetch-failed
  results: { set(result: FileResult): void; get(): FileResult | undefined; armWatchdog(): void };
  onAuthRetry(retry: () => void): void;
  effectiveView(): View;
};

export type FileViewState = {
  host: FileHost | undefined;
  requested: boolean;
};

export function emptyFileView(): FileViewState {
  return { host: undefined, requested: false };
}

// Display-only: safe on every scan, even while a panel sits on an error
export function syncFileView(state: FileViewState, deps: FileViewDeps, view: View): void {
  if (view === "raw") {
    deps.file.setRawHidden(false);
    state.host?.setVisible(false);
    return;
  }
  if (!state.host) return; // semantic never rendered here: leave the raw diff alone
  deps.file.setRawHidden(true);
  if (!state.host.attached()) state.host.attach(); // react remount can drop the host with the old body
  // Follow github collapse (react); classic uses Details CSS in attachHost instead
  state.host.setVisible(!deps.file.collapsed());
}

function request(state: FileViewState, deps: FileViewDeps, force?: boolean): void {
  state.requested = true;
  const panel = must(state.host).panel; // only reachable after show created the host
  panel.loading();
  void deps.requestDiff(force).then((res) => {
    if (res.ok) {
      deps.results.set({
        json: res.json,
        // Retry re-enters background resolution; reset latch or request() no-ops
        retry: () => {
          state.requested = false;
          request(state, deps, force);
        },
      });
      if (res.pending) deps.results.armWatchdog();
      panel.diff(res.json, res.pending ? resolvingCount(res.json) : 0);
      return;
    }
    state.requested = false; // don't cache errors: next toggle re-fetches
    const prior = deps.results.get();
    if (prior) {
      // Failed retry must not wipe the diff the user is reading
      panel.incomplete(prior.json, prior.retry);
      return;
    }
    if (res.error === "too-large") panel.tooLarge(res.bytes, () => request(state, deps, true));
    else if (isAuthError(res.error)) {
      deps.onAuthRetry(() => {
        // First retry sets requested; duplicate registrations no-op
        if (!state.requested && deps.effectiveView() === "semantic") request(state, deps);
      });
      panel.authError(res.error);
    } else panel.error(res.error);
  });
}

export function showFileView(state: FileViewState, deps: FileViewDeps, view: View): void {
  if (view === "raw") {
    syncFileView(state, deps, view);
    return;
  }
  if (!state.host) {
    state.host = deps.createHost();
    state.host.attach();
  }
  syncFileView(state, deps, view);
  if (state.requested) return; // cache only successful results (re-toggle doesn't re-fetch)
  request(state, deps);
}
