// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { createFileViewController } from "../../../src/presentation/internal/file-view-controller";
import type { View } from "../../../src/presentation/internal/view-mode";

function pressed(controller: HTMLElement, view: View): string | null {
  return (
    controller.querySelector<HTMLButtonElement>(`button[data-view="${view}"]`)?.getAttribute("aria-pressed") ?? null
  );
}

describe("createFileViewController", () => {
  beforeEach(() => {
    document.head.replaceChildren();
    document.body.replaceChildren();
  });

  it("switches raw and semantic views after a user selection", () => {
    const selected: View[] = [];
    const semanticRoots: ShadowRoot[] = [];
    const raw = document.createElement("div");
    const files = document.createElement("div");
    files.append(raw);
    document.body.append(files);

    const controller = createFileViewController(
      "raw",
      (hidden) => {
        raw.style.display = hidden ? "none" : "";
      },
      (host) => raw.after(host),
      () => true,
    );
    controller.subscribeSelection((view) => void selected.push(view));
    controller.subscribeSemantic((root) => void semanticRoots.push(root));
    controller.start();
    files.prepend(controller.element);

    expect(raw.style.display).toBe("");
    expect(files.querySelector("[data-prefablens-view]")).toBeNull();
    expect(pressed(controller.element, "raw")).toBe("true");
    expect(pressed(controller.element, "semantic")).toBe("false");

    controller.element.querySelector<HTMLButtonElement>('button[data-view="semantic"]')?.click();

    const host = files.querySelector<HTMLDivElement>("[data-prefablens-view]");
    expect(host).not.toBeNull();
    expect(raw.style.display).toBe("none");
    expect(host?.style.display).toBe("");
    expect(selected).toEqual(["semantic"]);
    expect(semanticRoots).toEqual([host?.shadowRoot]);
    expect(pressed(controller.element, "raw")).toBe("false");
    expect(pressed(controller.element, "semantic")).toBe("true");

    controller.element.querySelector<HTMLButtonElement>('button[data-view="raw"]')?.click();

    expect(raw.style.display).toBe("");
    expect(host?.style.display).toBe("none");
    expect(selected).toEqual(["semantic", "raw"]);
    expect(pressed(controller.element, "raw")).toBe("true");
    expect(pressed(controller.element, "semantic")).toBe("false");
  });

  it("repairs one semantic host without starting semantic work", () => {
    const selected: View[] = [];
    const semanticRoots: ShadowRoot[] = [];
    const raw = document.createElement("div");
    const files = document.createElement("div");
    files.append(raw);
    document.body.append(files);
    let semanticVisible = true;

    const controller = createFileViewController(
      "semantic",
      (hidden) => {
        raw.style.display = hidden ? "none" : "";
      },
      (host) => raw.after(host),
      () => semanticVisible,
    );
    expect(files.querySelector("[data-prefablens-view]")).toBeNull();
    controller.subscribeSelection((view) => void selected.push(view));
    controller.subscribeSemantic((root) => void semanticRoots.push(root));
    controller.start();
    files.prepend(controller.element);

    const host = files.querySelector<HTMLDivElement>("[data-prefablens-view]");
    const root = host?.shadowRoot;
    expect(host).not.toBeNull();
    expect(root).not.toBeNull();
    expect(raw.style.display).toBe("none");
    expect(pressed(controller.element, "semantic")).toBe("true");
    expect(semanticRoots).toEqual([root]);

    host?.remove();
    semanticVisible = false;
    controller.sync("semantic");

    expect(host?.isConnected).toBe(true);
    expect(files.querySelector("[data-prefablens-view]")).toBe(host);
    expect(host?.shadowRoot).toBe(root);
    expect(host?.style.display).toBe("none");
    expect(raw.style.display).toBe("none");
    expect(semanticRoots).toEqual([root]);

    controller.apply("raw");
    expect(pressed(controller.element, "raw")).toBe("true");
    expect(pressed(controller.element, "semantic")).toBe("false");
    expect(selected).toEqual([]);

    semanticVisible = true;
    controller.apply("semantic");
    expect(pressed(controller.element, "raw")).toBe("false");
    expect(pressed(controller.element, "semantic")).toBe("true");
    expect(files.querySelector("[data-prefablens-view]")).toBe(host);
    expect(host?.shadowRoot).toBe(root);
    expect(semanticRoots).toEqual([root, root]);
    expect(selected).toEqual([]);
  });
});
