// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { GuidResolvedPush } from "../../../application/gateway/messenger";
import { emptyDiff } from "../../../domain/diff/types";
import { applyGuidResolvedPush, pruneDisconnectedViews, type ViewEntry, type ViewRegistry } from "./views";

const DIFF = emptyDiff();
const at = {
  type: "guidResolved",
  owner: "o",
  repo: "r",
  target: { kind: "pull", prNumber: 1 },
  path: "A.prefab",
} as const;

function viewEntry(json: ViewEntry["json"]): ViewEntry {
  const host = document.createElement("div");
  return { root: host.attachShadow({ mode: "open" }), json, retry: () => {} };
}

describe("resolved pushes", () => {
  it("merges resolved names on an intermediate push without touching the tree", () => {
    const current = { ...emptyDiff(), unresolvedGuids: ["g1", "g2"], resolved: { g1: "A.prefab" } };
    const view = viewEntry(current);
    const push: GuidResolvedPush = { ...at, resolved: { g2: "B.prefab" }, done: false };

    applyGuidResolvedPush(view, push);

    expect(view.json.resolved).toEqual({ g1: "A.prefab", g2: "B.prefab" });
    expect(view.json.roots).toBe(current.roots);
    clearTimeout(view.watchdog);
  });

  it("replaces the whole diff when the final push carries json", () => {
    const current = { ...emptyDiff(), unresolvedGuids: ["g1"] };
    const reshaped = { ...emptyDiff(), unresolvedGuids: [] };
    const view = viewEntry(current);
    const push: GuidResolvedPush = { ...at, resolved: {}, json: reshaped, done: true, status: "complete" };

    applyGuidResolvedPush(view, push);

    expect(view.json).toBe(reshaped);
  });
});

describe("view registry", () => {
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
