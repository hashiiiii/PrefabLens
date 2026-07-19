import { type BackgroundError, type DiffV2, type SemanticDiffResponse, unresolvedRemaining } from "../types";
import { must } from "../util/must";
import type { View } from "./toggle";

/** Rendering surface inside the host's shadow root: the machine picks the screen,
 *  the caller draws it (render/renderLoading/... in content/index.ts). */
export type FilePanel = {
  loading(): void;
  /** The diff tree, with the resolving indicator while `resolving` > 0. */
  diff(json: DiffV2, resolving: number): void;
  /** A kept diff plus the incomplete-resolution bar (manual retry affordance). */
  incomplete(json: DiffV2, onRetry: () => void): void;
  tooLarge(bytes: number, onForce: () => void): void;
  /** Auth-error panel driving the device flow. */
  authError(error: "pat-missing" | "auth-failed"): void;
  error(error: BackgroundError): void;
};

/** The semantic-view host as the machine sees it: layout attach, visibility, its panel. */
export type FileHost = {
  attach(): void;
  attached(): boolean;
  setVisible(visible: boolean): void;
  panel: FilePanel;
};

/** A successful diff registered as a push target (content/index.ts adapts this onto the
 *  view registry, where guidResolved pushes and the watchdog find it). */
export type FileResult = { json: DiffV2; retry(): void };

export type FileViewDeps = {
  /** The pieces of FileEntry the machine drives: raw-diff visibility and collapse state. */
  file: { setRawHidden(hidden: boolean): void; collapsed(): boolean };
  /** Creates the semantic-view host; called once, on the first semantic show. */
  createHost(): FileHost;
  /** Background round-trip for this file's semantic diff (never rejects: the caller maps
   *  channel loss to a fetch-failed response). */
  requestDiff(force?: boolean): Promise<SemanticDiffResponse>;
  /** This file's push-target slot; armWatchdog guards the pending final push. */
  results: { set(result: FileResult): void; get(): FileResult | undefined; armWatchdog(): void };
  /** Registers a retry to run when a token lands in storage (auth-blocked panels). */
  onAuthRetry(retry: () => void): void;
  /** The view currently effective for this file (global default + per-file override). */
  effectiveView(): View;
};

export type FileView = {
  /** User-intent transition: may create the host and fetch the diff. */
  show(view: View): void;
  /** Display-only re-assert of the current view; never fetches. */
  sync(view: View): void;
};

/** Per-file attach/show state machine: which of raw/semantic is displayed, whether the
 *  semantic host exists, and whether a diff request is in flight or cached. Extracted
 *  from content/index.ts so the transitions are unit-testable without a browser. */
export function createFileView(deps: FileViewDeps): FileView {
  let host: FileHost | undefined;
  // A successful request stays latched (re-toggle doesn't re-fetch); failures reset it.
  let requested = false;

  // Display-only re-assert, never fetches: safe to run on every scan even while a panel
  // sits on an error (a fetching sync would silently hammer retries on rate limits).
  const sync = (view: View): void => {
    if (view === "raw") {
      deps.file.setRawHidden(false);
      host?.setVisible(false);
      return;
    }
    if (!host) return; // semantic never rendered here: leave the raw diff alone
    deps.file.setRawHidden(true);
    if (!host.attached()) host.attach(); // a react remount can drop the host together with the old body
    // Follow github's own collapse (react ui): the classic layout handles this via the
    // Details CSS class added in attachHost instead, where collapsed() is always false.
    host.setVisible(!deps.file.collapsed());
  };

  const request = (force?: boolean): void => {
    requested = true;
    const panel = must(host).panel; // request is only reachable after show created the host
    panel.loading();
    void deps.requestDiff(force).then((res) => {
      if (res.ok) {
        deps.results.set({
          json: res.json,
          // Retry re-runs the whole request: the diff itself is cached, so this only
          // re-enters background resolution (requested must reset or request() no-ops).
          retry: () => {
            requested = false;
            request(force);
          },
        });
        if (res.pending) deps.results.armWatchdog();
        // Always show it while pending: even if all names are resolved, source merging may remain
        panel.diff(res.json, res.pending ? Math.max(unresolvedRemaining(res.json).length, 1) : 0);
        return;
      }
      requested = false; // don't cache errors: let the next toggle re-fetch
      const prior = deps.results.get();
      if (prior) {
        // A failed retry must not wipe the diff the user is reading: keep the
        // tree and re-offer the retry affordance instead of a bare error panel.
        panel.incomplete(prior.json, prior.retry);
        return;
      }
      if (res.error === "too-large") panel.tooLarge(res.bytes, () => request(true));
      else if (res.error === "pat-missing" || res.error === "auth-failed") {
        deps.onAuthRetry(() => {
          // requested flips true on the first retry, so duplicate registrations no-op.
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
    if (requested) return; // cache only successful results per file (re-toggle doesn't re-fetch)
    request();
  };

  return { show, sync };
}
