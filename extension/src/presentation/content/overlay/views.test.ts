// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { DiffV2 } from "../../../domain/diff/types";
import { emptyViewRegistry, getView, pruneDisconnectedViews, setView } from "./views";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };

/** Builds a shadow root the way attachToggle does; connected controls whether the host is in the DOM. */
function makeRoot(connected: boolean): ShadowRoot {
  const host = document.createElement("div");
  if (connected) document.body.append(host);
  return host.attachShadow({ mode: "open" });
}

describe("view registry", () => {
  it("returns stored entries by key and misses unknown keys", () => {
    const views = emptyViewRegistry();
    const entry = { root: makeRoot(true), json: DIFF, retry: () => {} };
    setView(views, "o/r#1:Assets/Foo.prefab", entry);
    expect(getView(views, "o/r#1:Assets/Foo.prefab")).toBe(entry);
    expect(getView(views, "o/r#2:Assets/Foo.prefab")).toBeUndefined();
  });

  it("prunes views whose host left the DOM and keeps live ones", () => {
    // An SPA navigation swaps the diff DOM out from under us: pruning both ignores
    // late pushes aimed at the dead view and cuts the reference so it can be collected.
    const views = emptyViewRegistry();
    const liveHost = document.createElement("div");
    document.body.append(liveHost);
    const live = { root: liveHost.attachShadow({ mode: "open" }), json: DIFF, retry: () => {} };
    const dead = { root: makeRoot(false), json: DIFF, retry: () => {} };
    setView(views, "live", live);
    setView(views, "dead", dead);
    pruneDisconnectedViews(views);
    expect(getView(views, "live")).toBe(live);
    expect(getView(views, "dead")).toBeUndefined();
  });

  it("prunes a view that was connected at render time but removed since", () => {
    // The realistic sequence: render while attached, github replaces the container, then prune runs.
    const views = emptyViewRegistry();
    const host = document.createElement("div");
    document.body.append(host);
    setView(views, "k", { root: host.attachShadow({ mode: "open" }), json: DIFF, retry: () => {} });
    host.remove();
    pruneDisconnectedViews(views);
    expect(getView(views, "k")).toBeUndefined();
  });
});
