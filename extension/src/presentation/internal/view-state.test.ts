import { describe, expect, it } from "vitest";
import type { View } from "./view-mode";
import {
  applyExternal,
  clearOverrides,
  effectiveView,
  emptyViewState,
  onDefaultChange,
  setDefault,
  setOverride,
} from "./view-state";

function sinks() {
  const persisted: View[] = [];
  const notified: View[] = [];
  return {
    persisted,
    notified,
    persist: (view: View) => void persisted.push(view),
    listener: (view: View) => void notified.push(view),
  };
}

describe("view state", () => {
  it("keeps and clears a per-file override", () => {
    const state = emptyViewState("raw");
    expect(effectiveView(state, "a.prefab")).toBe("raw");

    setOverride(state, "a.prefab", "semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(effectiveView(state, "b.prefab")).toBe("raw");

    clearOverrides(state);
    expect(effectiveView(state, "a.prefab")).toBe("raw");
    expect(state.def).toBe("raw");
  });

  it("realigns files for different-value and same-value global selections", () => {
    const { persisted, notified, persist, listener } = sinks();
    const state = emptyViewState("raw");
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");

    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic"]);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");

    setOverride(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic", "semantic"]);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");

    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic", "semantic"]);
  });

  it("applies an external change and ignores its same-value echo", () => {
    const { persisted, notified, listener } = sinks();
    const state = emptyViewState("raw");
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");

    applyExternal(state, "semantic");
    expect(state.def).toBe("semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(persisted).toEqual([]);
    expect(notified).toEqual(["semantic"]);

    notified.length = 0;
    applyExternal(state, "semantic");
    expect(notified).toEqual([]);
  });
});
