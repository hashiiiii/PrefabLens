/// <reference types="node" />

import { readFileSync } from "node:fs";
import { expect, type Page, test } from "@playwright/test";

const fixture = readFileSync(new URL("./fixtures/pr-files-react.html", import.meta.url), "utf8");

// Same chrome stub as smoke.spec.ts: storage is mandatory for init, semanticDiff is canned.
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
    unresolvedGuids: [],
    resolved: {},
    roots: [],
    loose: [
      {
        kind: "component",
        fileId: "11400000",
        classId: 114,
        typeName: "MonoBehaviour",
        scriptGuid: null,
        className: null,
        status: "modified",
        fields: [{ path: "volume", status: "modified", before: "0.5", after: "0.8" }],
      },
    ],
  },
};

// The react ui serves the files tab at /changes, so every test drives that URL.
async function open(page: Page) {
  await page.route("**/pull/1/changes", (route) => route.fulfill({ body: fixture, contentType: "text/html" }));
  await page.goto("https://prefablens.test/owner/repo/pull/1/changes");
  await page.addScriptTag({ path: "dist/content.js" });
}

const fooHeader = (page: Page) => page.locator('#diff-aaa111 [class*="diff-file-header"]');

test("detects unity files on the react layout and renders the semantic view", async ({ page }) => {
  await stubChrome(page, cannedResponse);
  await open(page);

  // Toggle appears only on unity file headers (path comes from header text, not data-path)
  await expect(fooHeader(page).getByRole("button", { name: "Semantic" })).toBeVisible();
  await expect(page.locator("#diff-ccc333 [data-prefablens-toggle]")).toHaveCount(0);

  await fooHeader(page).getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("#diff-aaa111 [data-prefablens-view]");
  await expect(view).toContainText("MonoBehaviour");
  await expect(page.locator("#diff-aaa111 .Diff-module__diffContent")).toBeHidden();

  // Back to raw restores github's body and hides ours
  await fooHeader(page).getByRole("button", { name: "Raw" }).click();
  await expect(page.locator("#diff-aaa111 .Diff-module__diffContent")).toBeVisible();
  await expect(view).toBeHidden();
});

test("global toggle mounts before the virtualized list, not inside a recycled item", async ({ page }) => {
  await stubChrome(page, cannedResponse);
  await open(page);

  await expect(page.locator("[data-prefablens-global]")).toHaveCount(1);
  await expect(page.locator('[data-prefablens-global] + [data-testid="progressive-diffs-list"]')).toHaveCount(1);

  // Global semantic switches both unity files, readme untouched
  await page.locator("[data-prefablens-global]").getByRole("button", { name: "Semantic" }).click();
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(2);
});

test("github's collapse chevron hides the semantic view and re-hides a remounted body", async ({ page }) => {
  await stubChrome(page, cannedResponse);
  await open(page);

  await fooHeader(page).getByRole("button", { name: "Semantic" }).click();
  const view = page.locator("#diff-aaa111 [data-prefablens-view]");
  await expect(view).toContainText("MonoBehaviour");

  // Collapse: react swaps the chevron icon and unmounts the body node
  await page.evaluate(() => {
    const region = document.querySelector("#diff-aaa111")!;
    region.querySelector(".octicon-chevron-down")!.setAttribute("class", "octicon octicon-chevron-right");
    region.querySelector(".Diff-module__diffContent")!.remove();
  });
  await expect(view).toBeHidden();

  // Expand: react remounts a FRESH body node (no inline style) and swaps the icon back.
  // The per-scan sync must re-hide the new body and re-show our view.
  await page.evaluate(() => {
    const region = document.querySelector("#diff-aaa111")!;
    region.querySelector(".octicon-chevron-right")!.setAttribute("class", "octicon octicon-chevron-down");
    const body = document.createElement("div");
    body.className = "Diff-module__diffContent";
    body.textContent = "raw github diff table";
    region.append(body);
  });
  await expect(view).toBeVisible();
  await expect(page.locator("#diff-aaa111 .Diff-module__diffContent")).toBeHidden();
});

test("virtualization: a fully remounted file re-attaches and inherits the semantic default", async ({ page }) => {
  await stubChrome(page, cannedResponse, "semantic");
  await open(page);

  // Both unity files start semantic from the persisted default
  await expect(page.locator("[data-prefablens-view]")).toHaveCount(2);

  // Scroll-out + scroll-in: react discards the whole list item and recreates it fresh,
  // without any of our nodes, marker attributes, or inline styles.
  await page.evaluate(() => {
    const entry = document.querySelector("#diff-aaa111")!.parentElement!;
    const clone = entry.cloneNode(true) as HTMLElement;
    clone.querySelector("[data-prefablens-view]")?.remove();
    clone.querySelector("[data-prefablens-toggle]")?.remove();
    clone.querySelector("[data-prefablens]")?.removeAttribute("data-prefablens");
    for (const el of clone.querySelectorAll<HTMLElement>("[style]")) el.style.display = "";
    entry.replaceWith(clone);
  });

  await expect(page.locator("#diff-aaa111 [data-prefablens-view]")).toBeVisible();
  await expect(page.locator("#diff-aaa111 .Diff-module__diffContent")).toBeHidden();
});
