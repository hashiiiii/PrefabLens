// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { createToggle } from "./toggle";

describe("createToggle", () => {
  it("starts on Raw and reports selection changes", () => {
    const onSelect = vi.fn();
    const toggle = createToggle(onSelect);
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(raw?.getAttribute("aria-pressed")).toBe("true");
    semantic?.click();
    expect(onSelect).toHaveBeenCalledWith("semantic");
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
    raw?.click();
    expect(onSelect).toHaveBeenLastCalledWith("raw");
  });

  it("starts on the given initial view", () => {
    // When the persistent default is semantic, a lazy-loaded file's toggle is also born in the semantic pressed state
    const toggle = createToggle(vi.fn(), "semantic");
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
  });

  it("updates visuals via set() without firing onSelect", () => {
    // Bulk apply from the global toggle: only the per-file toggle's look follows along, without triggering onSelect's side effect (re-fetch)
    const onSelect = vi.fn();
    const toggle = createToggle(onSelect);
    document.body.append(toggle.element);
    toggle.set("semantic");
    const [, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(onSelect).not.toHaveBeenCalled();
  });
});
