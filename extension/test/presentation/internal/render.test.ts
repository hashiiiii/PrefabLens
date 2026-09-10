// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { type DiffV2, emptyDiff } from "../../../src/domain/diff/types";
import { must } from "../../../src/internal/must";
import { render, renderLoading, renderSignInPending } from "../../../src/presentation/internal/render";

function freshRoot(): ShadowRoot {
  const host = document.createElement("div");
  document.body.append(host);
  return host.attachShadow({ mode: "open" });
}

describe("render", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
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
    const text = must(root.querySelector("div")?.textContent);
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

  it("renders an empty diff", () => {
    const root = freshRoot();
    render(root, { ...emptyDiff(), unresolvedGuids: [], roots: [], loose: [] });
    expect(root.textContent).toContain("No semantic changes");
  });

  it("renders an accessible loading state", () => {
    const root = freshRoot();
    renderLoading(root);
    const status = must(root.querySelector('[role="status"]'));
    expect(status.getAttribute("aria-busy")).toBe("true");
    expect(status.getAttribute("aria-label")).toBe("Computing semantic diff…");
  });
});

describe("renderSignInPending", () => {
  it("renders a secure Device Flow link", () => {
    const root = freshRoot();
    renderSignInPending(root, "ABCD-1234", "https://github.com/login/device");
    expect(root.querySelector("code")?.textContent).toBe("ABCD-1234");
    const link = must(root.querySelector<HTMLAnchorElement>("a"));
    expect(link.href).toBe("https://github.com/login/device");
    expect(link.target).toBe("_blank");
    expect(link.rel).toBe("noopener noreferrer");
  });
});
