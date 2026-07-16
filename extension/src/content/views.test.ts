// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { DiffV2 } from "../types";
import { createViewRegistry } from "./views";

const DIFF: DiffV2 = { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] };

/** Builds a shadow root the way attachToggle does; connected controls whether the host is in the DOM. */
function makeRoot(connected: boolean): ShadowRoot {
  const host = document.createElement("div");
  if (connected) document.body.append(host);
  return host.attachShadow({ mode: "open" });
}

describe("createViewRegistry", () => {
  it("returns stored entries by key and misses unknown keys", () => {
    const views = createViewRegistry();
    const entry = { root: makeRoot(true), json: DIFF };
    views.set("o/r#1:Assets/Foo.prefab", entry);
    expect(views.get("o/r#1:Assets/Foo.prefab")).toBe(entry);
    expect(views.get("o/r#2:Assets/Foo.prefab")).toBeUndefined();
  });

  it("prunes views whose host left the DOM and keeps live ones", () => {
    // An SPA navigation swaps the diff DOM out from under us: pruning both ignores
    // late pushes aimed at the dead view and cuts the reference so it can be collected.
    const views = createViewRegistry();
    const liveHost = document.createElement("div");
    document.body.append(liveHost);
    const live = { root: liveHost.attachShadow({ mode: "open" }), json: DIFF };
    const dead = { root: makeRoot(false), json: DIFF };
    views.set("live", live);
    views.set("dead", dead);
    views.pruneDisconnected();
    expect(views.get("live")).toBe(live);
    expect(views.get("dead")).toBeUndefined();
  });

  it("prunes a view that was connected at render time but removed since", () => {
    // The realistic sequence: render while attached, github replaces the container, then prune runs.
    const views = createViewRegistry();
    const host = document.createElement("div");
    document.body.append(host);
    views.set("k", { root: host.attachShadow({ mode: "open" }), json: DIFF });
    host.remove();
    views.pruneDisconnected();
    expect(views.get("k")).toBeUndefined();
  });
});
