// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { parseDiffUrl, parsePrPage, scanUnityFiles } from "./detect";

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
    expect(parseDiffUrl("/owner/repo/pull/42/files/abc123")?.target).toEqual({ kind: "pull", prNumber: 42 });
  });
  it("matches the react ui changes tab and its commit range view", () => {
    expect(parseDiffUrl("/owner/repo/pull/42/changes")?.target).toEqual({ kind: "pull", prNumber: 42 });
    // "Between commit A and B" range view, same shape github-url-detection accepts
    expect(parseDiffUrl("/owner/repo/pull/42/changes/1e27d799..e1aba6f")?.target).toEqual({
      kind: "pull",
      prNumber: 42,
    });
  });
  it("maps single-commit views inside a PR to a commit target", () => {
    // react ui: /changes/SHA, classic: /commits/SHA — both show one commit against its parent
    expect(parseDiffUrl("/owner/repo/pull/42/changes/1e27d7998afdd3608d9fc3bf95ccf27fa5010641")?.target).toEqual({
      kind: "commit",
      sha: "1e27d7998afdd3608d9fc3bf95ccf27fa5010641",
    });
    expect(parseDiffUrl("/owner/repo/pull/42/commits/1e27d79")?.target).toEqual({ kind: "commit", sha: "1e27d79" });
  });
  it("matches commit pages", () => {
    expect(parseDiffUrl("/owner/repo/commit/1e27d7998afdd3608d9fc3bf95ccf27fa5010641")).toEqual({
      owner: "owner",
      repo: "repo",
      target: { kind: "commit", sha: "1e27d7998afdd3608d9fc3bf95ccf27fa5010641" },
    });
    expect(parseDiffUrl("/owner/repo/commit/1e27d79/")?.target).toEqual({ kind: "commit", sha: "1e27d79" });
    expect(parseDiffUrl("/owner/repo/commit/not-a-sha")).toBeNull();
  });
  it("matches same-repo three-dot compare pages", () => {
    expect(parseDiffUrl("/owner/repo/compare/main...feature")).toEqual({
      owner: "owner",
      repo: "repo",
      target: { kind: "compare", base: "main", head: "feature" },
    });
    // branch names keep their slashes; encoded characters are decoded per side
    expect(parseDiffUrl("/owner/repo/compare/feat/a...feat/b")?.target).toEqual({
      kind: "compare",
      base: "feat/a",
      head: "feat/b",
    });
    expect(parseDiffUrl("/owner/repo/compare/v1%2E0...main")?.target).toEqual({
      kind: "compare",
      base: "v1.0",
      head: "main",
    });
    // A manually typed trailing slash must not leak into the head ref (git refs can't end with /)
    expect(parseDiffUrl("/owner/repo/compare/main...topic/")?.target).toEqual({
      kind: "compare",
      base: "main",
      head: "topic",
    });
  });

  it("survives malformed percent escapes instead of throwing", () => {
    // Browsers pass invalid %-sequences through pathname verbatim; decodeURIComponent would
    // throw URIError and attach() runs this unguarded before the MutationObserver is installed
    expect(parseDiffUrl("/owner/repo/compare/50%discount...main")?.target).toEqual({
      kind: "compare",
      base: "50%discount",
      head: "main",
    });
  });
  it("rejects compare pages this extension cannot serve", () => {
    expect(parseDiffUrl("/owner/repo/compare/main...other:branch")).toBeNull(); // cross-fork
    expect(parseDiffUrl("/owner/repo/compare/main")).toBeNull(); // single ref
    expect(parseDiffUrl("/owner/repo/compare")).toBeNull(); // picker page
  });
  it("rejects other pages", () => {
    expect(parseDiffUrl("/owner/repo/pull/42")).toBeNull();
    expect(parseDiffUrl("/owner/repo/pull/42/commits")).toBeNull(); // commit list, no diff
    expect(parseDiffUrl("/owner/repo/blob/main/a.prefab")).toBeNull();
  });
});

describe("parsePrPage", () => {
  it("matches every pr tab, not just files", () => {
    // Prefetch starts on arrival at the conversation tab
    expect(parsePrPage("/o/r/pull/12")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
    expect(parsePrPage("/o/r/pull/12/commits")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
    expect(parsePrPage("/o/r/pull/12/files")).toEqual({ owner: "o", repo: "r", prNumber: 12 });
  });

  it("rejects non-pr pages", () => {
    expect(parsePrPage("/o/r/pulls")).toBeNull();
    expect(parsePrPage("/o/r/issues/12")).toBeNull();
    expect(parsePrPage("/o/r/pull/notanumber")).toBeNull();
  });
});

describe("scanUnityFiles", () => {
  it("finds .prefab/.unity/.asset containers and skips other files", () => {
    document.body.innerHTML = FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual([
      "Assets/Foo.prefab",
      "Assets/Scenes/Main.unity",
      "Assets/Data/Config.asset",
    ]);
    // Behavior replaces the old `content` field: hiding acts on the .js-file-content element
    const content = document.querySelector<HTMLElement>(".file .js-file-content")!;
    entries[0]!.setRawHidden(true);
    expect(content.style.display).toBe("none");
    entries[0]!.setRawHidden(false);
    expect(content.style.display).toBe("");
    // Classic collapse is handled by Primer's Details CSS, not by us
    expect(entries[0]!.collapsed()).toBe(false);
    // The global bar anchors on the .file container
    expect(entries[0]!.globalAnchor()).toBe(document.querySelector(".file"));
    // The host lands right after the content and opts into the Details collapse CSS
    const host = document.createElement("div");
    entries[0]!.attachHost(host);
    expect(content.nextElementSibling).toBe(host);
    expect(host.classList.contains("Details-content--hidden")).toBe(true);
  });

  it("finds every UnityYAML asset extension beyond the original trio", () => {
    // The set of text-serialized assets that unityyamlmerge targets.
    // Case matches Unity's actual output (camelCase like .overrideController).
    const paths = [
      "Assets/M.mat",
      "Assets/A.anim",
      "Assets/C.controller",
      "Assets/O.overrideController",
      "Assets/P.physicMaterial",
      "Assets/P2.physicsMaterial2D",
      "Assets/T.playable",
      "Assets/K.mask",
      "Assets/B.brush",
      "Assets/F.flare",
      "Assets/F.fontsettings",
      "Assets/G.guiskin",
      "Assets/G.giparams",
      "Assets/R.renderTexture",
      "Assets/S.spriteatlas",
      "Assets/S.spriteatlasv2",
      "Assets/T.terrainlayer",
      "Assets/X.mixer",
      "Assets/V.shadervariants",
      "Assets/P.preset",
      "Assets/S.signal",
      "Assets/L.lighting",
      "Assets/S.scenetemplate",
    ];
    document.body.innerHTML = paths
      .map(
        (p) => `<div class="file">
          <div class="file-header" data-path="${p}"></div>
          <div class="js-file-content">raw diff</div>
        </div>`,
      )
      .join("");
    expect(scanUnityFiles(document).map((e) => e.path)).toEqual(paths);
  });

  it("skips YAML-but-not-UnityYAML and JSON assets", () => {
    // .meta is not !u! document format, and .asmdef/.shadergraph are JSON.
    const paths = ["Assets/Foo.prefab.meta", "Assets/Code.asmdef", "Assets/S.shadergraph", "Assets/T.png"];
    document.body.innerHTML = paths
      .map(
        (p) => `<div class="file">
          <div class="file-header" data-path="${p}"></div>
          <div class="js-file-content">raw diff</div>
        </div>`,
      )
      .join("");
    expect(scanUnityFiles(document)).toEqual([]);
  });

  it("is harmless when the expected structure is missing (defensive selectors)", () => {
    document.body.innerHTML = "<div>totally different markup</div>";
    expect(scanUnityFiles(document)).toEqual([]);
  });
});

// Captured shape of GitHub's react diff UI (login-gated rollout): hashed CSS-module classes,
// path only as LRM-wrapped header text, no data-path attribute anywhere.
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
          <div class="Diff-module__diffContent">raw diff</div>
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
          <div class="Diff-module__diffContent">raw diff</div>
        </div>
      </div>
    </div>
  </div>
`;

describe("scanUnityFiles (react ui)", () => {
  it("finds unity files by header text and strips bidi marks", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual(["Assets/Foo.prefab"]);
  });

  it("reads the renamed-to path from the visually hidden span", () => {
    // Renames concatenate visible text and sr-only "OLD renamed to NEW" in textContent,
    // so the sr-only form must win when present.
    document.body.innerHTML = REACT_FIXTURE.replace(
      "<code>‎Assets/Foo.prefab‎</code>",
      '<code>‎Assets/{Old.prefab → New.prefab}‎<span class="sr-only">Assets/Old.prefab renamed to Assets/New.prefab</span></code>',
    );
    expect(scanUnityFiles(document).map((e) => e.path)).toEqual(["Assets/New.prefab"]);
  });

  it("hides every region child except the header block and our host", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entry = scanUnityFiles(document)[0]!;
    const host = document.createElement("div");
    host.setAttribute("data-prefablens-view", "");
    entry.attachHost(host);
    // Host goes right after the header wrapper, inside the region
    const region = document.querySelector("#diff-aaa111")!;
    expect(region.children[1]).toBe(host);
    entry.setRawHidden(true);
    const body = region.querySelector<HTMLElement>(".Diff-module__diffContent")!;
    expect(body.style.display).toBe("none");
    expect(host.style.display).not.toBe("none");
    expect(region.querySelector<HTMLElement>(".Diff-module__diffHeaderWrapper")!.style.display).not.toBe("none");
    entry.setRawHidden(false);
    expect(body.style.display).toBe("");
  });

  it("re-resolves body nodes on every call because react recreates them", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entry = scanUnityFiles(document)[0]!;
    entry.setRawHidden(true);
    // Simulate a react remount: fresh body node without our inline style
    const region = document.querySelector("#diff-aaa111")!;
    region.querySelector(".Diff-module__diffContent")!.remove();
    const fresh = document.createElement("div");
    fresh.className = "Diff-module__diffContent";
    region.append(fresh);
    entry.setRawHidden(true);
    expect(fresh.style.display).toBe("none");
  });

  it("reports the chevron collapse state", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entry = scanUnityFiles(document)[0]!;
    expect(entry.collapsed()).toBe(false);
    // React swaps the chevron icon when the file is collapsed
    const icon = document.querySelector("#diff-aaa111 .octicon-chevron-down")!;
    icon.setAttribute("class", "octicon octicon-chevron-right");
    expect(entry.collapsed()).toBe(true);
  });

  it("also reads collapse from the header's collapsed module class", () => {
    // Second signal, independent of the icon: github stamps this class on the header row
    document.body.innerHTML = REACT_FIXTURE;
    const entry = scanUnityFiles(document)[0]!;
    const header = document.querySelector("#diff-aaa111 .DiffFileHeader-module__diff-file-header")!;
    header.classList.add("DiffFileHeader-module__collapsed__aB3cD");
    expect(entry.collapsed()).toBe(true);
  });

  it("anchors the global bar on the virtualized list root", () => {
    document.body.innerHTML = REACT_FIXTURE;
    const entry = scanUnityFiles(document)[0]!;
    expect(entry.globalAnchor()).toBe(document.querySelector('[data-testid="progressive-diffs-list"]'));
  });

  it("is harmless when the react structure is missing pieces", () => {
    document.body.innerHTML = '<div role="region" id="diff-x"><div>no header</div></div>';
    expect(scanUnityFiles(document)).toEqual([]);
  });
});
