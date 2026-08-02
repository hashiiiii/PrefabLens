# Chrome extension (contributors)

This page is for people who change `extension/`.
For install steps and the product overview, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Why

The extension uses the same Zig diff engine as the CLI.
The build compiles that engine to WASM.
The extension does not send asset contents to a PrefabLens server.
GitHub API access uses the device flow from the PR panel.

## Tech stack

| Piece | Choice |
|---|---|
| Runtime | Chrome Manifest V3 (service worker + content script) |
| Language | TypeScript |
| Diff engine | Zig `core/`, built with `zig build wasm` |
| Bundle | esbuild (`extension/build.mjs`) → `extension/dist/` |
| Unit tests | Vitest (`pnpm test`). Builds WASM via `pretest` |
| E2E | Playwright with Chromium and `--load-extension` |
| Lint / format | Biome |
| Package manager | pnpm (see root `mise.toml` for the Node version) |

The release package is a zip of `extension/dist/`.
`manifest.json` sits at the root of that zip.
The live demo site uses a `--demo` bundle from the same build script.

## Design

This section describes the layer structure and the dependency rules for
`extension/src/`.
The design is a layered architecture for a Chrome Manifest V3 extension.
`src/layering.test.ts` enforces the import rules.

### Overview

Dependencies always point inward (toward `domain/`):

```
Presentation -> Application -> Domain <- Infrastructure
```

The extension has three JS contexts.
Each context has its own entry point and its own container wiring:

| Context | Entry point |
|---|---|
| Service worker | `presentation/background/index.ts` |
| Content script | `presentation/content/index.ts` |
| Site demo | `presentation/demo/index.ts` |

### Placement guide

Use this pass one time when you add a symbol.
Do not use other axes.

1. If the symbol needs I/O, port wiring, or multi-step orchestration, put it in `application/`.
   If a helper serves one use case only, keep it non-exported in that use case file.
2. If the symbol is a pure function that reads or builds a domain type, put it in
   `domain/<area>/fn/<name>.ts`.
3. If the symbol is a type (including repository ports and `Result`), put it in
   `domain/<area>/` (outside `fn/`).
   Do not put function bodies in these files.
4. If a helper is not a domain query or transform, and two or more production callers
   (or presentation) share it, put it directly under `application/`.
   Examples: `create-diff-session.ts`, `get-raw-diff.ts`, `get-repo-index.ts`.
5. If a helper is not vocabulary of a domain type, keep it out of `domain/`.
   Example: `must` lives at `src/must.ts`.
6. Keep test-only helpers in test files.

`<area>` matches an existing concept folder (`diff`, `guid`, `auth`, and more).
Add a new area only when a new concept appears.

### Layer contracts

Each layer section uses the same shape: role, imports, naming and ownership, then notes.

#### Domain (`src/domain/`)

**Role.** Domain vocabulary only.

**Imports.** This layer imports nothing outside `domain/`.

**Naming and ownership.**

- Repository interfaces for domain-model persistence live in `domain/<area>/`.
  Use cases depend on these interfaces.
  Infrastructure supplies the implementations.
- Constructors and type guards can live in the same file as their type
  (for example `ok` / `err` next to `Result`).
- Queries and transforms always go under `fn/`
  (for example `unresolvedRemaining`, `applyResolved`, `targetKey`).

**Notes.**

- Expected failures travel as tagged unions via `Result<T, E>` from `domain/result.ts`.
- Expected failures do not use `Error` subclasses.
- Expected failures do not use `throw`.

#### Application (`src/application/`)

**Role.** Use cases that compose domain logic and ports.

**Imports.** This layer can import `domain/`.
It cannot import `infrastructure/` or `presentation/`.

**Naming and ownership.**

- Use CRUD names for use-case verbs: `create`, `get`, `update`, `delete`.
- Put one use case in each file.
- Name the file `<verb>-<noun>.ts`.
- Export a plain verb function `<verb>(ports…, [state,] input)`.
- Long-lived state lives in plain state records
  (in-flight caches, latches, view state).
  Create those records with `create<X>()` / `empty<X>()` constructors.
  Callers pass state explicitly.
- Port types live in `application/port/<name>.ts` as `XxxPort`.
  Ports abstract outside capabilities that do not load or save domain models
  (GitHub API, WASM differ, chrome.runtime messaging, device-flow helpers).
- Feature folders hold verb-noun use cases only.

**Notes.**

- A single-function dependency is a plain parameter
  (for example `fetchBytes`, `makeClient`, `getDiffer`).
- A multi-method contract lives in `application/port/`.

#### Infrastructure (`src/infrastructure/`)

**Role.** This layer implements ports and repositories.
It also wires the container.

**Imports.** This layer can import `domain/` and `application/port/`.
It cannot import application use cases.

**Naming and ownership.**

- `providers/`: implementations of `application/port` contracts
  (GitHub client, WASM differ, chrome.runtime messaging, device-flow helpers).
- `repositories/`: implementations of domain repository interfaces
  (chrome.storage-backed).
  `merge-store.ts` is an internal helper for those implementations.
- `container.ts` is the only DI file.
  It exports individual `createX()` factories that return ports and repositories
  (and lifetime-managed loaders).

**Notes.**

- `container.ts` does not import application use cases or session constructors.

#### Presentation (`src/presentation/`)

**Role.** This layer receives outside input.
Then it decides whether to call a use case or a port.

**Imports.**

- This layer can import application use cases (and their types), `application/port`,
  domain types, `domain/<area>/fn` pure functions, and other presentation files.
- It cannot import any infrastructure file, with one exception:
  the entry point (`presentation/*/index.ts`) imports `container.ts`
  to construct ports and repositories.

**Naming and ownership.**

- UI view models are presentation-owned
  (`content/overlay/`: view state, view registry, per-file state machine, auth retries).
- The `viewMode` storage key is a UI preference.
  Presentation reads and writes it directly.
- The `accessToken` / `signin` keys belong to the token repository.
  Presentation only observes their change events.

**Notes.**

- Outbound work that is only transport can call a port or repository method
  directly (content → background messaging, thin repository reads for UI pre-fill).
- Multi-step business work stays in application use cases
  (device-flow sign-in, semantic diff pipeline, PR prefetch).
  Presentation passes ports and repositories into those verbs.
- Inbound transport events are presentation work, like HTTP routes
  (`chrome.runtime.onMessage`, `chrome.storage.onChanged`, DOM events).

### Startup

Every entry point follows this sequence:

```
createX() -> createDiffSession() (if needed) -> register listeners -> call use-case functions
```

## Verification

Install the toolchain from the repository root:

```bash
mise install
```

Then run the extension checks:

```bash
cd extension
pnpm install
pnpm run size
pnpm run lint
pnpm run typecheck
pnpm test
pnpm run build
```

`pnpm run size`, `pnpm test`, and `pnpm run build` each run `zig build wasm` when they need the WASM file.
If the gzip WASM bundle is larger than the budget in
`scripts/check-wasm-size.mjs`, `pnpm run size` fails.

For end-to-end checks:

```bash
cd extension
pnpm exec playwright install --with-deps chromium   # first time on a machine
pnpm run e2e
```

`pnpm run e2e` builds with `--e2e` (local API origin).
Then it runs Playwright.

To load a local build in Chrome by hand:

1. Run `pnpm run build` in `extension/`.
2. Open `chrome://extensions`.
3. Enable Developer mode.
4. Choose Load unpacked.
5. Select `extension/dist/`.

CI runs the same checks in the `extension` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Deploy

Maintainers publish the extension through the Release workflow on `main`.

1. Run [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   with `workflow_dispatch` and a version `X.Y.Z` (no `v` prefix).
2. Make sure that the `CWS_*` repository secrets are set before you rely on
   `publish-extension`.

After you start the workflow, it bumps versions.
It builds the CLI zips and `prefablens-extension-$VERSION.zip`.
It commits, tags `v$VERSION`, and creates the GitHub Release.
Then the `publish-extension` job downloads that zip.
The job uploads the zip to the Chrome Web Store and submits it for review.
The store publishes the extension after approval.

If no Chrome Web Store submission is pending, you can re-run
`publish-extension` alone.
If a submission is still in review, that re-run fails until the store finishes.
