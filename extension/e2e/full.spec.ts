/// <reference types="node" />
// Runs detection → real background → real WASM → render end-to-end with the actual extension (--load-extension).
// Uses a local HTTP server as "GitHub": the --e2e build bakes __API_BASE__ to this fixed port and
// statically registers the content script for it (see build.mjs), so no dynamic permission grant is needed.

import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { fileURLToPath } from "node:url";
import { type BrowserContext, chromium, expect, test } from "@playwright/test";

const DIST = fileURLToPath(new URL("../dist", import.meta.url));
const fixture = readFileSync(new URL("./fixtures/pr-files.html", import.meta.url), "utf8");

// Matches the port baked into __API_BASE__ by build.mjs --e2e
const PORT = 8471;

// Same minimal prefab as core/tests/wasm_golden.test.mjs: the output is pinned by the golden
const BEFORE = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5
`;
const AFTER = BEFORE.replace("0.5", "0.8");
// 26MB with a UnityYAML head but no documents trips the 25MB guard; after
// force, the content sniff passes and it finishes cheaply with an empty diff
const BIG = `%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n${"x".repeat(26 * 1024 * 1024)}`;

function startServer(): Promise<Server> {
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const send = (body: string, type: string): void => {
      res.writeHead(200, { "content-type": type });
      res.end(body);
    };
    const json = (body: unknown): void => send(JSON.stringify(body), "application/json");
    // Every ref pair shares one empty tree: blob fetches then fall back to the contents API below
    if (url.pathname.startsWith("/repos/o/r/git/trees/")) return json({ truncated: false, tree: [] });
    switch (url.pathname) {
      case "/o/r/pull/1/files":
        return send(fixture, "text/html");
      case "/repos/o/r/pulls/1/files":
        return json([
          { filename: "Assets/Foo.prefab", status: "modified" },
          { filename: "Assets/Big.unity", status: "modified" },
          { filename: "Assets/Baked.asset", status: "modified" },
        ]);
      case "/repos/o/r/pulls/1":
        return json({ base: { sha: "B" }, head: { sha: "H" } });
      case "/repos/o/r/compare/B...H":
        return json({ merge_base_commit: { sha: "MB" } });
      // Commit page: same classic DOM, but discovery goes through the commit API (base = first parent)
      case "/o/r/commit/abcdef0":
        return send(fixture, "text/html");
      case "/repos/o/r/commits/abcdef0":
        return json({
          sha: "HC",
          parents: [{ sha: "PC" }],
          files: [{ filename: "Assets/Foo.prefab", status: "modified" }],
        });
      // Compare page: merge base from the compare API, head resolved via the sha media type
      case "/o/r/compare/main...topic":
        return send(fixture, "text/html");
      case "/repos/o/r/compare/main...topic":
        return json({
          merge_base_commit: { sha: "MC" },
          files: [{ filename: "Assets/Foo.prefab", status: "modified" }],
        });
      case "/repos/o/r/commits/topic":
        return send("HT\n", "application/vnd.github.sha");
      case "/repos/o/r/contents/Assets/Foo.prefab": {
        // MB/PC/MC are the base side of the pull/commit/compare flows respectively
        const ref = url.searchParams.get("ref") ?? "";
        return send(["MB", "PC", "MC"].includes(ref) ? BEFORE : AFTER, "application/vnd.github.raw+json");
      }
      case "/repos/o/r/contents/Assets/Big.unity":
        return send(BIG, "application/vnd.github.raw+json");
      // A binary-serialized .asset (LightingDataAsset etc.): passes the path
      // prefilter, must be rejected by the real wasm content sniff.
      case "/repos/o/r/contents/Assets/Baked.asset":
        return send("\x00\x01PK-binary-payload", "application/vnd.github.raw+json");
      case "/search/code":
        return json({ items: [{ path: "Assets/Scripts/Sound.cs.meta" }] });
      case "/graphql":
        return json({ data: { repository: {} } });
      default:
        res.writeHead(404);
        res.end();
    }
  });
  return new Promise((resolve) => {
    server.listen(PORT, "127.0.0.1", () => resolve(server));
  });
}

let context: BrowserContext;
let server: Server;

test.beforeAll(async () => {
  server = await startServer();
  context = await chromium.launchPersistentContext("", {
    channel: "chromium", // the chromium channel is required to use extensions headlessly
    args: [`--disable-extensions-except=${DIST}`, `--load-extension=${DIST}`],
  });
  let sw = context.serviceWorkers()[0];
  sw ??= await context.waitForEvent("serviceworker");
  const extensionId = new URL(sw.url()).host;

  // Seed the token directly in storage (sign-in is the only UI path; the fake server ignores its value)
  const options = await context.newPage();
  await options.goto(`chrome-extension://${extensionId}/options.html`);
  await options.evaluate(() => chrome.storage.local.set({ pat: "tok" }));
  await options.close();
});

test.afterAll(async () => {
  await context?.close();
  server?.close();
});

test("renders a real wasm diff with code-search guid resolution", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  // Via Code Search, guid def resolves to Sound.cs, so the script name shows instead of the type name
  await expect(view).toContainText("Sound");
  await expect(view).toContainText("Volume");
  await expect(view).toContainText("0.5");
  await expect(view).toContainText("0.8");
  await page.close();
});

test("serves a commit page against the commit API", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/commit/abcdef0`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  // BEFORE at the first parent, AFTER at the commit itself: the same real-wasm diff as the PR flow
  await expect(view).toContainText("0.5");
  await expect(view).toContainText("0.8");
  await page.close();
});

test("serves a compare page from the merge base", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/compare/main...topic`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("0.5");
  await expect(view).toContainText("0.8");
  await page.close();
});

test("rejects a binary .asset through the real wasm sniff", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Baked.asset"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("not a text-serialized Unity asset", { timeout: 30_000 });
  await page.close();
});

test("gates oversized files behind an explicit render click", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Big.unity"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("Large file (52 MB)", { timeout: 30_000 });
  await view.getByRole("button", { name: "Render anyway" }).click();
  await expect(view).toContainText("No semantic changes", { timeout: 30_000 });
  await page.close();
});
