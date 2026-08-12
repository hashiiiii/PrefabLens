# Chrome extension

This page is for people who change `extension/`.
For install steps and product overview, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Why

The extension uses the same Zig diff engine as the CLI.
The build compiles that engine to WASM.
The extension does not send asset contents to a PrefabLens server.
GitHub API access uses the GitHub Device Flow from the PR panel.

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

### Overview

Dependencies point inward. Infrastructure also depends on
`application/gateway/` to implement gateways:

```
Presentation -> Application -> Domain
                     ^              ^
                     |              |
              Infrastructure -------+
              (implements gateway + repository)
```

`src/layering.test.ts` enforces these rules:

- the import direction
- the domain isolation
- infrastructure does not import application public functions
- only presentation entry points import `src/container.ts`
- `infrastructure/clients/` holds only `*-client.ts` interface implementations
- an `internal/` directory is private: only files under its parent directory
  import it (`src/internal/` is under the root, so every file can use it)

Two modules sit outside the four layers:

| Module | Role |
|---|---|
| `src/container.ts` | Composition root. DI factories only |
| `src/internal/` | Shared helpers that no layer owns (for example `must`) |

The extension has three JS contexts.
Each JS context has its own entry point and its own container wiring:

| Context | Entry point |
|---|---|
| Service worker | `presentation/background/index.ts` |
| Content script | `presentation/content/index.ts` |
| Site demo | `presentation/demo/index.ts` |

### Layout

`<area>` matches an existing concept folder (`diff`, `guid`, `auth`, …).
Add a new area only when a new concept appears.
Use kebab-case file names.

#### Domain (`src/domain/`)

```
domain/
  result.ts                   # Result plus the ok / err constructors
  <area>/
    <type>.ts                 # domain types
    <noun>-repository.ts      # repository interfaces
    fn/<name>.ts              # pure functions that read or build domain types
```

- If the symbol is a domain type (including `Result`), put it in
  `domain/<area>/` (outside `fn/`).
  Type files hold types plus constructors and type guards only
  (for example `ok` / `err` next to `Result`).
  Put queries and transforms under `fn/`.
- If the symbol is a repository interface for domain-model persistence, put it in
  `domain/<area>/<noun>-repository.ts`.
  Public functions depend on these interfaces.
  Clients in `infrastructure/` implement these interfaces.
- If the symbol is a pure function that reads or builds a domain type, put it in
  `domain/<area>/fn/<name>.ts`.
- If a helper is not a domain type, keep it out of `domain/`.
  Put cross-layer helpers in `src/internal/` (see Overview).

#### Application (`src/application/`)

```
application/
  <area>/
    <verb>-<noun>.ts   # one public function (use case or state factory)
  internal/
    <noun>.ts          # shared helpers that are not public functions
  gateway/
    <name>.ts          # gateway types (XxxGateway)
```

- If the symbol is an application public function (a use case or a state factory),
  put it in `application/<area>/<verb>-<noun>.ts`.
  Export one function per file.
  If a helper serves one public function only, keep it non-exported in that file.
- If two or more application callers share work that is not a public function,
  put it in `application/internal/<noun>.ts`
  (for example `raw-diff.ts`, `repo-index.ts`).
- Gateway types that application owns live in `application/gateway/<name>.ts`
  as `XxxGateway`:
  `GithubGateway`, `DifferGateway` (WASM), `MessengerGateway` (chrome.runtime),
  `GithubAuthGateway` (Device Flow), `FixturesGateway` (demo fixture files).
  A gateway file holds types plus small type guards and converters for its
  failure union (for example `isRateLimited`, `toBackgroundError`).

#### Infrastructure (`src/infrastructure/`)

```
infrastructure/
  clients/             # implementations of the repository interfaces and the gateway types
  internal/            # helpers that implement no interface
```

- A client implements a repository interface from `domain/` or a gateway type
  from `application/gateway/`.
- Put each client in `clients/` as `*-client.ts`
  (for example `github-client.ts`, `chrome-token-client.ts`).
- Put helpers that implement no interface in `internal/`
  (for example `fetch-queue.ts`, `merge-store.ts`, `storage-area.ts`).
- Only infrastructure files import `internal/` (the internal rule in Overview).

#### Presentation (`src/presentation/`)

```
presentation/
  background/          # service worker entry
  content/
    overlay/           # view models, view registry, file view state
  demo/                # site demo entry
  internal/            # helpers shared by two or more JS contexts
```

- Each JS context has its own entry under its folder (`*/index.ts`).
- View models and named UI callback types live next to the presentation code
  that owns them (for example under `content/overlay/`).
- If two or more presentation contexts share a helper (render, the toggle,
  the view state), put it in `presentation/internal/`.

#### Tests

- Tests under `src/` obey the layer import direction.
- `test/` is a test composition root outside the product layers.
- Put tests that compose multiple layers under `test/`.
- `fixtures/` contains shared static test data.
- Keep test-only helpers in test files when one file uses them.
- Do not put test-only helpers in `src/`.
- An in-memory storage implementation derives failures from its complete state and capacity.
- A virtual clock advances time when `sleep(ms)` runs.
- Test implementations do not use programmed responses, dependency bags, spies, or private call counts.

### Layer contracts

#### Domain (`src/domain/`)

**Role.** Domain vocabulary only.

**Imports.** Production files in this layer import nothing outside `domain/`.
Test files can also import the test runner, `node:` modules, and `src/internal/`.

**Notes.**

- Expected failures travel as tagged unions via `Result<T, E>` from `domain/result.ts`.
- Expected failures do not use `Error` subclasses.
- Expected failures do not use `throw`.
- Infrastructure adapters can reject for unexpected failures.
  The nearest public function converts them to `Result` at the boundary.

#### Application (`src/application/`)

**Role.** Public functions that compose domain logic and gateways.
A public function is a use case or a state factory.

**Imports.** This layer can import `domain/`.
It cannot import `infrastructure/` or `presentation/`.

**Notes.**

- Use CRUD names for use-case verbs: `create`, `get`, `update`, `delete`.
  If a CRUD name hides the intent, use a domain verb
  (for example `sign-in`, `prefetch-pr`).
- Export a plain verb function `<verb>(gateways…, [state,] input, [callbacks])`.
- Internal modules can export several sibling functions.
- Send and receive domain models through repository interfaces in `domain/`.
- Talk to outside systems that do not load or save domain models through gateways.
- A single-function dependency is a plain parameter
  (for example `fetchBytes`, `makeClient`, `getDiffer`).
- A multi-method outside capability lives in `application/gateway/`.
- UI callback shapes are presentation vocabulary.
  Application asks for the structure it needs.
  It does not own a named UI type.
- When construction of working memory needs real logic, application exports a
  state factory (for example `createDiffSession`).
  When construction is only a literal, presentation builds that value itself.
- Data that must cross JS contexts is not in-memory working memory.
  That data goes through a repository or a gateway.

#### Infrastructure (`src/infrastructure/`)

**Role.** Clients that implement the repository interfaces and the gateway types.

**Imports.** This layer can import `domain/` and `application/gateway/`.
It cannot import anything else under `application/`.

**Notes.**

- Infrastructure does not own the composition root.
  Entry points import `src/container.ts` to create the clients.
- Helpers that implement no interface go in `infrastructure/internal/`.
  Only infrastructure files can import them.

#### Presentation (`src/presentation/`)

**Role.** This layer receives outside input, holds non-persistent working memory
for its JS context, and calls application public functions for multi-step work.
Transport-only work can call a gateway or repository method directly.

**Imports.**

- Can import: application public functions (and their types),
  `application/gateway`, domain types, `domain/<area>/fn` pure functions,
  other presentation files, `src/container.ts`, and `src/internal/`.
- Cannot import: `application/internal/` or any infrastructure file.
  Entry points import `src/container.ts` to create the clients.

**Notes.**

- Outbound transport-only work can call a gateway or repository method
  directly (content → background messaging, thin repository reads for UI pre-fill).
- Multi-step business work stays in application public functions
  (Device Flow sign-in, semantic diff pipeline, PR prefetch).
  Presentation passes gateways, repositories, and working memory into those verbs.
- Inbound transport events are presentation work, like HTTP routes
  (`chrome.runtime.onMessage`, `chrome.storage.onChanged`, DOM events).
- The `viewMode` storage key is a UI preference.
  Presentation reads and writes it directly.
- The `accessToken` / `signin` keys belong to the token repository.
  Presentation only observes their change events.

### Startup

Every entry point follows this sequence:

```
createX() -> createDiffSession() (if needed) -> register listeners -> call public functions
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

If a submission is still in review, a re-run of `publish-extension` fails
until the store finishes.
If no Chrome Web Store submission is pending, you can re-run
`publish-extension` alone.
