import { describe, expect, it, vi } from "vitest";
import {
  applyExternal,
  clearOverrides,
  defaultView,
  effectiveView,
  emptyViewState,
  onDefaultChange,
  setDefault,
  setOverride,
} from "./view-state";

describe("view state", () => {
  it("resolves effective view as override-or-default", () => {
    const state = emptyViewState("raw");
    expect(effectiveView(state, "a.prefab")).toBe("raw");
    setOverride(state, "a.prefab", "semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(effectiveView(state, "b.prefab")).toBe("raw"); // an override affects only its target file
  });

  it("setDefault persists, clears overrides, and notifies listeners", () => {
    // The crux of "pressing global always lines up every file": per-file overrides are reset by the global toggle
    const persist = vi.fn();
    const state = emptyViewState("raw");
    const listener = vi.fn();
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persist).toHaveBeenCalledWith("semantic");
    expect(listener).toHaveBeenCalledWith("semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic"); // the override is cleared
  });

  it("same-value setDefault still clears overrides without persisting", () => {
    // "Pressing global always lines everything up": pressing the already-pressed side again still clears overrides.
    // Only the rewrite to storage is skipped (avoids a wasted onChanged echo)
    const persist = vi.fn();
    const state = emptyViewState("semantic");
    const listener = vi.fn();
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith("semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
  });

  it("same-value setDefault with no overrides is a pure no-op", () => {
    // With no overrides, no notification is needed either: don't wastefully re-apply all appliers
    const persist = vi.fn();
    const state = emptyViewState("semantic");
    const listener = vi.fn();
    onDefaultChange(state, listener);
    setDefault(state, "semantic", persist);
    expect(persist).not.toHaveBeenCalled();
    expect(listener).not.toHaveBeenCalled();
  });

  it("applyExternal updates without persisting (storage.onChanged echo)", () => {
    // storage.onChanged fires even on the tab that did the set: re-persisting would cause an infinite loop
    const persist = vi.fn();
    const state = emptyViewState("raw");
    const listener = vi.fn();
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    applyExternal(state, "semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic"); // a switch from another tab still lines up every file
    expect(defaultView(state)).toBe("semantic");
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith("semantic");
    listener.mockClear();
    applyExternal(state, "semantic"); // ignore a same-value echo
    expect(listener).not.toHaveBeenCalled();
  });

  it("clearOverrides drops per-file overrides only", () => {
    const state = emptyViewState("semantic");
    setOverride(state, "a.prefab", "raw");
    clearOverrides(state);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(defaultView(state)).toBe("semantic");
  });
});
