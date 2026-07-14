import { defineConfig } from "vitest/config";

export default defineConfig({
  define: { __API_BASE__: '"https://api.github.com"' },
  test: { include: ["src/**/*.test.ts"] },
});
