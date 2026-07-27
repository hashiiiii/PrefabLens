import { readFileSync } from "node:fs";

export default function (eleventyConfig) {
  eleventyConfig.ignores.add("fixtures/**");
  eleventyConfig.ignores.add("generated/**");
  eleventyConfig.ignores.add("public/**");
  eleventyConfig.addPassthroughCopy({ public: "/" });
  eleventyConfig.addPassthroughCopy({ "generated/assets": "/" });
  // Raw read instead of {% include %}
  eleventyConfig.addShortcode("fragment", (name) => readFileSync(`generated/fragments/${name}`, "utf8"));
  return { dir: { output: "dist" } };
}
