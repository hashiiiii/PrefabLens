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

// Real sinks instead of spies: persisted and notified views land in plain arrays
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
  it("resolves effective view as override-or-default", () => {
    const state = emptyViewState("raw");
    expect(effectiveView(state, "a.prefab")).toBe("raw");
    setOverride(state, "a.prefab", "semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(effectiveView(state, "b.prefab")).toBe("raw"); // an override affects only its target file
  });

  it("setDefault persists, clears overrides, and notifies listeners", () => {
    // The crux of "pressing global always lines up every file": per-file overrides are reset by the global toggle
    const { persisted, notified, persist, listener } = sinks();
    const state = emptyViewState("raw");
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic"]);
    expect(effectiveView(state, "a.prefab")).toBe("semantic"); // the override is cleared
  });

  it("same-value setDefault still clears overrides without persisting", () => {
    // "Pressing global always lines everything up": pressing the already-pressed side again still clears overrides.
    // Only the rewrite to storage is skipped (avoids a wasted onChanged echo)
    const { persisted, notified, persist, listener } = sinks();
    const state = emptyViewState("semantic");
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    setDefault(state, "semantic", persist);
    expect(persisted).toEqual([]);
    expect(notified).toEqual(["semantic"]);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
  });

  it("same-value setDefault with no overrides is a pure no-op", () => {
    // With no overrides, no notification is needed either: a re-apply of every applier is wasted work
    const { persisted, notified, persist, listener } = sinks();
    const state = emptyViewState("semantic");
    onDefaultChange(state, listener);
    setDefault(state, "semantic", persist);
    expect(persisted).toEqual([]);
    expect(notified).toEqual([]);
  });

  it("applyExternal updates without persisting (storage.onChanged echo)", () => {
    // storage.onChanged fires even on the tab that did the set: a re-persist causes an infinite loop
    const { persisted, notified, listener } = sinks();
    const state = emptyViewState("raw");
    onDefaultChange(state, listener);
    setOverride(state, "a.prefab", "raw");
    applyExternal(state, "semantic");
    expect(effectiveView(state, "a.prefab")).toBe("semantic"); // a switch from another tab still lines up every file
    expect(state.def).toBe("semantic");
    expect(persisted).toEqual([]);
    expect(notified).toEqual(["semantic"]);
    notified.length = 0;
    applyExternal(state, "semantic"); // ignore a same-value echo
    expect(notified).toEqual([]);
  });

  it("clearOverrides drops per-file overrides only", () => {
    const state = emptyViewState("semantic");
    setOverride(state, "a.prefab", "raw");
    clearOverrides(state);
    expect(effectiveView(state, "a.prefab")).toBe("semantic");
    expect(state.def).toBe("semantic");
  });
});
