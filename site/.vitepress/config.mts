import { defineConfig } from "vitepress";

export default defineConfig({
  title: "PrefabLens",
  description:
    "Human-readable diffs for UnityYAML assets. PrefabLens shows prefab, scene, and other Unity asset changes at the GameObject, component, and field level — on GitHub pull requests, in the CLI, and inside the Unity Editor.",
  base: "/PrefabLens/",
  outDir: "dist",
  // fixtures/ holds UnityYAML corpora plus a README; none of it is site pages.
  srcExclude: ["fixtures/**", "generated/**"],
  head: [["link", { rel: "icon", href: "/PrefabLens/favicon.svg", type: "image/svg+xml" }]],
  themeConfig: {
    nav: [
      { text: "Extension demo", link: "/extension" },
      { text: "CLI demo", link: "/cli" },
      { text: "Unity Editor", link: "/editor" },
    ],
    socialLinks: [{ icon: "github", link: "https://github.com/hashiiiii/PrefabLens" }],
    footer: {
      message: "Apache 2.0 licensed. Fixture assets from the PrefabLens test corpus.",
      copyright: "Source and issues on github.com/hashiiiii/PrefabLens",
    },
  },
});
