import { describe, expect, it } from "vitest";
import type { ViewMode } from "../../../src/presentation/internal/view-mode";
import {
  applyExternal,
  clearFilesViewMode,
  getDefault,
  resolve,
  setDefault,
  setFileViewMode,
  subscribe,
} from "../../../src/presentation/internal/view-state";

function sinks() {
  const persisted: ViewMode[] = [];
  const notified: ViewMode[] = [];
  return {
    persisted,
    notified,
    persist: (view: ViewMode) => void persisted.push(view),
    listener: (view: ViewMode) => void notified.push(view),
  };
}

describe("view state", () => {
  it("keeps and clears a per-file override", () => {
    const state = getDefault("semantic");
    expect(resolve(state, "a.prefab")).toBe("semantic");

    setFileViewMode(state, "a.prefab", "raw");
    expect(resolve(state, "a.prefab")).toBe("raw");
    expect(resolve(state, "b.prefab")).toBe("semantic");

    clearFilesViewMode(state);
    expect(resolve(state, "a.prefab")).toBe("semantic");
    expect(state.page).toBe("semantic");
  });

  it("realigns files for different-value and same-value global selections", () => {
    const { persisted, notified, persist, listener } = sinks();
    const state = getDefault("raw");
    subscribe(state, listener);
    setFileViewMode(state, "a.prefab", "raw");

    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic"]);
    expect(resolve(state, "a.prefab")).toBe("semantic");

    setFileViewMode(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic", "semantic"]);
    expect(resolve(state, "a.prefab")).toBe("semantic");

    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic", "semantic"]);
  });

  it("applies an external change and ignores its same-value echo", () => {
    const { notified, listener } = sinks();
    const state = getDefault("raw");
    subscribe(state, listener);
    setFileViewMode(state, "a.prefab", "raw");

    applyExternal(state, "semantic");
    expect(state.page).toBe("semantic");
    expect(resolve(state, "a.prefab")).toBe("semantic");
    expect(notified).toEqual(["semantic"]);

    notified.length = 0;
    applyExternal(state, "semantic");
    expect(notified).toEqual([]);
  });

  it("stops default notifications after unsubscribe", () => {
    const { notified, persist, listener } = sinks();
    const state = getDefault("raw");
    const unsubscribe = subscribe(state, listener);

    setDefault(state, "semantic", persist);
    unsubscribe();
    setDefault(state, "raw", persist);

    expect(notified).toEqual(["semantic"]);
  });
});
