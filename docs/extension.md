# Extension Architecture

Layer structure and dependency rules for `extension/src/`. Modeled on
[reknotes ARCHITECTURE.md](https://github.com/hashiiiii/reknotes/blob/main/docs/ARCHITECTURE.md),
adapted for a Chrome MV3 extension. `src/layering.test.ts` enforces the import
rules mechanically.

## Overview

Dependencies always point inward (toward `domain/`):

    Presentation -> Application -> Domain <- Infrastructure

The extension has three JS contexts, each with its own entry point and
container factory:

| Context | Entry point | Factory |
|---|---|---|
| Service worker | `presentation/background/index.ts` | `createBackgroundDeps()` |
| Content script | `presentation/content/index.ts` | `createContentDeps()` |
| Site demo | `presentation/demo/index.ts` | `createDemoDeps()` |

## Layers

### Domain (`src/domain/`)

Pure types and pure functions. Imports nothing outside `domain/`.

### Application (`src/application/`)

Use cases composed from domain logic and ports.

- **Use case**: one per file, named `<verb>-<noun>.ts`, exporting a plain
  verb function `<verb>(deps, [state,] input)`. Long-lived state (in-flight
  caches, latches, view state) lives in plain state records created by
  `create<X>()` / `empty<X>()` constructors; the container (or presentation,
  for UI state) creates them once and callers pass them explicitly. No
  `create<UseCase>(deps)` factories, no method-bag objects.
- **Result**: expected failures travel as tagged unions via
  `Result<T, E>` from `application/_result.ts` — no `Error` subclasses,
  no `throw` for expected failures. `_result.ts` is the one non-port
  application file that infrastructure may import (pure primitives shared
  by ports and their implementations); `src/layering.test.ts` encodes that
  exception.
- **Port** (`application/port/<name>.ts`): `XxxPort` types abstracting
  infrastructure capabilities. (reknotes uses `I*Provider`; this codebase
  keeps its established `*Port` naming.)
- **Shared internals**: files used by several use cases in a feature folder
  get an underscore prefix (`_diff-session.ts`, `_resolution.ts`,
  `_promise-cache.ts`) to distinguish them from verb-noun use cases.
- **Inline deps**: a single-function dependency may live inline in a use
  case's `Deps` type (e.g. `getSettings`, `fetchBytes`); multi-method
  contracts go in `port/`.

### Infrastructure (`src/infrastructure/`)

- **`providers/`**: implementations of `application/port` contracts and
  other outside-world adapters (GitHub client, WASM differ, chrome.storage,
  chrome.runtime messaging).
- **`repositories/`**: chrome.storage-backed stores.
- **`container.ts`**: the only DI file. Exports one `create<Context>Deps()`
  factory per JS context returning the deps (and state) bundles presentation
  passes to use-case functions. Only container.ts may import application use
  cases; all other infrastructure files import `application/port` at most.

### Presentation (`src/presentation/`)

Receives outside input and decides which use case to call.

- May import: application use cases (and their types), domain types and
  pure functions, other presentation files.
- Must not import: `application/port`, any infrastructure file — except the
  entry point (`presentation/*/index.ts`), which imports `container.ts` to
  build its deps bundle. Presentation holds deps bundles but never invokes port
  methods itself — it only passes them to use cases.
- **Inbound vs outbound**: inbound transport events
  (`chrome.runtime.onMessage`, `chrome.storage.onChanged`, DOM events) are
  presentation's job, like HTTP routes. Outbound calls (requests to the
  background, GitHub API) go through a use case and a port.
- UI view models (`content/overlay/`: view state, view registry, per-file
  state machine, auth retries) are presentation-owned. The `viewMode`
  storage key is a UI preference and is read/written directly by
  presentation; the `accessToken`/`signin` keys are owned by the token
  store, and presentation only observes their change events.

## Startup pattern

Every entry point follows:

    create<Context>Deps() -> register listeners -> call use-case functions
