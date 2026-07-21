---
title: Extension demo
---

<script setup>
import { onMounted } from "vue";
import prFiles from "./generated/pr-files.html?raw";

// demo.js runs main() at evaluation time and scans the DOM for
// .file-header[data-before]/[data-after], so it must load after this page's
// markup is mounted. A page-relative src keeps the /PrefabLens/ base and the
// script's own relative fetches (fixtures/, guids.json, prefablens.wasm)
// working in dev and prod alike. Re-appending on every mount is deliberate:
// after an SPA navigation the mock is re-rendered bare and needs a fresh scan.
onMounted(() => {
  const script = document.createElement("script");
  script.src = "./demo.js";
  document.body.appendChild(script);
});
</script>

# Extension demo

<div class="demo-banner">
  <strong>Simulated pull request page.</strong>
  <span>
    Not GitHub — but the Raw / Semantic toggle and the semantic views below are the real
    PrefabLens extension code and WASM diff engine running in your browser, exactly as they
    do on github.com.
  </span>
</div>

<div class="window">
  <div class="window-bar">
    <span class="dot"></span><span class="dot"></span><span class="dot"></span>
    <span class="address">github.com/you/unity-project/pull/2/files</span>
  </div>
  <div class="gh-page">
    <h1 class="pr-header">Rebalance robot physics and rework the playground scene <span class="pr-number">#2</span></h1>
    <div v-html="prFiles"></div>
  </div>
</div>
