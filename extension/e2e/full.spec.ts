/// <reference types="node" />
// Runs detection → real background → real WASM → render end-to-end with the actual extension (--load-extension).
// Uses a local HTTP server as "GitHub": the --e2e build bakes __API_BASE__ and __GITHUB_ORIGIN__ to this
// fixed port and statically registers the content script for it (see build.mjs), so no dynamic
// permission grant is needed. Auth is the PR-panel device flow against the local OAuth routes.

import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { fileURLToPath } from "node:url";
import { type BrowserContext, chromium, expect, test } from "@playwright/test";

const DIST = fileURLToPath(new URL("../dist", import.meta.url));
const fixture = readFileSync(new URL("./fixtures/pr-files.html", import.meta.url), "utf8");
const reactFixture = readFileSync(new URL("./fixtures/pr-files-react.html", import.meta.url), "utf8");

// Matches the port baked into __API_BASE__ by build.mjs --e2e
const PORT = 8471;

type ServerState = {
  requests: string[];
  failNextFile: boolean;
};

const state: ServerState = {
  requests: [],
  failNextFile: false,
};

let guidSearchGate: Promise<void> | undefined;
let releaseGuidSearch: (() => void) | undefined;

function holdGuidSearch(): void {
  guidSearchGate = new Promise((resolve) => {
    releaseGuidSearch = resolve;
  });
}

function releaseHeldGuidSearch(): void {
  releaseGuidSearch?.();
  guidSearchGate = undefined;
  releaseGuidSearch = undefined;
}

// Same minimal prefab as core/tests/wasm_golden.test.mjs: the output is pinned by the golden
const BEFORE = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5
`;
const AFTER = BEFORE.replace("0.5", "0.8");
// 26MB with a UnityYAML head but no documents trips the 25MB guard. After
// force, the content sniff passes and it finishes cheaply with an empty diff.
const BIG = `%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n${"x".repeat(26 * 1024 * 1024)}`;

function startServer(): Promise<Server> {
  // One-shot 429 for the backoff test: a new server instance resets it
  let servedRateLimit = false;
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    state.requests.push(`${req.method ?? "GET"} ${url.pathname}${url.search}`);
    const send = (body: string, type: string): void => {
      res.writeHead(200, { "content-type": type });
      res.end(body);
    };
    const json = (body: unknown): void => send(JSON.stringify(body), "application/json");
    // Every ref pair shares one empty tree: blob fetches then use the contents API below instead
    if (url.pathname.startsWith("/repos/o/r/git/trees/")) return json({ truncated: false, tree: [] });
    switch (url.pathname) {
      case "/o/r/pull/1/files":
        return send(fixture, "text/html");
      case "/o/r/pull/2/files":
        return send(reactFixture, "text/html");
      case "/repos/o/r/pulls/1/files":
        return json([
          { filename: "Assets/Foo.prefab", status: "modified" },
          { filename: "Assets/Big.unity", status: "modified" },
          { filename: "Assets/Baked.asset", status: "modified" },
        ]);
      case "/repos/o/r/pulls/1":
        return json({ base: { sha: "B" }, head: { sha: "H" } });
      case "/repos/o/r/pulls/2/files":
        return json([{ filename: "Assets/Foo.prefab", status: "modified" }]);
      case "/repos/o/r/pulls/2":
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
      case "/o/r/commit/e2e5000":
        return send(fixture, "text/html");
      case "/repos/o/r/commits/e2e5000":
        return json({
          sha: "H500",
          parents: [{ sha: "P500" }],
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
      // Backoff commit: commit pages have no prefetch, so the toggle's own attempt receives the 429
      case "/o/r/commit/e2e4290":
        return send(fixture, "text/html");
      case "/repos/o/r/commits/e2e4290":
        return json({
          sha: "H429",
          parents: [{ sha: "P429" }],
          files: [{ filename: "Assets/Foo.prefab", status: "modified" }],
        });
      case "/repos/o/r/contents/Assets/Foo.prefab": {
        if (state.failNextFile && url.pathname === "/repos/o/r/contents/Assets/Foo.prefab") {
          state.failNextFile = false;
          res.writeHead(500);
          return res.end();
        }
        // MB/PC/MC/P429 are the base side of the pull/commit/compare/backoff flows respectively
        const ref = url.searchParams.get("ref") ?? "";
        if (ref === "H429" && !servedRateLimit) {
          servedRateLimit = true;
          res.writeHead(429, { "retry-after": "1" });
          return res.end("rate limit");
        }
        return send(
          ["MB", "PC", "MC", "P429", "P500"].includes(ref) ? BEFORE : AFTER,
          "application/vnd.github.raw+json",
        );
      }
      case "/repos/o/r/contents/Assets/Late.prefab": {
        const ref = url.searchParams.get("ref") ?? "";
        return send(
          ["MB", "PC", "MC", "P429", "P500"].includes(ref) ? BEFORE : AFTER,
          "application/vnd.github.raw+json",
        );
      }
      case "/repos/o/r/contents/Assets/Big.unity":
        return send(BIG, "application/vnd.github.raw+json");
      // A binary-serialized .asset (for example LightingDataAsset): it passes the
      // path prefilter, and the real wasm content sniff must reject it.
      case "/repos/o/r/contents/Assets/Baked.asset":
        return send("\x00\x01PK-binary-payload", "application/vnd.github.raw+json");
      case "/search/code":
        if (guidSearchGate) await guidSearchGate;
        return json({ items: [{ path: "Assets/Scripts/Sound.cs.meta" }] });
      case "/graphql":
        return json({ data: { repository: {} } });
      case "/login/device/code":
        return json({
          device_code: "dc-e2e",
          user_code: "ABCD-1234",
          verification_uri: `http://127.0.0.1:${PORT}/login/device`,
          interval: 0,
          expires_in: 900,
        });
      case "/login/oauth/access_token":
        // The first poll succeeds: no human Authorize step. The extension still runs the full poll loop.
        return json({ access_token: "e2e-token" });
      case "/login/device":
        return send("<!doctype html><title>device</title>", "text/html");
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

async function setLocalStorage(values: Record<string, unknown>): Promise<void> {
  const worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker"));
  await worker.evaluate((next) => chrome.storage.local.set(next), values);
}

async function clearLocalStorage(): Promise<void> {
  const worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker"));
  await worker.evaluate(() => chrome.storage.local.clear());
}

test.beforeAll(async () => {
  server = await startServer();
  context = await chromium.launchPersistentContext("", {
    channel: "chromium", // the chromium channel is required to use extensions headlessly
    args: [`--disable-extensions-except=${DIST}`, `--load-extension=${DIST}`],
  });
  if (!context.serviceWorkers()[0]) await context.waitForEvent("serviceworker");
});

test.afterAll(async () => {
  await context?.close();
  server?.close();
});

test.beforeEach(async () => {
  releaseHeldGuidSearch();
  await clearLocalStorage();
  await setLocalStorage({ accessToken: "e2e-token" });
});

test("starts PR prefetch before a manual semantic request", async () => {
  state.requests = [];
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  await expect.poll(() => state.requests.join("\n")).toContain("GET /repos/o/r/pulls/1/files?per_page=100&page=1");
  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await expect(header.getByRole("button", { name: "Semantic" })).toBeVisible();
  await page.close();
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
  await expect(view).toContainText("not a Unity asset file in text format", { timeout: 30_000 });
  await page.close();
});

test("recovers from a 429 through the real queue backoff", async () => {
  // The wiring regression that this test pins: bare fetch resolved on a 429.
  // The queue's backoff never ran, and the panel showed the rate-limit error.
  // The server returns one 429 for the head blob (retry-after: 1). The shipped
  // pipeline (background → container → createQueuedFetch → queue) must pause and retry.
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/commit/e2e4290`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("0.5", { timeout: 15_000 });
  await expect(view).toContainText("0.8");
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

test("hides the semantic view when the classic file collapses", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("Sound");

  const file = page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"])');
  await file.evaluate((element) => element.classList.remove("Details--on", "open"));
  await expect(view).toBeHidden();

  await file.evaluate((element) => element.classList.add("Details--on", "open"));
  await expect(view).toBeVisible();
  await page.close();
});

test("attaches to a Unity file added after the initial SPA scan", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  await page.evaluate(() => {
    const file = document.createElement("div");
    file.className = "file Details Details--on open";
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content Details-content--hidden">raw diff</div>';
    document.body.append(file);
  });

  const header = page.locator('.file-header[data-path="Assets/Late.prefab"]');
  await expect(header.getByRole("button", { name: "Semantic" })).toBeVisible();
  await page.close();
});

test("recovers when a later semantic request succeeds", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/commit/e2e5000`);
  state.failNextFile = true;

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  const view = page.locator("[data-prefablens-view]");
  await header.getByRole("button", { name: "Semantic" }).click();
  await expect(view).toContainText("Could not get file contents from GitHub.");

  await header.getByRole("button", { name: "Raw" }).click();
  await header.getByRole("button", { name: "Semantic" }).click();
  await expect(view).toContainText("Sound");
  await page.close();
});

test("applies the persisted semantic default to current and later files", async () => {
  await setLocalStorage({ accessToken: "e2e-token", viewMode: "semantic" });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  await expect(page.locator("[data-prefablens-view]")).toHaveCount(3);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();
  const global = page.locator("[data-prefablens-global]");
  await expect(global.locator('button[data-view="semantic"]')).toHaveAttribute("aria-pressed", "true");

  await page.evaluate(() => {
    const file = document.createElement("div");
    file.className = "file Details Details--on open";
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content Details-content--hidden">raw diff</div>';
    document.body.append(file);
  });
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(4);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Late.prefab"]) .js-file-content')).toBeHidden();
  await page.close();
});

test("clears per-file overrides after a global selection", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const global = page.locator("[data-prefablens-global]");
  await expect(global).toHaveCount(1);
  await expect(
    page.locator('[data-prefablens-global] + .file .file-header[data-path="Assets/Foo.prefab"]'),
  ).toHaveCount(1);

  await global.getByRole("button", { name: "Semantic" }).click();
  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Raw" }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeVisible();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Big.unity"]) .js-file-content')).toBeHidden();

  await global.getByRole("button", { name: "Raw" }).click();
  await global.getByRole("button", { name: "Semantic" }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();
  await page.close();
});

test("renders a semantic diff on the React layout", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

  const header = page.locator('#diff-aaa111 [class*="diff-file-header"]');
  await expect(header.getByRole("button", { name: "Semantic" })).toBeVisible();
  await expect(page.locator("#diff-ccc333 [data-prefablens-toggle]")).toHaveCount(0);
  await header.getByRole("button", { name: "Semantic" }).click();

  const view = page.locator("#diff-aaa111 [data-prefablens-view]");
  await expect(view).toContainText("Sound");
  await expect(page.locator("#diff-aaa111 .border.rounded-bottom-2")).toBeHidden();
  await header.getByRole("button", { name: "Raw" }).click();
  await expect(page.locator("#diff-aaa111 .border.rounded-bottom-2")).toBeVisible();
  await expect(view).toBeHidden();
  await page.close();
});

test("hides a remounted raw body before paint", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

  const header = page.locator('#diff-aaa111 [class*="diff-file-header"]');
  await header.getByRole("button", { name: "Semantic" }).click();
  await expect(page.locator("#diff-aaa111 [data-prefablens-view]")).toContainText("Sound");

  const displayRightAfterAppend = await page.evaluate(() => {
    const region = document.querySelector("#diff-aaa111");
    if (!region) throw new Error("diff region missing");
    region.querySelector(".border.rounded-bottom-2")?.remove();
    const fresh = document.createElement("div");
    fresh.className = "border position-relative rounded-bottom-2";
    fresh.textContent = "raw github diff table";
    region.append(fresh);
    return getComputedStyle(fresh).display;
  });
  expect(displayRightAfterAppend).toBe("none");
  await page.close();
});

test("mounts the global toggle outside the recycled item", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

  await expect(page.locator("[data-prefablens-global]")).toHaveCount(1);
  await expect(page.locator('[data-prefablens-global] + [data-testid="progressive-diffs-list"]')).toHaveCount(1);
  await page.close();
});

test("re-hides a remounted body after collapse", async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

  const header = page.locator('#diff-aaa111 [class*="diff-file-header"]');
  await header.getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("#diff-aaa111 [data-prefablens-view]");
  await expect(view).toContainText("Sound");

  await page.evaluate(() => {
    const region = document.querySelector("#diff-aaa111");
    if (!region) throw new Error("diff region missing");
    region.querySelector(".octicon-chevron-down")?.setAttribute("class", "octicon octicon-chevron-right");
    region.querySelector(".border.rounded-bottom-2")?.remove();
  });
  await expect(view).toBeHidden();

  await page.evaluate(() => {
    const region = document.querySelector("#diff-aaa111");
    if (!region) throw new Error("diff region missing");
    region.querySelector(".octicon-chevron-right")?.setAttribute("class", "octicon octicon-chevron-down");
    const body = document.createElement("div");
    body.className = "border position-relative rounded-bottom-2";
    body.textContent = "raw github diff table";
    region.append(body);
  });
  await expect(view).toBeVisible();
  await expect(page.locator("#diff-aaa111 .border.rounded-bottom-2")).toBeHidden();
  await page.close();
});

test("applies a final GUID push after a React body remount", async () => {
  holdGuidSearch();
  const page = await context.newPage();
  try {
    await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

    const header = page.locator('#diff-aaa111 [class*="diff-file-header"]');
    await header.getByRole("button", { name: "Semantic" }).click();
    const view = page.locator("#diff-aaa111 [data-prefablens-view]");
    await expect(view).toContainText("Resolving 1 reference");

    await page.evaluate(() => {
      const region = document.querySelector("#diff-aaa111");
      if (!region) throw new Error("diff region missing");
      region.querySelector("[data-prefablens-view]")?.remove();
      region.querySelector(".border.rounded-bottom-2")?.remove();
      const body = document.createElement("div");
      body.className = "border position-relative rounded-bottom-2";
      body.textContent = "remounted raw github diff table";
      region.append(body);
    });

    await expect(view).toContainText("Resolving 1 reference");
    releaseHeldGuidSearch();
    await expect(view).toContainText("Sound");
  } finally {
    releaseHeldGuidSearch();
    await page.close();
  }
});

test("reattaches a fully remounted file with the semantic default", async () => {
  await setLocalStorage({ accessToken: "e2e-token", viewMode: "semantic" });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/2/files`);

  await expect(page.locator("[data-prefablens-view]")).toHaveCount(2);
  await page.evaluate(() => {
    const entry = document.querySelector("#diff-aaa111")?.parentElement;
    if (!entry) throw new Error("diff region missing");
    const clone = entry.cloneNode(true) as HTMLElement;
    clone.querySelector("[data-prefablens-view]")?.remove();
    clone.querySelector("[data-prefablens-toggle]")?.remove();
    clone.querySelector("[data-prefablens]")?.removeAttribute("data-prefablens");
    for (const element of clone.querySelectorAll<HTMLElement>("[style]")) element.style.display = "";
    entry.replaceWith(clone);
  });

  await expect(page.locator("#diff-aaa111 [data-prefablens-view]")).toBeVisible();
  await expect(page.locator("#diff-aaa111 .border.rounded-bottom-2")).toBeHidden();
  await page.close();
});

test("signs in with GitHub through Device Flow", async () => {
  await clearLocalStorage();
  state.requests = [];
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORT}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("[data-prefablens-view]");
  await view.getByRole("button", { name: "Sign in with GitHub" }).click();
  await expect
    .poll(() =>
      ["POST /login/device/code", "POST /login/oauth/access_token"].every((route) => state.requests.includes(route)),
    )
    .toBe(true);
  await expect(view).toContainText("Sound", { timeout: 15_000 });
  await expect(view.getByRole("button", { name: "Sign in with GitHub" })).toHaveCount(0);

  for (const other of context.pages()) {
    if (other !== page && other.url().includes("/login/device")) await other.close();
  }
  await page.close();
});
