---
layout: home
titleTemplate: Human-readable diffs for UnityYAML assets

hero:
  name: PrefabLens
  text: Review prefabs, not YAML noise.
  tagline: PrefabLens shows Unity asset changes as a GameObject / component / field tree — on GitHub pull requests, in your terminal, and inside the Unity Editor. Not just prefabs — it reads every UnityYAML asset.
  actions:
    - theme: brand
      text: Try the extension demo
      link: /extension
    - theme: alt
      text: Try the CLI demo
      link: /cli
    - theme: alt
      text: Unity Editor
      link: /editor

features:
  - title: On GitHub pull requests
    details: A simulated Files changed page running the real renderer and WASM diff engine. Toggle each Unity file between the raw diff and the semantic view.
    link: /extension
    linkText: Extension demo
  - title: In your terminal
    details: The colored tree the prefablens command prints locally, and the self-contained HTML report that --open pops into your browser.
    link: /cli
    linkText: CLI demo
  - title: In the Unity Editor
    details: An Editor window that lists changed UnityYAML assets and shows each one as a semantic diff tree. The CLI binary is downloaded automatically on first use.
    link: /editor
    linkText: Unity Editor
---

<script setup>
import heroDiff from "./generated/hero-diff.html?raw";
</script>

<!-- Same Robot.prefab change, both views produced by the real tooling at
     build time: git for the raw diff, the prefablens binary for the
     semantic report. -->
<div class="compare">
  <div>
    <p class="pane-label">What GitHub shows you</p>
    <div class="window">
      <div class="window-bar">
        <span class="dot"></span><span class="dot"></span><span class="dot"></span>
        <span class="address">git diff — Robot.prefab</span>
      </div>
      <div class="gh-page raw-pane" v-html="heroDiff"></div>
    </div>
  </div>
  <div>
    <p class="pane-label">What PrefabLens shows you</p>
    <div class="window">
      <div class="window-bar">
        <span class="dot"></span><span class="dot"></span><span class="dot"></span>
        <span class="address">prefablens — Robot.prefab</span>
      </div>
      <iframe class="hero-frame" src="./hero-report.html" title="PrefabLens semantic diff"></iframe>
    </div>
  </div>
</div>

## Install

### Chrome extension

[Chrome Web Store](https://chromewebstore.google.com/detail/dlhnalbfkikchkfedfneiimadommcnip) — adds the Raw / Semantic toggle to Unity files on GitHub pull requests.

### CLI — Homebrew

```sh
brew install hashiiiii/tap/prefablens
```

### CLI — Scoop

```sh
scoop bucket add hashiiiii https://github.com/hashiiiii/scoop-bucket
scoop install prefablens
```

### CLI — mise

```sh
mise use -g github:hashiiiii/PrefabLens
```

### Unity Editor — OpenUPM

```sh
openupm add com.hashiiiii.prefablens
```

Without the openupm-cli, install via the Package Manager git URL:
`https://github.com/hashiiiii/PrefabLens.git?path=editor`.

### Everything else

Prebuilt binaries are on the [releases page](https://github.com/hashiiiii/PrefabLens/releases).
