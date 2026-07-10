// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { DiffV2 } from "../types";
import {
  detectTheme,
  render,
  renderError,
  renderLoading,
  renderSignIn,
  renderSignInPending,
  renderTooLarge,
} from "./render";

const DIFF: DiffV2 = {
  schema: "prefablens.diff.v2",
  unresolvedGuids: ["def", "ghi"],
  resolved: { def: "Assets/Scripts/Sound.cs" },
  roots: [
    {
      kind: "gameObject",
      fileId: "1",
      name: "Player",
      status: "modified",
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
            {
              path: "m_Target",
              status: "modified",
              before: { ref: { fileId: "100", guid: null, type: null } },
              after: { ref: { fileId: "0", guid: "ghi", type: 2 } },
            },
            { path: "newField", status: "added", before: null, after: "1" },
          ],
        },
      ],
      children: [{ kind: "gameObject", fileId: "3", name: "Weapon", status: "added", components: [], children: [] }],
    },
  ],
  loose: [],
};

const INSTANCE: DiffV2 = {
  schema: "prefablens.diff.v2",
  unresolvedGuids: ["aaa"],
  resolved: { aaa: "Assets/Cylinder Variant.prefab" },
  roots: [
    {
      kind: "gameObject",
      fileId: "1",
      name: "Plane",
      status: "unchanged",
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

  it("renders the GameObject hierarchy with statuses", () => {
    const root = freshRoot();
    render(root, DIFF);
    const gos = root.querySelectorAll("details.pl-go");
    expect(gos).toHaveLength(2);
    expect(gos[0]?.querySelector("summary")?.textContent).toContain("Player");
    expect(gos[1]?.classList.contains("pl-added")).toBe(true);
  });

  it("shows field values as before → after and resolves the component to its script stem", () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector(".pl-root")!.textContent!;
    expect(text).toContain("volume");
    expect(text).toContain("0.5");
    expect(text).toContain("0.8");
    expect(text).toContain("Sound"); // resolved guid → file stem, not the full path
    expect(text).toContain("‹Script›");
  });

  it("shows only the current value for added fields, without a before placeholder", () => {
    const root = freshRoot();
    render(root, DIFF);
    const rows = [...root.querySelectorAll(".pl-field")];
    const added = rows.find((r) => r.textContent?.includes("newField"))!;
    expect(added.textContent).toBe("newField1");
  });

  it("falls back to the raw guid when unresolved and to #fileId for local refs", () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector(".pl-root")!.textContent!;
    expect(text).toContain("#100"); // local ref
    expect(text).toContain("ghi"); // unresolved guid stays visible
  });

  it("renders repo-controlled strings as text, never as markup", () => {
    const hostile: DiffV2 = {
      ...DIFF,
      roots: [
        {
          kind: "gameObject",
          fileId: "1",
          name: "<img src=x onerror=alert(1)>",
          status: "added",
          components: [],
          children: [],
        },
      ],
    };
    const root = freshRoot();
    render(root, hostile);
    expect(root.querySelector("img")).toBeNull();
    expect(root.textContent).toContain("<img src=x onerror=alert(1)>");
  });

  it("replaces previous content on re-render and shows an empty note for empty diffs", () => {
    const root = freshRoot();
    render(root, DIFF);
    render(root, { schema: "prefablens.diff.v2", unresolvedGuids: [], roots: [], loose: [] });
    expect(root.querySelectorAll("details")).toHaveLength(0);
    expect(root.textContent).toContain("No semantic changes");
  });

  it("renderTooLarge shows the size and renders on click", () => {
    const root = freshRoot();
    const onRender = vi.fn();
    renderTooLarge(root, 26 * 1024 * 1024, onRender);
    expect(root.textContent).toContain("Large file (26 MB)");
    const button = root.querySelector<HTMLButtonElement>("button.pl-render")!;
    expect(button.textContent).toBe("Render anyway");
    button.click();
    expect(onRender).toHaveBeenCalledTimes(1);
  });

  it("renderError shows a clean one-line message", () => {
    const root = freshRoot();
    renderError(root, "Set a GitHub token in the PrefabLens options page.");
    expect(root.textContent).toContain("Set a GitHub token");
  });

  it("renders prefab instance with badge, components section and open override card", () => {
    const root = freshRoot();
    render(root, INSTANCE);
    const text = root.textContent ?? "";
    expect(text).toContain("Cylinder Variant");
    expect(text).toContain("‹Prefab: Assets/Cylinder Variant.prefab›");
    expect(text).toContain("components");
    expect(text).toContain("Transform");
    expect(text).toContain("Position");
    // The override card is open.
    const card = root.querySelector(".pl-components details") as HTMLDetailsElement;
    expect(card.open).toBe(true);
  });

  it("marks a mixed-status override group heading as modified", () => {
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: [],
      roots: [
        {
          kind: "prefabInstance",
          fileId: "1001",
          name: "Cylinder",
          status: "modified",
          sourceGuid: null,
          overrides: [
            { group: "Transform", label: "Scale.y", status: "added", before: null, after: "2" },
            { group: "Transform", label: "Position.x", status: "modified", before: "0", after: "1" },
          ],
          components: [],
          children: [],
        },
      ],
      loose: [],
    };
    const root = freshRoot();
    render(root, diff);
    const card = root.querySelector(".pl-components details") as HTMLDetailsElement;
    expect(card.classList.contains("pl-modified")).toBe(true);
    expect(card.querySelector("summary .pl-badge")?.textContent).toBe("~");
    // The rows themselves keep their original status.
    expect(card.querySelector(".pl-field.pl-added")?.textContent).toContain("Scale.y");
  });

  it("renders structural summary rows as label only, without a value placeholder", () => {
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: [],
      roots: [
        {
          kind: "prefabInstance",
          fileId: "1001",
          name: "Cylinder",
          status: "modified",
          sourceGuid: null,
          overrides: [
            { group: "Overrides", label: "Added Components (1)", status: "added", before: null, after: null },
          ],
          components: [],
          children: [],
        },
      ],
      loose: [],
    };
    const root = freshRoot();
    render(root, diff);
    const row = root.querySelector(".pl-field");
    expect(row?.textContent).toContain("Added Components (1)");
    expect(row?.textContent).not.toContain("—");
  });

  it("keeps added and modified component cards open", () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: [],
      roots: [
        {
          kind: "gameObject",
          fileId: "1",
          name: "Cylinder",
          status: "modified",
          components: [
            {
              kind: "component",
              fileId: "8",
              classId: 114,
              typeName: "MonoBehaviour",
              scriptGuid: null,
              className: "Cylinder1",
              status: "added",
              fields: [{ path: "Enabled", status: "added", before: null, after: "1" }],
            },
            {
              kind: "component",
              fileId: "4",
              classId: 4,
              typeName: "Transform",
              scriptGuid: null,
              className: null,
              status: "modified",
              fields: [{ path: "Position.x", status: "modified", before: "0.64596", after: "1" }],
            },
          ],
          children: [],
        },
      ],
      loose: [],
    };
    render(root, diff);
    const cards = [...root.querySelectorAll(".pl-components > details")] as HTMLDetailsElement[];
    expect(cards).toHaveLength(2);
    // Closing added would look asymmetric ("only Cylinder1 collapsed"), so always open regardless of status
    expect(cards[0]?.open).toBe(true); // added Cylinder1 is open too
    expect(cards[0]?.textContent).toContain("Cylinder1"); // className fallback
    expect(cards[1]?.open).toBe(true); // modified Transform is open
  });

  it("falls back instance name to resolved source prefab stem", () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: ["bbb"],
      resolved: { bbb: "Assets/Enemy.prefab" },
      roots: [
        {
          kind: "prefabInstance",
          fileId: "1001",
          name: "",
          status: "added",
          sourceGuid: "bbb",
          overrides: [],
          components: [],
          children: [],
        },
      ],
      loose: [],
    };
    render(root, diff);
    expect(root.textContent).toContain("Enemy");
  });

  it("falls back to generic instance name and badge when sourceGuid is unresolved", () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: ["zzz"],
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
      loose: [],
    };
    render(root, diff);
    expect(root.textContent).toContain("Prefab Instance");
    expect(root.textContent).toContain("‹Prefab›");
  });

  it("shows a resolving indicator while guid resolution is pending", () => {
    const root = freshRoot();
    render(
      root,
      { schema: "prefablens.diff.v2", unresolvedGuids: ["g1", "g2"], roots: [], loose: [] },
      { resolving: 2 },
    );
    expect(root.textContent).toContain("Resolving 2 reference(s)…");
  });

  it("drops the indicator on re-render after resolution completes", () => {
    // It disappears when re-rendered on the push's done (mount fully replaces, so it naturally goes away)
    const root = freshRoot();
    const diff = { schema: "prefablens.diff.v2" as const, unresolvedGuids: ["g1"], roots: [], loose: [] };
    render(root, diff, { resolving: 1 });
    render(root, diff);
    expect(root.textContent).not.toContain("Resolving");
  });

  it("falls back component display to className when the script guid is unresolved", () => {
    const root = freshRoot();
    const diff: DiffV2 = {
      schema: "prefablens.diff.v2",
      unresolvedGuids: ["xyz"],
      roots: [],
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
    render(root, diff);
    const summary = root.querySelector("details > summary");
    expect(summary?.textContent).toContain("Cylinder1");
    expect(summary?.textContent).not.toContain("MonoBehaviour");
  });

  it("renders unity-style rows: chevron, icon and status badge", () => {
    const root = freshRoot();
    render(root, DIFF);
    const summary = root.querySelector("details.pl-go > summary")!;
    expect(summary.classList.contains("pl-row")).toBe(true);
    expect(summary.querySelector(".pl-chevron svg")).not.toBeNull();
    expect(summary.querySelector(".pl-icon svg")).not.toBeNull();
    expect(summary.querySelector(".pl-badge")?.textContent).toBe("~");
  });

  it("skips the status badge on unchanged rows and tints the prefab icon", () => {
    const root = freshRoot();
    render(root, INSTANCE);
    // Plane is unchanged: no badge chip at all, not a blank one
    const plane = root.querySelector("details.pl-go > summary")!;
    expect(plane.querySelector(".pl-badge")).toBeNull();
    const icon = root.querySelector("details.pl-pi > summary .pl-icon")!;
    expect(icon.classList.contains("pl-icon-prefab")).toBe(true);
  });

  it("marks rows without children as leaves (chevron slot hidden via CSS)", () => {
    const root = freshRoot();
    render(root, DIFF);
    const summaries = [...root.querySelectorAll("details.pl-go > summary")];
    const weapon = summaries.find((s) => s.textContent?.includes("Weapon"))!;
    expect(weapon.classList.contains("pl-leaf")).toBe(true);
    const player = summaries.find((s) => s.textContent?.includes("Player"))!;
    expect(player.classList.contains("pl-leaf")).toBe(false);
  });

  it("renderLoading shows an accessible skeleton tree instead of text", () => {
    const root = freshRoot();
    renderLoading(root);
    const box = root.querySelector(".pl-skeleton")!;
    expect(box.getAttribute("role")).toBe("status");
    expect(box.getAttribute("aria-busy")).toBe("true");
    expect(box.getAttribute("aria-label")).toContain("Computing semantic diff");
    expect(box.querySelectorAll(".pl-skel-row")).toHaveLength(5);
    // The label lives in aria, not in visible text
    expect(box.textContent).toBe("");
  });

  it("shows a spinner with the resolving indicator", () => {
    const root = freshRoot();
    render(root, { schema: "prefablens.diff.v2", unresolvedGuids: ["g1"], roots: [], loose: [] }, { resolving: 1 });
    expect(root.querySelector(".pl-resolving .pl-spinner")).not.toBeNull();
  });

  it("shows an alert icon on errors", () => {
    const root = freshRoot();
    renderError(root, "Could not fetch file contents from GitHub.");
    expect(root.querySelector(".pl-error .pl-note-icon svg")).not.toBeNull();
  });
});

describe("detectTheme", () => {
  it("follows html[data-color-mode]", () => {
    document.documentElement.setAttribute("data-color-mode", "dark");
    expect(detectTheme(document)).toBe("dark");
    document.documentElement.setAttribute("data-color-mode", "light");
    expect(detectTheme(document)).toBe("light");
  });

  it("follows the OS scheme via matchMedia when data-color-mode is auto", () => {
    // GitHub's default is auto: a value that is neither dark nor light defers to matchMedia
    document.documentElement.setAttribute("data-color-mode", "auto");
    expect(detectTheme(document)).toBe("light"); // jsdom has no matchMedia → fall back to light
    const win = document.defaultView!;
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
  it("renders the message and a sign-in button that invokes the callback", () => {
    const root = freshRoot();
    let clicks = 0;
    renderSignIn(root, "Sign in with GitHub to view semantic diffs.", () => clicks++);
    expect(root.querySelector(".pl-error")?.textContent).toContain("Sign in with GitHub to view semantic diffs.");
    const button = root.querySelector<HTMLButtonElement>("button.pl-render");
    expect(button?.textContent).toBe("Sign in with GitHub");
    button?.click();
    expect(clicks).toBe(1);
  });
});

describe("renderSignInPending", () => {
  it("shows the user code, a copy button, and a link to the verification page", () => {
    const root = freshRoot();
    let copies = 0;
    renderSignInPending(root, "ABCD-1234", "https://github.com/login/device", () => copies++);
    expect(root.querySelector(".pl-user-code")?.textContent).toBe("ABCD-1234");
    const copy = root.querySelector<HTMLButtonElement>("button.pl-render");
    expect(copy?.textContent).toBe("Copy code");
    copy?.click();
    expect(copies).toBe(1);
    const link = root.querySelector<HTMLAnchorElement>("a.pl-render");
    expect(link?.href).toBe("https://github.com/login/device");
    // New tab without opener: the PR tab must keep polling while the user authorizes.
    expect(link?.target).toBe("_blank");
    expect(link?.rel).toBe("noopener noreferrer");
    expect(root.querySelector(".pl-signin-wait .pl-spinner")).not.toBeNull();
  });
});
