// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { emptyDiff } from "../../../domain/diff/types";
import { pruneDisconnectedViews, type ViewRegistry } from "./views";

const DIFF = emptyDiff();

/** Builds a shadow root the way attachToggle does; connected controls whether the host is in the DOM. */
function makeRoot(connected: boolean): ShadowRoot {
  const host = document.createElement("div");
  if (connected) document.body.append(host);
  return host.attachShadow({ mode: "open" });
}

describe("view registry", () => {
  it("prunes views whose host left the DOM and keeps live ones", () => {
    // An SPA navigation swaps the diff DOM out from under us: pruning both ignores
    // late pushes aimed at the dead view and cuts the reference so it can be collected.
    const views: ViewRegistry = new Map();
    const live = { root: makeRoot(true), json: DIFF, retry: () => {} };
    const dead = { root: makeRoot(false), json: DIFF, retry: () => {} };
    views.set("live", live);
    views.set("dead", dead);
    pruneDisconnectedViews(views);
    expect(views.get("live")).toBe(live);
    expect(views.get("dead")).toBeUndefined();
  });

  it("prunes a view that was connected at render time but removed since", () => {
    // The realistic sequence: render while attached, github replaces the container, then prune runs.
    const views: ViewRegistry = new Map();
    const host = document.createElement("div");
    document.body.append(host);
    views.set("k", { root: host.attachShadow({ mode: "open" }), json: DIFF, retry: () => {} });
    host.remove();
    pruneDisconnectedViews(views);
    expect(views.get("k")).toBeUndefined();
  });
});
