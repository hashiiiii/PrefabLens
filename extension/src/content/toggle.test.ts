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
    // 永続既定が semantic のとき、遅延ロードで現れたファイルのトグルも semantic 押下状態で生まれる
    const toggle = createToggle(vi.fn(), "semantic");
    document.body.append(toggle.element);
    const [raw, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(raw?.getAttribute("aria-pressed")).toBe("false");
  });

  it("updates visuals via set() without firing onSelect", () => {
    // 全体トグルからの一括適用: 個別トグルの見た目だけ追随させ、onSelect の副作用(再フェッチ)は起こさない
    const onSelect = vi.fn();
    const toggle = createToggle(onSelect);
    document.body.append(toggle.element);
    toggle.set("semantic");
    const [, semantic] = [...toggle.element.querySelectorAll("button")];
    expect(semantic?.getAttribute("aria-pressed")).toBe("true");
    expect(onSelect).not.toHaveBeenCalled();
  });
});
