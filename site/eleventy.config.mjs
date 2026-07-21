import { readFileSync } from "node:fs";

export default function (eleventyConfig) {
  // fixtures/ is a UnityYAML corpus (plus a README), generated/ is build.mjs
  // output, and public/ is copy-only assets (its .html reports must never be
  // parsed as Liquid); none of them hold site pages. Ignores only stop
  // template processing, so the passthrough copy below still applies.
  eleventyConfig.ignores.add("fixtures/**");
  eleventyConfig.ignores.add("generated/**");
  eleventyConfig.ignores.add("public/**");
  // Runtime assets (reports, demo.js, wasm, fixtures) and static files land at
  // the site root, next to the pages, so page-relative URLs keep working.
  eleventyConfig.addPassthroughCopy({ public: "/" });
  // Raw read instead of {% include %}: generated diff content is UnityYAML and
  // must never be parsed as Liquid.
  eleventyConfig.addShortcode("fragment", (name) => readFileSync(`generated/${name}`, "utf8"));
  return { dir: { output: "dist" } };
}
