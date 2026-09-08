import { fileURLToPath } from "node:url";
import { type BrowserContext, chromium, expect, test, type Worker } from "@playwright/test";
import { build } from "esbuild";
import type { MergeStore } from "../../src/infrastructure/internal/merge-store";
import type { StorageArea } from "../../src/infrastructure/internal/storage-area";
import { must } from "../../src/internal/must";

declare const cacheRepositories: Record<"guids" | "metaGuids", (area: StorageArea) => MergeStore>;

const DIST = fileURLToPath(new URL("../../dist", import.meta.url));
let repositoryScript: string;
let context: BrowserContext;
let worker: Worker;

test.beforeAll(async () => {
  // Bundle the real repositories into the worker without adding test hooks to the shipped extension.
  const result = await build({
    stdin: {
      contents: `
        export { createChromeGuidRepository as guids } from "./src/infrastructure/clients/chrome-guid-client";
        import { createChromeRepoIndexRepository } from "./src/infrastructure/clients/chrome-repo-index-client";
        export function metaGuids(area) {
          const repo = createChromeRepoIndexRepository(area);
          return { load: repo.loadGuids, save: repo.saveGuids };
        }
      `,
      resolveDir: fileURLToPath(new URL("../../", import.meta.url)),
    },
    bundle: true,
    format: "iife",
    globalName: "cacheRepositories",
    write: false,
  });
  repositoryScript = must(result.outputFiles[0]).text;
});

test.beforeEach(async () => {
  context = await chromium.launchPersistentContext("", {
    channel: "chromium",
    args: [`--disable-extensions-except=${DIST}`, `--load-extension=${DIST}`],
  });
  worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker"));
  await worker.evaluate(repositoryScript);
});

test.afterEach(async () => {
  await context?.close();
});

for (const prefix of ["guids", "metaGuids"] as const) {
  test(`preserves concurrent ${prefix} saves after a Chrome storage failure`, async () => {
    const result = await worker.evaluate(async (prefix) => {
      const area = chrome.storage.local;
      const first = cacheRepositories[prefix](area);
      const second = cacheRepositories[prefix](area);
      await first.save("repro", { stored: "initial" });

      await Promise.all([
        first.save("repro", { a: "first" }),
        first.save("repro", { b: "second" }),
        second.save("repro", { c: "third" }),
      ]);
      const concurrent = await first.load("repro");

      // Exceed Chrome's actual quota so repository error handling runs against a real rejected write.
      const saves = await Promise.allSettled([
        first.save("repro", { oversized: "x".repeat(area.QUOTA_BYTES) }),
        first.save("repro", { d: "after failure" }),
        second.save("repro", { e: "last" }),
      ]);
      return {
        concurrent,
        statuses: saves.map((save) => save.status),
        recovered: await first.load("repro"),
      };
    }, prefix);

    expect(result.concurrent).toEqual({ stored: "initial", a: "first", b: "second", c: "third" });
    expect(result.statuses).toEqual([prefix === "guids" ? "rejected" : "fulfilled", "fulfilled", "fulfilled"]);
    expect(result.recovered).toEqual({
      stored: "initial",
      a: "first",
      b: "second",
      c: "third",
      d: "after failure",
      e: "last",
    });
  });
}
