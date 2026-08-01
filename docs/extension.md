# Extension Architecture

Layer structure and dependency rules for `extension/src/`. A layered architecture
adapted for a Chrome Manifest V3 extension. `src/layering.test.ts` enforces the import
rules mechanically.

## Overview

Dependencies always point inward (toward `domain/`):

    Presentation -> Application -> Domain <- Infrastructure

The extension has three JS contexts, each with its own entry point and
container wiring:

| Context | Entry point | Factory |
|---|---|---|
| Service worker | `presentation/background/index.ts` | individual `createX()` from `container.ts` |
| Content script | `presentation/content/index.ts` | individual `createX()` from `container.ts` |
| Site demo | `presentation/demo/index.ts` | individual `createX()` from `container.ts` |

## Layers

### Domain (`src/domain/`)

Pure types and pure functions. Imports nothing outside `domain/`.

- **Repository**: interfaces for domain-model persistence live in
  `domain/` (alongside models). Use cases depend on these interfaces;
  infrastructure supplies the implementations.
- **Result**: expected failures travel as tagged unions via
  `Result<T, E>` from `domain/result.ts` — no `Error` subclasses,
  no `throw` for expected failures. Shared by ports, use cases, and
  infrastructure implementations.

### Application (`src/application/`)

Use cases composed from domain logic and ports.

- **Use-case verbs**: prefer CRUD names — `create`, `get`, `update`, `delete`.
  `signIn` is the allowed non-CRUD exception (OAuth device flow).
- **Use case**: one per file, named `<verb>-<noun>.ts`, exporting a plain
  verb function `<verb>(ports…, [state,] input)`. Long-lived state (in-flight
  caches, latches, view state) lives in plain state records created by
  `create<X>()` / `empty<X>()` constructors; callers pass state explicitly.
  No `create<UseCase>(deps)` factories, no method-bag objects, no `XxxDeps`
  bags.
- **Port** (`application/port/<name>.ts`): `XxxPort` types abstracting
  outside capabilities that do **not** load or save domain models (GitHub
  API, WASM differ, chrome.runtime messaging, device-flow helpers).
- **Shared internals**: files used by several use cases in a feature folder
  get an underscore prefix (`_diff-session.ts`, `_resolution.ts`,
  `_promise-cache.ts`) to distinguish them from verb-noun use cases.
- **Function params**: single-function dependencies (e.g. `fetchBytes`,
  `makeClient`, `getDiffer`) are plain parameters; multi-method contracts
  live in `application/port/`.

### Infrastructure (`src/infrastructure/`)

- **`providers/`**: implementations of `application/port` contracts
  (GitHub client, WASM differ, chrome.runtime messaging, device-flow helpers).
- **`repositories/`**: implementations of domain repository interfaces
  (chrome.storage-backed). `merge-store.ts` is an internal helper for
  those implementations.
- **`container.ts`**: the only DI file. Exports individual `createX()`
  factories that return ports and repositories (and lifetime-managed
  loaders). Does not import application use cases or session constructors.

### Presentation (`src/presentation/`)

Receives outside input and decides whether to call a use case or a port.

- May import: application use cases (and their types), `application/port`,
  domain types and pure functions, other presentation files.
- Must not import: any infrastructure file — except the entry point
  (`presentation/*/index.ts`), which imports `container.ts` to construct
  ports **and repositories**.
- **When to call a port vs a use case**: transport-shaped outbound work
  (content → background messaging, thin repository reads for UI pre-fill)
  may invoke port/repository methods directly. Multi-step business
  orchestration (device-flow sign-in, semantic diff pipeline, PR prefetch)
  stays in application use cases; presentation passes ports/repositories
  into those verbs.
- **Inbound vs outbound**: inbound transport events
  (`chrome.runtime.onMessage`, `chrome.storage.onChanged`, DOM events) are
  presentation's job, like HTTP routes.
- UI view models (`content/overlay/`: view state, view registry, per-file
  state machine, auth retries) are presentation-owned. The `viewMode`
  storage key is a UI preference and is read/written directly by
  presentation; the `accessToken`/`signin` keys are owned by the token
  repository, and presentation only observes their change events.

## Startup pattern

Every entry point follows:

    createX()… → createDiffSession() (if needed) → register listeners → call use-case functions
