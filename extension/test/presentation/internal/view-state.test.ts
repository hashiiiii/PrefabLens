import { describe, expect, it } from "vitest";
import type { View } from "../../../src/presentation/internal/view-mode";
import {
  applyExternal,
  clearOverrides,
  effectiveView,
  emptyViewState,
  setDefault,
  setOverride,
  subscribeDefault,
} from "../../../src/presentation/internal/view-state";

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
    const state = emptyViewState("semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");

    setOverride(state, "a.prefab", "raw");
    expect(effectiveView(state, "a.prefab")).toBe("raw");
    expect(effectiveView(state, "b.prefab")).toBe("semantic");

    clearOverrides(state);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(state.def).toBe("semantic");
  });

  it("realigns files for different-value and same-value global selections", () => {
    const { persisted, notified, persist, listener } = sinks();
    const state = emptyViewState("raw");
    subscribeDefault(state, listener);
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
    const { notified, listener } = sinks();
    const state = emptyViewState("raw");
    subscribeDefault(state, listener);
    setOverride(state, "a.prefab", "raw");

    applyExternal(state, "semantic");
    expect(state.def).toBe("semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(notified).toEqual(["semantic"]);

    notified.length = 0;
    applyExternal(state, "semantic");
    expect(notified).toEqual([]);
  });

  it("stops default notifications after unsubscribe", () => {
    const { notified, persist, listener } = sinks();
    const state = emptyViewState("raw");
    const unsubscribe = subscribeDefault(state, listener);

    setDefault(state, "semantic", persist);
    unsubscribe();
    setDefault(state, "raw", persist);

    expect(notified).toEqual(["semantic"]);
  });
});
