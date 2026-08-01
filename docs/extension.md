# Extension

## Architecture

Layer structure and dependency rules for `extension/src/`. A layered architecture
adapted for a Chrome Manifest V3 extension. `src/layering.test.ts` enforces the import
rules mechanically.

### Overview

Dependencies always point inward (toward `domain/`):

    Presentation -> Application -> Domain <- Infrastructure

The extension has three JS contexts, each with its own entry point and
container wiring:

| Context | Entry point |
|---|---|
| Service worker | `presentation/background/index.ts` |
| Content script | `presentation/content/index.ts` |
| Site demo | `presentation/demo/index.ts` |

### Layers

#### Domain (`src/domain/`)

Domain vocabulary only. Imports nothing outside `domain/`.

**Where to put a new symbol** (one pass, no other axes):

1. Needs I/O, port wiring, or multi-step orchestration → `application/`
   (single-use-case helper: non-exported in that use case file).
2. Pure function that reads or builds a domain type →
   `domain/<area>/fn/<name>.ts`.
3. Type or interface (including repository ports and `Result`) →
   `domain/<area>/` (outside `fn/`). No function bodies in these files.

`<area>` matches an existing concept folder (`diff`, `guid`, `auth`, …).
Add a new area only when a new concept appears.

- **Constructors / type guards**: may live in the same file as their type
  (e.g. `ok` / `err` next to `Result`). Queries and transforms
  (`unresolvedRemaining`, `applyResolved`, `targetKey`, …) always go under
  `fn/`.
- **Not domain**: helpers that are not vocabulary of a domain type
  stay out of `domain/` (e.g. `must` lives at `src/must.ts`).
- **Repository**: interfaces for domain-model persistence live in
  `domain/<area>/`. Use cases depend on these interfaces.
  Infrastructure supplies the implementations.
- **Result**: expected failures travel as tagged unions via
  `Result<T, E>` from `domain/result.ts` — no `Error` subclasses,
  no `throw` for expected failures.

#### Application (`src/application/`)

Use cases composed from domain logic and ports.

- **Use-case verbs**: prefer CRUD names — `create`, `get`, `update`, `delete`.
- **Use case**: one per file, named `<verb>-<noun>.ts`, exporting a plain
  verb function `<verb>(ports…, [state,] input)`. Long-lived state (in-flight
  caches, latches, view state) lives in plain state records created by
  `create<X>()` / `empty<X>()` constructors. Callers pass state explicitly.
- **Port** (`application/port/<name>.ts`): `XxxPort` types abstracting
  outside capabilities that do **not** load or save domain models (GitHub
  API, WASM differ, chrome.runtime messaging, device-flow helpers).
- **Shared helpers**: live directly under `application/` when used by two or
  more production callers (or by presentation) and they are *not* domain
  queries/transforms — e.g. `create-diff-session.ts`, `get-raw-diff.ts`,
  `get-repo-index.ts`. Pure reads/builds of domain types go in
  `domain/<area>/fn/` instead. Single-use-case helpers stay non-exported
  in that use case file. Test-only helpers stay in test files. Feature
  folders hold verb-noun use cases only.
- **Function params**: single-function dependencies (e.g. `fetchBytes`,
  `makeClient`, `getDiffer`) are plain parameters. Multi-method contracts
  live in `application/port/`.

#### Infrastructure (`src/infrastructure/`)

- **`providers/`**: implementations of `application/port` contracts
  (GitHub client, WASM differ, chrome.runtime messaging, device-flow helpers).
- **`repositories/`**: implementations of domain repository interfaces
  (chrome.storage-backed). `merge-store.ts` is an internal helper for
  those implementations.
- **`container.ts`**: the only DI file. Exports individual `createX()`
  factories that return ports and repositories (and lifetime-managed
  loaders). Does not import application use cases or session constructors.

#### Presentation (`src/presentation/`)

Receives outside input and decides whether to call a use case or a port.

- May import: application use cases (and their types), `application/port`,
  domain types and `domain/<area>/fn` pure functions, other presentation files.
- Must not import: any infrastructure file — except the entry point
  (`presentation/*/index.ts`), which imports `container.ts` to construct
  ports **and repositories**.
- **When to call a port vs a use case**: transport-shaped outbound work
  (content → background messaging, thin repository reads for UI pre-fill)
  may invoke port/repository methods directly. Multi-step business
  orchestration (device-flow sign-in, semantic diff pipeline, PR prefetch)
  stays in application use cases. Presentation passes ports/repositories
  into those verbs.
- **Inbound vs outbound**: inbound transport events
  (`chrome.runtime.onMessage`, `chrome.storage.onChanged`, DOM events) are
  presentation's job, like HTTP routes.
- UI view models (`content/overlay/`: view state, view registry, per-file
  state machine, auth retries) are presentation-owned. The `viewMode`
  storage key is a UI preference and is read/written directly by
  presentation. The `accessToken`/`signin` keys are owned by the token
  repository, and presentation only observes their change events.

### Startup pattern

Every entry point follows:

    createX()… → createDiffSession() (if needed) → register listeners → call use-case functions
