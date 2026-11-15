# Chrome Extension

The PrefabLens extension adds a **Raw / Semantic** switch to supported GitHub diff pages.  
Semantic view replaces GitHub's text diff for UnityYAML assets with a tree of changed GameObjects, components, and fields.

Install it from the [Chrome Web Store](https://chromewebstore.google.com/detail/dlhnalbfkikchkfedfneiimadommcnip).  
The [README](../README.md#chrome-extension) has the project overview.  
To try the interface without connecting to GitHub, use the [interactive demo](https://prefablens.hashiiiii.workers.dev/extension.html).

## Use the Extension

1. Open a GitHub pull request's **Files changed** tab in Chrome.
2. Select **Semantic** in the PrefabLens control above the changed files, or on an individual UnityYAML file.
3. If prompted, select **Sign in with GitHub**.  
   Enter the displayed code on GitHub and authorize PrefabLens.  
   The extension resumes the diff when authorization succeeds.
4. Select **Raw** to return to GitHub's text diff.  
   The page-wide view preference is saved in Chrome.  
   A file-level choice applies to that file on the current diff page; selecting a page-wide view applies it to all matching files.

The extension runs on `github.com` and requests file contents and pull request metadata from GitHub.  
Its semantic diff engine runs in the browser.  
GitHub Device Flow requests the `repo` OAuth scope.  
The token and view preference stay in Chrome storage; the extension sends requests only to GitHub and does not send data to a PrefabLens server.  
See the [privacy policy](../PRIVACY.md) for details.

The extension detects UnityYAML files on pull request file diffs, commit diffs, and same-repository compare pages.  
A file must be a text-based Unity asset to produce a semantic diff.

## Troubleshooting

- **No PrefabLens control appears:** confirm that the page is on `github.com`, is a supported diff page, and includes a changed UnityYAML file.  
  The extension does not add controls for other file extensions.
- **GitHub sign-in fails:** retry **Sign in with GitHub**.  
  If the code expires, start sign-in again and enter the new code on GitHub.
- **GitHub rate limit or unresolved references:** if a rate-limit error appears, wait and select **Semantic** again.  
  If the semantic view shows an unresolved-reference message, select **Retry** there.  
  GitHub can limit requests while the extension loads file contents or resolves Unity references.
- **A large file is not rendered yet:** files larger than 25 megabytes ask for confirmation. Select **Render anyway** to continue.
- **A file cannot be diffed:** use **Raw** to see GitHub's text diff.  
  Non-text Unity assets cannot produce a semantic diff.

## Contributor Guide

### Data Flow and Code Boundaries

The extension has three browser contexts: the content script attaches controls to GitHub pages, the service worker fetches GitHub data and runs the shared WebAssembly diff engine, and the site demo uses fixture files with the same renderer.  
Entry points are under `extension/src/presentation/`.

Keep each responsibility in its existing layer:

- `domain/` defines diff and repository types plus pure functions.
- `application/` contains use cases that combine domain logic with gateway or repository interfaces.
- `infrastructure/clients/` implements those interfaces for GitHub, Chrome storage and messaging, and WebAssembly.
- `presentation/` handles DOM events, Chrome events, view state, and context entry points.

The entry points use `src/container.ts` to create their clients.  
Infrastructure clients handle GitHub requests and shared storage or messaging adapters.  
Presentation code owns the page DOM, view state, and browser-context event handling.  
`application/internal/` and `infrastructure/internal/` hold helpers for their respective layers; `presentation/internal/` holds UI helpers shared across contexts.

### Build and Verify

Install the repository toolchain from the root.  
Then install the extension dependencies and run the checks:

```sh
mise install
cd extension
pnpm install --frozen-lockfile
pnpm run size
pnpm run lint
pnpm run typecheck
pnpm test
pnpm run build
```

The size check, test setup, and build compile `core/` to WebAssembly with `zig build wasm`.  
The size check enforces the gzip size limit in `scripts/check-wasm-size.mjs`.

To run the browser suite, install Playwright's Chromium dependencies once and run:

```sh
pnpm exec playwright install --with-deps chromium
pnpm run e2e
```

`pnpm run e2e` builds the extension with a local API origin and runs Playwright against Chromium.  
It does not use a real GitHub account.  
CI runs these checks in the `extension` job of [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

To load a local build manually, run `pnpm run build`, open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select `extension/dist/`.

The release ZIP contains `extension/dist/` with `manifest.json` at its root.  
The release workflow can submit that build to the Chrome Web Store; the store publishes it after review.  
Maintainer release steps are in [`.github/workflows/release.yml`](../.github/workflows/release.yml).
