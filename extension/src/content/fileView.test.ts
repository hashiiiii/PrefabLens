import { describe, expect, it } from "vitest";
import type { DiffV2, SemanticDiffResponse } from "../types";
import { must } from "../util/must";
import { createFileView, type FileResult } from "./fileView";
import type { View } from "./toggle";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };

/** What the panel last drew, as plain data (a real sink, not a spy). */
type Screen =
  | { kind: "loading" }
  | { kind: "diff"; json: DiffV2; resolving: number }
  | { kind: "incomplete"; json: DiffV2; onRetry(): void }
  | { kind: "tooLarge"; bytes: number; onForce(): void }
  | { kind: "authError"; error: string }
  | { kind: "error"; error: string };

/** requestDiff resolves on the microtask queue; a macrotask flushes every chained then. */
const flush = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

/** In-memory implementations of every FileViewDeps interface: each object really stores
 *  the state the machine drives, so assertions read state instead of call recordings. */
function makeHarness() {
  const file = {
    rawHidden: false,
    isCollapsed: false,
    setRawHidden(hidden: boolean) {
      file.rawHidden = hidden;
    },
    collapsed: () => file.isCollapsed,
  };
  const host = {
    created: false,
    attachCount: 0,
    connected: false,
    visible: undefined as boolean | undefined,
    screens: [] as Screen[],
  };
  // Responses are consumed in order; requests records the force flag of each round-trip.
  const responses: SemanticDiffResponse[] = [];
  const requests: Array<boolean | undefined> = [];
  const results = {
    current: undefined as FileResult | undefined,
    watchdogArmed: 0,
  };
  const authRetries: Array<() => void> = [];
  const state = { effective: "semantic" as View };

  const view = createFileView({
    file,
    createHost() {
      host.created = true;
      return {
        attach() {
          host.attachCount++;
          host.connected = true;
        },
        attached: () => host.connected,
        setVisible(visible) {
          host.visible = visible;
        },
        panel: {
          loading: () => void host.screens.push({ kind: "loading" }),
          diff: (json, resolving) => void host.screens.push({ kind: "diff", json, resolving }),
          incomplete: (json, onRetry) => void host.screens.push({ kind: "incomplete", json, onRetry }),
          tooLarge: (bytes, onForce) => void host.screens.push({ kind: "tooLarge", bytes, onForce }),
          authError: (error) => void host.screens.push({ kind: "authError", error }),
          error: (error) => void host.screens.push({ kind: "error", error }),
        },
      };
    },
    requestDiff(force) {
      requests.push(force);
      return Promise.resolve(must(responses.shift()));
    },
    results: {
      set: (result) => {
        results.current = result;
      },
      get: () => results.current,
      armWatchdog: () => void results.watchdogArmed++,
    },
    onAuthRetry: (retry) => void authRetries.push(retry),
    effectiveView: () => state.effective,
  });

  const screen = (): Screen => must(host.screens.at(-1));
  return { view, file, host, responses, requests, results, authRetries, state, screen };
}

describe("createFileView show", () => {
  it("show(semantic) creates and attaches the host, hides raw, and renders the fetched diff", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF });

    h.view.show("semantic");
    // Transition: no-host + semantic → host created and attached, raw hidden, loading
    // shown synchronously while the request is in flight.
    expect(h.host.created).toBe(true);
    expect(h.host.attachCount).toBe(1);
    expect(h.file.rawHidden).toBe(true);
    expect(h.host.visible).toBe(true);
    expect(h.screen()).toEqual({ kind: "loading" });

    await flush();
    // Transition: success response → diff rendered without the resolving indicator (not
    // pending), and the result registered as a push target.
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF, resolving: 0 });
    expect(h.results.current?.json).toBe(DIFF);
    expect(h.results.watchdogArmed).toBe(0);
  });

  it("show(raw) leaves the raw diff alone and never creates a host or fetches", () => {
    const h = makeHarness();
    h.view.show("raw");
    // Transition: raw is the passive state — nothing to build, nothing to request.
    expect(h.host.created).toBe(false);
    expect(h.requests).toHaveLength(0);
    expect(h.file.rawHidden).toBe(false);
  });

  it("toggling back to semantic reuses the cached result instead of re-fetching", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF });
    h.view.show("semantic");
    await flush();

    h.view.show("raw");
    // Transition: semantic-shown → raw restores the raw diff and hides (not destroys) the host.
    expect(h.file.rawHidden).toBe(false);
    expect(h.host.visible).toBe(false);

    h.view.show("semantic");
    // Transition: requested stays latched after success, so re-showing only re-asserts
    // display — exactly one round-trip ever happened.
    expect(h.requests).toHaveLength(1);
    expect(h.file.rawHidden).toBe(true);
    expect(h.host.visible).toBe(true);
  });

  it("keeps the resolving indicator up while pending, even when every guid already has a name", async () => {
    const h = makeHarness();
    // All names resolved but pending: source merging may still be running in background.
    h.responses.push({
      ok: true,
      json: { ...DIFF, unresolvedGuids: ["g1"], resolved: { g1: "Assets/A.cs" } },
      pending: true,
    });
    h.view.show("semantic");
    await flush();
    // Transition: pending success → indicator floor of 1 and the watchdog armed to catch a lost final push.
    expect(h.screen()).toMatchObject({ kind: "diff", resolving: 1 });
    expect(h.results.watchdogArmed).toBe(1);
  });

  it("counts only guids without a resolved name for the indicator", async () => {
    const h = makeHarness();
    h.responses.push({
      ok: true,
      json: { ...DIFF, unresolvedGuids: ["g1", "g2", "g3"], resolved: { g2: "Assets/B.mat" } },
      pending: true,
    });
    h.view.show("semantic");
    await flush();
    // g2 already resolved via the in-PR meta index: 2 remain (the shared unresolvedRemaining filter).
    expect(h.screen()).toMatchObject({ kind: "diff", resolving: 2 });
  });
});

describe("createFileView sync", () => {
  it("sync(semantic) before any semantic render leaves the raw diff alone", () => {
    const h = makeHarness();
    h.view.sync("semantic");
    // Transition: no host yet → sync must not hide raw (the user would see nothing) and
    // must not fetch (a fetching sync would hammer retries on rate limits).
    expect(h.file.rawHidden).toBe(false);
    expect(h.requests).toHaveLength(0);
  });

  it("sync re-attaches a host dropped by a react remount without re-fetching", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF });
    h.view.show("semantic");
    await flush();

    // A react remount discards the diff body together with our host...
    h.host.connected = false;
    h.file.rawHidden = false;
    h.view.sync("semantic");
    // Transition: display-only re-assert — host re-attached, raw re-hidden, and still
    // exactly one request (sync never fetches).
    expect(h.host.attachCount).toBe(2);
    expect(h.file.rawHidden).toBe(true);
    expect(h.requests).toHaveLength(1);
  });

  it("sync follows github's collapse state for the semantic host", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF });
    h.view.show("semantic");
    await flush();

    h.file.isCollapsed = true;
    h.view.sync("semantic");
    // Transition: collapsed file → semantic host hidden along with github's own body.
    expect(h.host.visible).toBe(false);

    h.file.isCollapsed = false;
    h.view.sync("semantic");
    expect(h.host.visible).toBe(true);
  });

  it("sync(raw) restores the raw diff and hides the semantic host", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF });
    h.view.show("semantic");
    await flush();

    h.view.sync("raw");
    expect(h.file.rawHidden).toBe(false);
    expect(h.host.visible).toBe(false);
  });
});

describe("createFileView request", () => {
  it("does not cache errors: the next semantic show re-fetches", async () => {
    const h = makeHarness();
    h.responses.push({ ok: false, error: "fetch-failed" });
    h.view.show("semantic");
    await flush();
    // Transition: failure with no prior result → plain error panel, requested reset.
    expect(h.screen()).toEqual({ kind: "error", error: "fetch-failed" });

    h.responses.push({ ok: true, json: DIFF });
    h.view.show("semantic");
    await flush();
    // Transition: error was not latched → the second show issues a second request.
    expect(h.requests).toHaveLength(2);
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF });
  });

  it("a failed retry keeps the diff on screen and re-offers retry instead of a bare error", async () => {
    const h = makeHarness();
    h.responses.push({ ok: true, json: DIFF, pending: true });
    h.view.show("semantic");
    await flush();

    // Retry after an incomplete resolution, but the request fails this time.
    h.responses.push({ ok: false, error: "rate-limited" });
    must(h.results.current).retry();
    expect(h.screen()).toEqual({ kind: "loading" });
    await flush();
    // Transition: failure with a prior result → the kept diff plus the retry affordance
    // (never wipe the tree the user is reading).
    expect(h.screen()).toMatchObject({ kind: "incomplete", json: DIFF });

    // The offered retry works: a success replaces the incomplete bar with the diff again.
    h.responses.push({ ok: true, json: DIFF });
    const incomplete = h.screen();
    if (incomplete.kind !== "incomplete") throw new Error("expected incomplete screen");
    incomplete.onRetry();
    await flush();
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF });
    expect(h.requests).toHaveLength(3);
  });

  it("too-large offers force rendering, and retry afterwards keeps the force flag", async () => {
    const h = makeHarness();
    h.responses.push({ ok: false, error: "too-large", bytes: 123 });
    h.view.show("semantic");
    await flush();
    // Transition: too-large → the render-anyway affordance instead of a diff.
    expect(h.screen()).toMatchObject({ kind: "tooLarge", bytes: 123 });

    h.responses.push({ ok: true, json: DIFF, pending: true });
    const tooLarge = h.screen();
    if (tooLarge.kind !== "tooLarge") throw new Error("expected tooLarge screen");
    tooLarge.onForce();
    await flush();
    // Transition: force render → the request repeats with force, bypassing the size guard.
    expect(h.requests).toEqual([undefined, true]);
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF });

    // The registered retry re-runs the whole request with the same force flag: without it
    // the retried request would bounce off the size guard again.
    h.responses.push({ ok: true, json: DIFF });
    must(h.results.current).retry();
    await flush();
    expect(h.requests).toEqual([undefined, true, true]);
  });

  it("an auth error registers a retry that fires only while the file still shows semantic", async () => {
    const h = makeHarness();
    h.responses.push({ ok: false, error: "pat-missing" });
    h.view.show("semantic");
    await flush();
    // Transition: auth failure → sign-in panel plus a retry parked until a token lands.
    expect(h.screen()).toEqual({ kind: "authError", error: "pat-missing" });
    expect(h.authRetries).toHaveLength(1);

    // The user flipped this file to raw before signing in: the token retry must not fetch
    // for a file that no longer shows the semantic view.
    h.state.effective = "raw";
    must(h.authRetries[0])();
    expect(h.requests).toHaveLength(1);

    // Back on semantic, the same parked retry re-requests.
    h.state.effective = "semantic";
    h.responses.push({ ok: true, json: DIFF });
    must(h.authRetries[0])();
    await flush();
    expect(h.requests).toHaveLength(2);
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF });
  });

  it("duplicate auth retries no-op after the first one flips requested back on", async () => {
    const h = makeHarness();
    // Two auth failures in a row (show → error → show again) park two retries.
    h.responses.push({ ok: false, error: "auth-failed" });
    h.view.show("semantic");
    await flush();
    h.responses.push({ ok: false, error: "auth-failed" });
    h.view.show("semantic");
    await flush();
    expect(h.authRetries).toHaveLength(2);

    // A token lands and the flush runs every parked retry: the first re-requests and sets
    // requested, so the second must see requested === true and stay idle (one fetch, not two).
    h.responses.push({ ok: true, json: DIFF });
    for (const retry of h.authRetries) retry();
    await flush();
    expect(h.requests).toHaveLength(3);
    expect(h.screen()).toMatchObject({ kind: "diff", json: DIFF });
  });
});
