/// <reference types="node" />

import { readFileSync } from "node:fs";
import { expect, type Page, test } from "@playwright/test";

const fixture = readFileSync(new URL("./fixtures/pr-files.html", import.meta.url), "utf8");

// The content script reads viewMode from chrome.storage.local on startup.
// If the stub lacks storage, init throws and breaks every test, so always provide it.
function stubChrome(page: Page, res: unknown, viewMode?: string) {
  return page.addInitScript(
    ({ res, viewMode }) => {
      (window as unknown as Record<string, unknown>).chrome = {
        runtime: {
          sendMessage: (msg: { type?: string }) =>
            msg?.type === "semanticDiff" ? Promise.resolve(res) : Promise.resolve(),
          onMessage: { addListener: () => {} },
        },
        storage: {
          local: {
            get: () => Promise.resolve(viewMode ? { viewMode } : {}),
            set: () => Promise.resolve(),
          },
          onChanged: { addListener: () => {} },
        },
      };
    },
    { res, viewMode },
  );
}

const cannedResponse = {
  ok: true,
  json: {
    schema: "prefablens.diff.v2",
    unresolvedGuids: ["def"],
    resolved: {},
    roots: [],
    loose: [
      {
        kind: "component",
        fileId: "11400000",
        classId: 114,
        typeName: "MonoBehaviour",
        scriptGuid: "def",
        className: null,
        status: "modified",
        fields: [{ path: "volume", status: "modified", before: "0.5", after: "0.8" }],
      },
    ],
  },
};

test("detects a Unity file, toggles to Semantic, renders the tree", async ({ page }) => {
  // The content script inspects the URL (/pull/N/files): serve the fixture at a PR URL
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  // Stub background with a fixed response (handler.test.ts covers the real path here)
  await stubChrome(page, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  // Detection: the toggle is attached only to Unity files
  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await expect(unityHeader.getByRole("button", { name: "Semantic" })).toBeVisible();
  const mdHeader = page.locator('.file-header[data-path="README.md"]');
  await expect(mdHeader.locator("[data-prefablens-toggle]")).toHaveCount(0);

  // Toggle → render (Playwright pierces open shadow roots automatically)
  await unityHeader.getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("MonoBehaviour");
  await expect(view).toContainText("volume");
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();

  // Can switch back to Raw
  await unityHeader.getByRole("button", { name: "Raw" }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeVisible();
  await expect(view).toBeHidden();
});

test("github's file collapse hides the semantic view too", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await stubChrome(page, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await unityHeader.getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("[data-prefablens-view]");
  await expect(view).toContainText("MonoBehaviour");

  // Collapse: github's details-behavior only toggles these classes on .file, so the
  // semantic host must opt into the same Primer CSS that hides .js-file-content
  const file = page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"])');
  await file.evaluate((el) => el.classList.remove("Details--on", "open"));
  await expect(view).toBeHidden();

  // Expand again: the semantic view comes back without touching the toggle
  await file.evaluate((el) => el.classList.add("Details--on", "open"));
  await expect(view).toBeVisible();
});

test("sends a prefetch message on pr page arrival", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await stubChrome(page, cannedResponse);
  // Wrap stubChrome's sendMessage to record calls
  await page.addInitScript(() => {
    const w = window as unknown as {
      chrome: { runtime: { sendMessage: (m: unknown) => Promise<unknown> } };
      __sent: unknown[];
    };
    w.__sent = [];
    const orig = w.chrome.runtime.sendMessage;
    w.chrome.runtime.sendMessage = (m: unknown) => {
      w.__sent.push(m);
      return orig(m);
    };
  });
  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (window as unknown as { __sent: Array<{ type?: string }> }).__sent.filter((m) => m?.type === "prefetch")
            .length,
      ),
    )
    .toBe(1); // only once per PR
});

test("attaches toggles to files added after the initial scan (SPA lazy loading)", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await stubChrome(page, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  // GitHub lazy-loads Files changed on scroll: the MutationObserver picks up additions after the initial scan
  await page.evaluate(() => {
    const file = document.createElement("div");
    file.className = "file";
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content">raw diff</div>';
    document.body.append(file);
  });
  const lateHeader = page.locator('.file-header[data-path="Assets/Late.prefab"]');
  await expect(lateHeader.getByRole("button", { name: "Semantic" })).toBeVisible();
});

test("recovers after an error response", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  // First call returns a pat-missing error, later calls return a normal response (verifies errors are not cached and are re-fetched)
  // Use a dedicated stub for the counter, but keep storage/onMessage the same shape as stubChrome so init does not throw
  await page.addInitScript((res) => {
    (window as unknown as Record<string, unknown>).__prefablensCalls = 0;
    (window as unknown as Record<string, unknown>).chrome = {
      runtime: {
        // Exclude prefetch from the count: attach() always sends one on pull-page arrival, so
        // a naive count-everything would offset the first semanticDiff and break the error→success check
        sendMessage: (msg: { type?: string }) => {
          if (msg?.type !== "semanticDiff") return Promise.resolve();
          const w = window as unknown as Record<string, number>;
          const call = w.__prefablensCalls ?? 0;
          w.__prefablensCalls = call + 1;
          return Promise.resolve(call === 0 ? { ok: false, error: "pat-missing" } : res);
        },
        onMessage: { addListener: () => {} },
      },
      storage: {
        local: {
          get: () => Promise.resolve({}),
          set: () => Promise.resolve(),
        },
        onChanged: { addListener: () => {} },
      },
    };
  }, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  const view = page.locator("[data-prefablens-view]");

  // First toggle: shows the error
  await unityHeader.getByRole("button", { name: "Semantic" }).click();
  await expect(view).toContainText("Sign in with GitHub");

  // Re-toggling Raw → Semantic re-fetches and recovers to the normal result
  await unityHeader.getByRole("button", { name: "Raw" }).click();
  await unityHeader.getByRole("button", { name: "Semantic" }).click();
  await expect(view).toContainText("MonoBehaviour");
});

test("applies the persisted semantic default to every unity file and late additions", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await stubChrome(page, cannedResponse, "semantic"); // the previous choice was saved as semantic

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  // All three Unity files render as semantic without a click
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(3);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();

  // The global toggle also reflects the default and appears in the Semantic pressed state
  const global = page.locator("[data-prefablens-global]");
  await expect(global.locator('button[data-view="semantic"]')).toHaveAttribute("aria-pressed", "true");

  // A lazy-loaded file also inherits the default (the crux of preventing "pressed but still raw")
  await page.evaluate(() => {
    const file = document.createElement("div");
    file.className = "file";
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content">raw diff</div>';
    document.body.append(file);
  });
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(4);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Late.prefab"]) .js-file-content')).toBeHidden();
});

test("global toggle switches all files and resets per-file overrides", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await stubChrome(page, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  // The global toggle is injected exactly once, right before the first Unity file
  const global = page.locator("[data-prefablens-global]");
  await expect(global).toHaveCount(1);

  // Position contract: the bar goes right before the first Unity file's .file container
  await expect(
    page.locator('[data-prefablens-global] + .file .file-header[data-path="Assets/Foo.prefab"]'),
  ).toHaveCount(1);

  // Global Semantic → all Unity files switch (README is excluded)
  await global.getByRole("button", { name: "Semantic" }).click();
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(3);

  // Per-file override to Raw → only that file reverts to raw
  const fooHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await fooHeader.getByRole("button", { name: "Raw" }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeVisible();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Big.unity"]) .js-file-content')).toBeHidden();

  // Toggling global Raw → Semantic resets overrides, so all files always line up
  await global.getByRole("button", { name: "Raw" }).click();
  await global.getByRole("button", { name: "Semantic" }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();
});

test("signs in with the device flow from the PR page and auto-recovers", async ({ page }) => {
  await page.route("**/pull/1/files", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  // GitHub OAuth endpoints stubbed at the network layer (the content script calls them same-origin in production).
  // The token stays pending until the test flips `authorized`, playing the user's Authorize click on GitHub.
  let authorized = false;
  await page.route("**/login/device/code", (route) =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        device_code: "dc1",
        user_code: "ABCD-1234",
        verification_uri: "https://github.com/login/device",
        interval: 0,
        expires_in: 900,
      }),
    }),
  );
  await page.route("**/login/oauth/access_token", (route) =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify(authorized ? { access_token: "tok123" } : { error: "authorization_pending" }),
    }),
  );
  // Stateful chrome stub: pat-gated responses like the real background, and set() fires onChanged
  // listeners so the auto-retry path is exercised end to end.
  await page.addInitScript((res) => {
    const data: Record<string, unknown> = {};
    const listeners: Array<(changes: Record<string, { newValue?: unknown }>, area: string) => void> = [];
    const w = window as unknown as Record<string, unknown>;
    w.__opened = [];
    window.open = (url?: string | URL) => {
      (w.__opened as string[]).push(String(url));
      return null;
    };
    w.chrome = {
      runtime: {
        sendMessage: (msg: { type?: string }) => {
          if (msg?.type !== "semanticDiff") return Promise.resolve();
          return Promise.resolve(data.pat ? res : { ok: false, error: "pat-missing" });
        },
        onMessage: { addListener: () => {} },
      },
      storage: {
        local: {
          get: (keys: string[]) =>
            Promise.resolve(Object.fromEntries(keys.filter((k) => k in data).map((k) => [k, data[k]]))),
          set: (items: Record<string, unknown>) => {
            const changes = Object.fromEntries(Object.entries(items).map(([k, v]) => [k, { newValue: v }]));
            Object.assign(data, items);
            for (const listener of listeners) listener(changes, "local");
            return Promise.resolve();
          },
          remove: (key: string) => {
            delete data[key];
            return Promise.resolve();
          },
        },
        onChanged: { addListener: (listener: (typeof listeners)[number]) => void listeners.push(listener) },
      },
    };
  }, cannedResponse);

  await page.goto("https://prefablens.test/owner/repo/pull/1/files");
  await page.addScriptTag({ path: "dist/content.js" });

  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  const view = page.locator("[data-prefablens-view]");

  await unityHeader.getByRole("button", { name: "Semantic" }).click();
  await view.getByRole("button", { name: "Sign in with GitHub" }).click();

  // While polling: the user code stays visible and the verification tab was opened.
  await expect(view).toContainText("ABCD-1234");
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __opened: string[] }).__opened))
    .toEqual(["https://github.com/login/device"]);

  // The user authorizes on GitHub → token lands → the stuck panel retries without any manual toggle.
  authorized = true;
  await expect(view).toContainText("MonoBehaviour");
});
