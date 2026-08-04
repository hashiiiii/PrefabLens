// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { mountToggle } from "./toggle";
import type { View } from "./view-mode";

// Selection sink: a real array, not a spy
function sink() {
  const selected: View[] = [];
  return { selected, onSelect: (view: View) => void selected.push(view) };
}

describe("mountToggle", () => {
  it("starts on Raw and reports selection changes", () => {
    const { selected, onSelect } = sink();
    const toggle = mountToggle(onSelect);
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(raw?.getAttribute("aria-pressed")).toBe("true");
    semantic?.click();
    expect(selected).toEqual(["semantic"]);
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
    raw?.click();
    expect(selected).toEqual(["semantic", "raw"]);
  });

  it("starts on the given initial view", () => {
    // When the persistent default is semantic, a lazy-loaded file's toggle is also born in the semantic pressed state
    const toggle = mountToggle(sink().onSelect, "semantic");
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
  });

  it("updates visuals via set() without firing onSelect", () => {
    // Bulk apply from the global toggle: only the per-file toggle's look follows along, without triggering onSelect's side effect (re-fetch)
    const { selected, onSelect } = sink();
    const toggle = mountToggle(onSelect);
    document.body.append(toggle.element);
    toggle.set("semantic");
    const [, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(selected).toEqual([]);
  });

  it("injects the page stylesheet exactly once", () => {
    mountToggle(sink().onSelect);
    mountToggle(sink().onSelect);
    expect(document.head.querySelectorAll("style[data-prefablens-style]")).toHaveLength(1);
  });

  it("renders as a segmented control styled via aria-pressed", () => {
    const toggle = mountToggle(sink().onSelect);
    expect(toggle.element.classList.contains("prefablens-seg")).toBe(true);
    // No inline style juggling: the selected look is keyed off aria-pressed in CSS
    const [raw] = [...toggle.element.querySelectorAll("button")];
    expect(raw?.getAttribute("style")).toBeNull();
  });
});
