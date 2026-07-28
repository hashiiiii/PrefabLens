import { readFileSync } from "node:fs";

export default function (eleventyConfig) {
  eleventyConfig.ignores.add("fixtures/**");
  eleventyConfig.ignores.add("generated/**");
  eleventyConfig.ignores.add("public/**");
  eleventyConfig.addPassthroughCopy({ public: "/" });
  eleventyConfig.addPassthroughCopy({ "generated/assets": "/" });
  eleventyConfig.addGlobalData("pullRequest", () => JSON.parse(readFileSync("generated/pull-request.json", "utf8")));
  // Raw read instead of {% include %}: generated diff content must never be parsed as Liquid
  eleventyConfig.addShortcode("rawHtml", (name) => readFileSync(`generated/raw-html/${name}`, "utf8"));
  return { dir: { output: "dist" } };
}
