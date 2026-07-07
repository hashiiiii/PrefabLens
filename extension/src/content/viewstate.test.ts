import { describe, expect, it, vi } from "vitest";
import { createViewState } from "./viewstate";

describe("createViewState", () => {
  it("resolves effective view as override-or-default", () => {
    const state = createViewState("raw", vi.fn());
    expect(state.effective("a.prefab")).toBe("raw");
    state.setOverride("a.prefab", "semantic");
    expect(state.effective("a.prefab")).toBe("semantic");
    expect(state.effective("b.prefab")).toBe("raw"); // an override affects only its target file
  });

  it("setDefault persists, clears overrides, and notifies listeners", () => {
    // The crux of "pressing global always lines up every file": per-file overrides are reset by the global toggle
    const persist = vi.fn();
    const state = createViewState("raw", persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride("a.prefab", "raw");
    state.setDefault("semantic");
    expect(persist).toHaveBeenCalledWith("semantic");
    expect(listener).toHaveBeenCalledWith("semantic");
    expect(state.effective("a.prefab")).toBe("semantic"); // the override is cleared
  });

  it("same-value setDefault still clears overrides without persisting", () => {
    // "Pressing global always lines everything up": pressing the already-pressed side again still clears overrides.
    // Only the rewrite to storage is skipped (avoids a wasted onChanged echo)
    const persist = vi.fn();
    const state = createViewState("semantic", persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride("a.prefab", "raw");
    state.setDefault("semantic");
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith("semantic");
    expect(state.effective("a.prefab")).toBe("semantic");
  });

  it("same-value setDefault with no overrides is a pure no-op", () => {
    // With no overrides, no notification is needed either: don't wastefully re-apply all appliers
    const persist = vi.fn();
    const state = createViewState("semantic", persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setDefault("semantic");
    expect(persist).not.toHaveBeenCalled();
    expect(listener).not.toHaveBeenCalled();
  });

  it("applyExternal updates without persisting (storage.onChanged echo)", () => {
    // storage.onChanged fires even on the tab that did the set: re-persisting would cause an infinite loop
    const persist = vi.fn();
    const state = createViewState("raw", persist);
    const listener = vi.fn();
    state.onDefaultChange(listener);
    state.setOverride("a.prefab", "raw");
    state.applyExternal("semantic");
    expect(state.effective("a.prefab")).toBe("semantic"); // a switch from another tab still lines up every file
    expect(state.defaultView()).toBe("semantic");
    expect(persist).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith("semantic");
    listener.mockClear();
    state.applyExternal("semantic"); // ignore a same-value echo
    expect(listener).not.toHaveBeenCalled();
  });

  it("clearOverrides drops per-file overrides only", () => {
    const state = createViewState("semantic", vi.fn());
    state.setOverride("a.prefab", "raw");
    state.clearOverrides();
    expect(state.effective("a.prefab")).toBe("semantic");
    expect(state.defaultView()).toBe("semantic");
  });
});
