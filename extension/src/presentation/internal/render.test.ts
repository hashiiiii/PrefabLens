// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../domain/diff/types";
import { must } from "../../internal/must";
import { detectTheme, render, renderLoading, renderSignIn, renderSignInPending, renderTooLarge } from "./render";

const DIFF: DiffV2 = {
  ...emptyDiff(),
  unresolvedGuids: ["def", "ghi"],
  resolved: { def: "Assets/Scripts/Sound.cs" },
  roots: [
    {
      kind: "gameObject",
      fileId: "1",
      name: "Player",
      status: "modified",
      overrides: [
        { group: "GameObject", label: "Name", status: "modified", before: "Hero", after: "Player" },
        { group: "Overrides", label: "Added Components (1)", status: "added", before: null, after: null },
      ],
      components: [
        {
          kind: "component",
          fileId: "2",
          classId: 114,
          typeName: "MonoBehaviour",
          scriptGuid: "def",
          className: null,
          status: "modified",
          fields: [
            { path: "volume", status: "modified", before: "0.5", after: "0.8" },
            { path: "newField", status: "added", before: null, after: "1" },
          ],
        },
        {
          kind: "component",
          fileId: "5",
          classId: 114,
          typeName: "MonoBehaviour",
          scriptGuid: null,
          className: "Health",
          status: "added",
          fields: [{ path: "Enabled", status: "added", before: null, after: "1" }],
        },
      ],
      children: [
        {
          kind: "gameObject",
          fileId: "3",
          name: "Weapon",
          status: "added",
          overrides: [],
          components: [],
          children: [],
        },
      ],
    },
  ],
  loose: [
    {
      kind: "component",
      fileId: "4",
      classId: 4,
      typeName: "Transform",
      scriptGuid: null,
      className: null,
      status: "modified",
      fields: [{ path: "Position.x", status: "modified", before: "0", after: "1" }],
    },
  ],
};

const INSTANCE: DiffV2 = {
  ...emptyDiff(),
  unresolvedGuids: ["aaa", "bbb"],
  resolved: {
    aaa: "Assets/Cylinder Variant.prefab",
    bbb: "Assets/Enemy.prefab",
  },
  roots: [
    {
      kind: "gameObject",
      fileId: "1",
      name: "Plane",
      status: "unchanged",
      overrides: [],
      components: [],
      children: [
        {
          kind: "prefabInstance",
          fileId: "1001",
          name: "Cylinder Variant",
          status: "added",
          sourceGuid: "aaa",
          overrides: [
            { group: "Transform", label: "Position", status: "added", before: null, after: "(2.03, 3.63, 1.12)" },
          ],
          components: [],
          children: [],
        },
        {
          kind: "prefabInstance",
          fileId: "1002",
          name: "",
          status: "added",
          sourceGuid: "bbb",
          overrides: [],
          components: [],
          children: [],
        },
      ],
    },
  ],
  loose: [],
};

function freshRoot(): ShadowRoot {
  const host = document.createElement("div");
  document.body.append(host);
  return host.attachShadow({ mode: "open" });
}

describe("render", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    document.documentElement.removeAttribute("data-color-mode");
  });

  it("renders hierarchy, components, overrides, and field values", () => {
    const root = freshRoot();
    render(root, DIFF);

    const gameObjects = [...root.querySelectorAll<HTMLDetailsElement>("details.pl-go")];
    expect(gameObjects).toHaveLength(2);
    expect(gameObjects[0]?.querySelector("summary")?.textContent).toContain("Player");
    expect(gameObjects[1]?.querySelector("summary")?.textContent).toContain("Weapon");

    const text = must(root.querySelector(".pl-root")?.textContent);
    expect(text).toContain("components (4)");
    expect(text).toContain("GameObject");
    expect(text).toContain("NameHero→Player");
    expect(text).toContain("Sound‹Script: Assets/Scripts/Sound.cs›");
    expect(text).toContain("volume0.5→0.8");

    const added = must([...root.querySelectorAll(".pl-field")].find((row) => row.textContent?.includes("newField")));
    expect(added.textContent).toBe("newField1");
    const structural = must(
      [...root.querySelectorAll(".pl-field")].find((row) => row.textContent?.includes("Added Components (1)")),
    );
    expect(structural.textContent).toBe("Added Components (1)");

    const cards = [...root.querySelectorAll<HTMLDetailsElement>("details.pl-components > .pl-kids > details")];
    expect(cards).toHaveLength(5);
    expect(cards.every((card) => card.open)).toBe(true);
    expect(root.querySelector(".pl-root > details.pl-components details.pl-comp")?.textContent).toContain("Transform");
  });

  it("formats local, null, built-in, and unresolved references", () => {
    const refs: DiffV2 = {
      ...emptyDiff(),
      unresolvedGuids: ["ghi"],
      roots: [],
      loose: [
        {
          kind: "component",
          fileId: "5",
          classId: 33,
          typeName: "MeshFilter",
          scriptGuid: null,
          className: null,
          status: "modified",
          fields: [
            {
              path: "Local",
              status: "modified",
              before: { ref: { fileId: "100", guid: null, type: null } },
              after: { ref: { fileId: "0", guid: null, type: null } },
            },
            {
              path: "Asset",
              status: "modified",
              before: { ref: { fileId: "10202", guid: "0000000000000000e000000000000000", type: 0 } },
              after: { ref: { fileId: "42", guid: "ghi", type: 2 } },
            },
          ],
        },
      ],
    };
    const root = freshRoot();
    render(root, refs);
    const text = must(root.querySelector(".pl-root")?.textContent);
    expect(text).toContain("#100");
    expect(text).toContain("None");
    expect(text).toContain("Cube (built-in)");
    expect(text).toContain("guid:ghi");
    expect(text).not.toContain("#0");
  });

  it("renders repository strings as text", () => {
    const hostile: DiffV2 = {
      ...emptyDiff(),
      unresolvedGuids: [],
      roots: [
        {
          kind: "gameObject",
          fileId: "1",
          name: "<img src=x onerror=alert(1)>",
          status: "added",
          overrides: [],
          components: [],
          children: [],
        },
      ],
      loose: [],
    };
    const root = freshRoot();
    render(root, hostile);
    expect(root.querySelector("img")).toBeNull();
    expect(root.textContent).toContain("<img src=x onerror=alert(1)>");
  });

  it("replaces prior content and renders an empty diff", () => {
    const root = freshRoot();
    render(root, DIFF);
    render(root, { ...emptyDiff(), unresolvedGuids: [], roots: [], loose: [] });
    expect(root.querySelectorAll("details")).toHaveLength(0);
    expect(root.textContent).toContain("No semantic changes");
  });

  it("waits for a large-file action", async () => {
    const root = freshRoot();
    const clicked = renderTooLarge(root, 26 * 1024 * 1024);
    expect(root.textContent).toContain("Large file (26 MB)");
    const button = must(root.querySelector<HTMLButtonElement>("button.pl-render"));
    expect(button.textContent).toBe("Render anyway");
    button.click();
    await clicked;
  });

  it("renders prefab instances and fallback names", () => {
    const root = freshRoot();
    render(root, INSTANCE);
    const text = must(root.textContent);
    expect(text).toContain("Cylinder Variant‹Prefab: Assets/Cylinder Variant.prefab›");
    expect(text).toContain("Transform");
    expect(text).toContain("Position(2.03, 3.63, 1.12)");
    expect(text).toContain("Enemy‹Prefab: Assets/Enemy.prefab›");
  });

  it("renders unresolved component and instance names", () => {
    const diff: DiffV2 = {
      ...emptyDiff(),
      unresolvedGuids: ["xyz", "zzz"],
      roots: [
        {
          kind: "prefabInstance",
          fileId: "1001",
          name: "",
          status: "added",
          sourceGuid: "zzz",
          overrides: [],
          components: [],
          children: [],
        },
      ],
      loose: [
        {
          kind: "component",
          fileId: "5",
          classId: 114,
          typeName: "MonoBehaviour",
          scriptGuid: "xyz",
          className: "Cylinder1",
          status: "modified",
          fields: [{ path: "Hp", status: "modified", before: "1", after: "2" }],
        },
      ],
    };
    const root = freshRoot();
    render(root, diff);
    const text = must(root.textContent);
    expect(text).toContain("Prefab Instance‹Prefab›");
    expect(text).toContain("Cylinder1‹Script›");
    expect(text).not.toContain("MonoBehaviour");
  });

  it("shows reference resolution progress", () => {
    const root = freshRoot();
    render(root, { ...emptyDiff(), unresolvedGuids: ["g1", "g2"], roots: [], loose: [] }, { resolving: 2 });
    expect(root.textContent).toContain("Resolving 2 reference(s)…");
  });

  it("waits for an incomplete-resolution retry", async () => {
    const root = freshRoot();
    const retried = render(root, DIFF, { incomplete: true });
    expect(root.textContent).toContain("Some references were not resolved");
    must(root.querySelector<HTMLButtonElement>("button.pl-render")).click();
    await retried;
  });

  it("renders an accessible loading state", () => {
    const root = freshRoot();
    renderLoading(root);
    const status = must(root.querySelector('[role="status"]'));
    expect(status.getAttribute("aria-busy")).toBe("true");
    expect(status.getAttribute("aria-label")).toBe("Computing semantic diff…");
  });
});

describe("detectTheme", () => {
  it("uses an explicit document theme", () => {
    document.documentElement.setAttribute("data-color-mode", "dark");
    expect(detectTheme(document)).toBe("dark");
    document.documentElement.setAttribute("data-color-mode", "light");
    expect(detectTheme(document)).toBe("light");
  });

  it("uses the operating-system theme for automatic mode", () => {
    document.documentElement.setAttribute("data-color-mode", "auto");
    expect(detectTheme(document)).toBe("light");
    const win = must(document.defaultView);
    win.matchMedia = ((query: string) => ({
      matches: query === "(prefers-color-scheme: dark)",
    })) as unknown as typeof win.matchMedia;
    try {
      expect(detectTheme(document)).toBe("dark");
    } finally {
      delete (win as { matchMedia?: unknown }).matchMedia;
    }
  });
});

describe("renderSignIn", () => {
  it("waits for the sign-in action", async () => {
    const root = freshRoot();
    const clicked = renderSignIn(root, "Sign in with GitHub to view semantic diffs.");
    expect(root.textContent).toContain("Sign in with GitHub to view semantic diffs.");
    const button = must(root.querySelector<HTMLButtonElement>("button.pl-render"));
    expect(button.textContent).toBe("Sign in with GitHub");
    button.click();
    await clicked;
  });
});

describe("renderSignInPending", () => {
  it("renders a secure Device Flow link", () => {
    const root = freshRoot();
    renderSignInPending(root, "ABCD-1234", "https://github.com/login/device");
    expect(root.querySelector(".pl-user-code")?.textContent).toBe("ABCD-1234");
    expect(root.querySelector<HTMLButtonElement>("button.pl-render")?.textContent).toBe("Copy code");
    const link = must(root.querySelector<HTMLAnchorElement>("a.pl-render"));
    expect(link.href).toBe("https://github.com/login/device");
    expect(link.target).toBe("_blank");
    expect(link.rel).toBe("noopener noreferrer");
  });
});
