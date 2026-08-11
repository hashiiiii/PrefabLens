// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { emptyDiff } from "../../../domain/diff/types";
import { pruneDisconnectedViews, type ViewRegistry } from "./views";

const DIFF = emptyDiff();

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
