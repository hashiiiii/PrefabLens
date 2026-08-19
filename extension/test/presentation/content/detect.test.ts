// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { must } from "../../../src/internal/must";
import { parseDiffUrl, parsePrPage, scanUnityFiles } from "../../../src/presentation/content/detect";

const FIXTURE = `
  <div class="file">
    <div class="file-header" data-path="Assets/Foo.prefab"><div class="file-actions"></div></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="Assets/Scenes/Main.unity"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="Assets/Data/Config.asset"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="src/main.cs"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file-header" data-path="Assets/Orphan.prefab"></div>
`;

describe("parseDiffUrl", () => {
  it("matches the PR files tab", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/files")).toEqual({
      owner: "owner",
      repo: "repo",
      target: { kind: "pull", prNumber: 42 },
    });
  });

  it("matches a file anchor on the PR files tab", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/files/abc123")?.target).toEqual({ kind: "pull", prNumber: 42 });
  });

  it("matches the React changes tab", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/changes")?.target).toEqual({ kind: "pull", prNumber: 42 });
  });

  it("matches a commit range on the React changes tab", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/changes/1e27d799..e1aba6f")?.target).toEqual({
      kind: "pull",
      prNumber: 42,
    });
  });

  it("maps a single commit on the React changes tab to a commit target", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/changes/1e27d7998afdd3608d9fc3bf95ccf27fa5010641")?.target).toEqual({
      kind: "commit",
      sha: "1e27d7998afdd3608d9fc3bf95ccf27fa5010641",
    });
  });

  it("maps a single commit on the classic commits tab to a commit target", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/commits/1e27d79")?.target).toEqual({ kind: "commit", sha: "1e27d79" });
  });

  it("matches commit pages", () => {
    expect(parseDiffUrl("/owner/repo/commit/1e27d7998afdd3608d9fc3bf95ccf27fa5010641")).toEqual({
      owner: "owner",
      repo: "repo",
      target: { kind: "commit", sha: "1e27d7998afdd3608d9fc3bf95ccf27fa5010641" },
    });
  });

  it("matches a commit page with a trailing slash", () => {
    expect(parseDiffUrl("/owner/repo/commit/1e27d79/")?.target).toEqual({ kind: "commit", sha: "1e27d79" });
  });

  it("rejects a commit page without a SHA", () => {
    expect(parseDiffUrl("/owner/repo/commit/not-a-sha")).toBeNull();
  });

  it("matches same-repo three-dot compare pages", () => {
    expect(parseDiffUrl("/owner/repo/compare/main...feature")).toEqual({
      owner: "owner",
      repo: "repo",
      target: { kind: "compare", base: "main", head: "feature" },
    });
  });

  it("preserves slashes in compare branch names", () => {
    expect(parseDiffUrl("/owner/repo/compare/feat/a...feat/b")?.target).toEqual({
      kind: "compare",
      base: "feat/a",
      head: "feat/b",
    });
  });

  it("decodes each compare ref", () => {
    expect(parseDiffUrl("/owner/repo/compare/v1%2E0...main")?.target).toEqual({
      kind: "compare",
      base: "v1.0",
      head: "main",
    });
  });

  it("removes a trailing slash from the compare head ref", () => {
    expect(parseDiffUrl("/owner/repo/compare/main...topic/")?.target).toEqual({
      kind: "compare",
      base: "main",
      head: "topic",
    });
  });

  it("survives malformed percent escapes instead of throwing", () => {
    // Browsers keep invalid percent sequences in pathname. decodeURIComponent throws for this input.
    expect(parseDiffUrl("/owner/repo/compare/50%discount...main")?.target).toEqual({
      kind: "compare",
      base: "50%discount",
      head: "main",
    });
  });

  it("rejects a cross-repository compare page", () => {
    expect(parseDiffUrl("/owner/repo/compare/main...other:branch")).toBeNull();
  });

  it("rejects a compare page with one ref", () => {
    expect(parseDiffUrl("/owner/repo/compare/main")).toBeNull();
  });

  it("rejects the compare picker page", () => {
    expect(parseDiffUrl("/owner/repo/compare")).toBeNull();
  });

  it("rejects a PR conversation page", () => {
    expect(parseDiffUrl("/owner/repo/pull/42")).toBeNull();
  });

  it("rejects a PR commit list", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/commits")).toBeNull();
  });

  it("rejects a repository file page", () => {
    expect(parseDiffUrl("/owner/repo/blob/main/a.prefab")).toBeNull();
  });
});

describe("parsePrPage", () => {
  it("matches every PR tab, not only the files tab", () => {
    // Prefetch starts when the user opens the conversation tab.
    expect(parsePrPage("/o/r/pull/12")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
    expect(parsePrPage("/o/r/pull/12/commits")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
    expect(parsePrPage("/o/r/pull/12/files")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
  });

  it("rejects pages outside a PR", () => {
    expect(parsePrPage("/o/r/pulls")).toBeNull();
    expect(parsePrPage("/o/r/issues/12")).toBeNull();
    expect(parsePrPage("/o/r/pull/notanumber")).toBeNull();
  });
});

describe("scanUnityFiles", () => {
  it("finds Unity file containers and skips other files", () => {
    document.body.innerHTML = FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual([
      "Assets/Foo.prefab",
      "Assets/Scenes/Main.unity",
      "Assets/Data/Config.asset",
    ]);
  });

  it("hides and restores the raw file content", () => {
    document.body.innerHTML = FIXTURE;
    const entry = must(scanUnityFiles(document)[0]);
    const content = must(document.querySelector<HTMLElement>(".file .js-file-content"));

    entry.setRawHidden(true);
    expect(content.style.display).toBe("none");
    entry.setRawHidden(false);
    expect(content.style.display).toBe("");
  });

  it("uses the classic file container as the global anchor", () => {
    document.body.innerHTML = FIXTURE;
    const entry = must(scanUnityFiles(document)[0]);

    // Primer CSS controls the collapsed state for classic file containers.
    expect(entry.collapsed()).toBe(false);
    expect(entry.globalAnchor()).toBe(document.querySelector(".file"));
  });

  it("attaches the semantic host after the raw content", () => {
    document.body.innerHTML = FIXTURE;
    const entry = must(scanUnityFiles(document)[0]);
    const content = must(document.querySelector<HTMLElement>(".file .js-file-content"));
    const host = document.createElement("div");

    entry.attachHost(host);

    expect(content.nextElementSibling).toBe(host);
    expect(host.classList.contains("Details-content--hidden")).toBe(true);
  });

  it("skips files that do not contain UnityYAML", () => {
    document.body.innerHTML = `
        <div class="file">
          <div class="file-header" data-path="Assets/Foo.prefab.meta"></div>
          <div class="js-file-content">raw diff</div>
        </div>
        <div class="file">
          <div class="file-header" data-path="Assets/Code.asmdef"></div>
          <div class="js-file-content">raw diff</div>
        </div>
        <div class="file">
          <div class="file-header" data-path="Assets/S.shadergraph"></div>
          <div class="js-file-content">raw diff</div>
        </div>
        <div class="file">
          <div class="file-header" data-path="Assets/T.png"></div>
          <div class="js-file-content">raw diff</div>
        </div>
      `;

    expect(scanUnityFiles(document)).toEqual([]);
  });

  it("is harmless when the expected structure is missing (defensive selectors)", () => {
    document.body.innerHTML = "<div>totally different markup</div>";
    expect(scanUnityFiles(document)).toEqual([]);
  });
});

// GitHub React diff markup uses hashed classes and LRM-wrapped header text.
const REACT_FIXTURE = `
  <div data-testid="diff-content">
    <div data-testid="progressive-diffs-list">
      <div class="PullRequestDiffsList-module__diffEntry__djnVa">
        <div role="region" id="diff-aaa111" class="Diff-module__diffTargetable Diff-module__diff">
          <div class="Diff-module__diffHeaderWrapper">
            <div class="DiffFileHeader-module__diff-file-header">
              <h3 class="DiffFileHeader-module__file-name"><a href="#diff-aaa111"><code>‎Assets/Foo.prefab‎</code></a></h3>
              <button type="button" aria-expanded="true"><svg class="octicon octicon-chevron-down"></svg></button>
            </div>
          </div>
          <div class="border position-relative rounded-bottom-2">raw diff</div>
        </div>
      </div>
      <div class="PullRequestDiffsList-module__diffEntry__djnVa">
        <div role="region" id="diff-bbb222" class="Diff-module__diffTargetable Diff-module__diff">
          <div class="Diff-module__diffHeaderWrapper">
            <div class="DiffFileHeader-module__diff-file-header">
              <h3 class="DiffFileHeader-module__file-name"><a href="#diff-bbb222"><code>‎README.md‎</code></a></h3>
              <button type="button" aria-expanded="true"><svg class="octicon octicon-chevron-down"></svg></button>
            </div>
          </div>
          <div class="border position-relative rounded-bottom-2">raw diff</div>
        </div>
      </div>
    </div>
  </div>
`;

describe("scanUnityFiles (React UI)", () => {
  it("finds Unity files by header text and removes bidi marks", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual(["Assets/Foo.prefab"]);
  });

  it("reads the renamed-to path from the visually hidden span", () => {
    // GitHub rename text contains both paths. The accessible text identifies the final path.
    document.body.innerHTML = REACT_FIXTURE.replace(
      "<code>‎Assets/Foo.prefab‎</code>",
      '<code>‎Assets/{Old.prefab → New.prefab}‎<span class="sr-only">Assets/Old.prefab renamed to Assets/New.prefab</span></code>',
    );
    expect(scanUnityFiles(document).map((e) => e.path)).toEqual(["Assets/New.prefab"]);
  });

  it("re-resolves body nodes on every call because react recreates them", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entry = must(scanUnityFiles(document)[0]);
    entry.setRawHidden(true);
    // React can replace the body and change its CSS classes. The fallback must hide this replacement.
    const region = must(document.querySelector("#diff-aaa111"));
    must(region.querySelector(".border.rounded-bottom-2")).remove();
    const fresh = document.createElement("div");
    fresh.className = "Diff-module__diffContent";
    region.append(fresh);
    entry.setRawHidden(true);
    expect(fresh.style.display).toBe("none");
  });

  it("is harmless when the react structure is missing pieces", () => {
    document.body.innerHTML = '<div role="region" id="diff-x"><div>no header</div></div>';
    expect(scanUnityFiles(document)).toEqual([]);
  });
});
