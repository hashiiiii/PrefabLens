import { defineConfig } from "vitest/config";

export default defineConfig({
  define: {
    __API_BASE__: '"https://api.github.com"',
    __GITHUB_ORIGIN__: '"https://github.com"',
  },
  test: {
    include: ["test/**/*.test.ts"],
    // suppress console log
    // see: https://vitest.dev/config/onconsolelog.html
    onConsoleLog: () => false,
  },
});
