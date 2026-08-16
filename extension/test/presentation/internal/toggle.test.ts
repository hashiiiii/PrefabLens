// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { mountToggle } from "../../../src/presentation/internal/toggle";
import type { ViewMode } from "../../../src/presentation/internal/view-mode";

describe("mountToggle", () => {
  beforeEach(() => {
    document.head.replaceChildren();
    document.body.replaceChildren();
  });

  it("notifies subscribers until they unsubscribe", () => {
    const selected: ViewMode[] = [];
    const toggle = mountToggle("raw");
    const unsubscribe = toggle.subscribe((view) => void selected.push(view));
    document.body.append(toggle.element);

    toggle.element.querySelector<HTMLButtonElement>('button[data-view="semantic"]')?.click();
    unsubscribe();
    toggle.element.querySelector<HTMLButtonElement>('button[data-view="raw"]')?.click();

    expect(selected).toEqual(["semantic"]);
  });
});
