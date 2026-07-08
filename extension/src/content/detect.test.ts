// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { parsePrPage, parsePrUrl, scanUnityFiles } from "./detect";

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

describe("parsePrUrl", () => {
  it("matches the PR files tab", () => {
    expect(parsePrUrl("/owner/repo/pull/42/files")).toEqual({ owner: "owner", repo: "repo", prNumber: 42 });
    expect(parsePrUrl("/owner/repo/pull/42/files/abc123")).toEqual({ owner: "owner", repo: "repo", prNumber: 42 });
  });
  it("rejects other pages", () => {
    expect(parsePrUrl("/owner/repo/pull/42")).toBeNull();
    expect(parsePrUrl("/owner/repo/blob/main/a.prefab")).toBeNull();
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
    expect(entries[0]?.content.classList.contains("js-file-content")).toBe(true);
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
