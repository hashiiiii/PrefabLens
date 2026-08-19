import { describe, expect, it } from "vitest";
import type { ViewMode } from "../../../src/presentation/internal/view-mode";
import { createViewState } from "../../../src/presentation/internal/view-state";

describe("view state", () => {
  it("resolve uses the page default when the file has no override", () => {
    const state = createViewState("semantic", () => {});
    expect(state.resolve("a.prefab")).toBe("semantic");
  });

  it("setFile overrides the page default for that path only", () => {
    const state = createViewState("semantic", () => {});
    state.setFile("a.prefab", "raw");
    expect(state.resolve("a.prefab")).toBe("raw");
    expect(state.resolve("b.prefab")).toBe("semantic");
  });

  it("clearFiles drops overrides and keeps the page default", () => {
    const state = createViewState("semantic", () => {});
    state.setFile("a.prefab", "raw");
    state.clearFiles();
    expect(state.resolve("a.prefab")).toBe("semantic");
    expect(state.page).toBe("semantic");
  });

  it("setDefault to a new view persists, notifies, and clears overrides", () => {
    const persisted: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("raw", (view) => void persisted.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.setDefault("semantic");

    expect(persisted).toEqual(["semantic"]);
    expect(notified).toEqual(["semantic"]);
    expect(state.resolve("a.prefab")).toBe("semantic");
  });

  // A same-value click still realigns files. Persist only on a real change.
  it("setDefault to the current view still clears overrides and does not persist", () => {
    const persisted: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void persisted.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.setDefault("semantic");

    expect(persisted).toEqual([]);
    expect(notified).toEqual(["semantic"]);
    expect(state.resolve("a.prefab")).toBe("semantic");
  });

  it("setDefault to the current view with no overrides does nothing", () => {
    const persisted: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void persisted.push(view));
    state.subscribe((view) => void notified.push(view));

    state.setDefault("semantic");

    expect(persisted).toEqual([]);
    expect(notified).toEqual([]);
  });

  it("applyExternal changes the page and clears overrides without persisting", () => {
    const persisted: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("raw", (view) => void persisted.push(view));
    state.subscribe((view) => void notified.push(view));
    state.setFile("a.prefab", "raw");

    state.applyExternal("semantic");

    expect(state.page).toBe("semantic");
    expect(state.resolve("a.prefab")).toBe("semantic");
    expect(notified).toEqual(["semantic"]);
    expect(persisted).toEqual([]);
  });

  // storage.onChanged also fires on the originating tab.
  it("applyExternal ignores the same value", () => {
    const persisted: ViewMode[] = [];
    const notified: ViewMode[] = [];
    const state = createViewState("semantic", (view) => void persisted.push(view));
    state.subscribe((view) => void notified.push(view));

    state.applyExternal("semantic");

    expect(notified).toEqual([]);
    expect(persisted).toEqual([]);
  });

  it("unsubscribe stops later notifications", () => {
    const notified: ViewMode[] = [];
    const state = createViewState("raw", () => {});
    const unsubscribe = state.subscribe((view) => void notified.push(view));

    state.setDefault("semantic");
    unsubscribe();
    state.setDefault("raw");

    expect(notified).toEqual(["semantic"]);
  });
});
