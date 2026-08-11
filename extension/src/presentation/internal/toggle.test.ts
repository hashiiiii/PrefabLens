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
  it("starts on Raw and reports one user selection", () => {
    const { selected, onSelect } = sink();
    const toggle = mountToggle(onSelect);
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(raw?.getAttribute("aria-pressed")).toBe("true");
    semantic?.click();
    expect(selected).toEqual(["semantic"]);
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
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
    // Bulk apply from the global toggle: only the look of the per-file toggle follows, and onSelect's side effect (re-fetch) does not fire
    const { selected, onSelect } = sink();
    const toggle = mountToggle(onSelect);
    document.body.append(toggle.element);
    toggle.set("semantic");
    const [, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(selected).toEqual([]);
  });
});
