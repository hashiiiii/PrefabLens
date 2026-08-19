import { describe, expect, it } from "vitest";
import type { ViewMode } from "../../../src/presentation/internal/view-mode";
import { createViewState } from "../../../src/presentation/internal/view-state";

describe("view state", () => {
  it("getFile uses the page default when the file has no override", () => {
    const state = createViewState("semantic", () => {});
    expect(state.getFile("a.prefab")).toBe("semantic");
  });

  it("setFile overrides the page default for that path only", () => {
    const state = createViewState("semantic", () => {});
    state.setFile("a.prefab", "raw");
    expect(state.getFile("a.prefab")).toBe("raw");
    expect(state.getFile("b.prefab")).toBe("semantic");
  });

  it("clearFiles drops overrides and keeps the page default", () => {
    const state = createViewState("semantic", () => {});
    state.setFile("a.prefab", "raw");
    state.clearFiles();
    expect(state.getFile("a.prefab")).toBe("semantic");
    expect(state.page).toBe("semantic");
  });

  it("savePage to a new view saves, notifies, and clears overrides", () => {
    const saved: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("raw", (view) => void saved.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.savePage("semantic");

    expect(saved).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic"]);
    expect(state.getFile("a.prefab")).toBe("semantic");
  });

  // A same-value click still realigns files. Save only on a real change.
  it("savePage to the current view still clears overrides and does not save", () => {
    const saved: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void saved.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.savePage("semantic");

    expect(saved).toEqual([]);
    expect(notified).toEqual(["semantic"]);
    expect(state.getFile("a.prefab")).toBe("semantic");
  });

  it("savePage to the current view with no overrides does nothing", () => {
    const saved: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void saved.push(view));
    state.subscribe((view) => void notified.push(view));

    state.savePage("semantic");

    expect(saved).toEqual([]);
    expect(notified).toEqual([]);
  });

  it("setPage changes the page and clears overrides without saving", () => {
    const saved: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("raw", (view) => void saved.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.setPage("semantic");

    expect(state.page).toBe("semantic");
    expect(state.getFile("a.prefab")).toBe("semantic");
    expect(notified).toEqual(["semantic"]);
    expect(saved).toEqual([]);
  });

  // storage.onChanged also fires on the originating tab.
  it("setPage ignores the same value", () => {
    const saved: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void saved.push(view));
    state.subscribe((view) => void notified.push(view));

    state.setPage("semantic");

    expect(notified).toEqual([]);
    expect(saved).toEqual([]);
  });

  it("unsubscribe stops later notifications", () => {
    const notified: ViewMode[] = [];
    const state = createViewState("raw", () => {});
    const unsubscribe = state.subscribe((view) => void notified.push(view));

    state.savePage("semantic");
    unsubscribe();
    state.savePage("raw");

    expect(notified).toEqual(["semantic"]);
  });
});
