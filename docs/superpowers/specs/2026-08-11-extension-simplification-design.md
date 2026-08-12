# Extension Simplification Design

Date: 2026-08-11

Status: Approved

## Purpose

This refactor makes the extension easier to read and change. It preserves user-visible features and supported workflows.

The extension is at version 0.8.1. The refactor can remove obsolete compatibility code before the first stable release.

## Scope

The work covers the production code, tests, and design rules under `extension/`. It also updates `docs/extension.md`.

The work excludes the existing `renovate.json` change. It does not add features. It does not do speculative performance work.

The extension commits between `main` and `HEAD` are provisional. The refactor can replace their implementation. It must preserve behavior.

## Architecture

The current dependency direction remains:

```text
Presentation -> Application -> Domain
                     ^              ^
                     |              |
              Infrastructure -------+
```

### Domain

The domain owns domain models, repository interfaces, and pure domain functions. It does not own transport protocols.

### Application

The application owns use cases and gateway contracts. Each use-case file exports one public function.

Application use cases receive gateways, repositories, state, callbacks, and input as explicit parameters.

### Infrastructure

The infrastructure owns clients and private implementation helpers. Each client fully implements one gateway or repository interface.

### Presentation

The presentation owns browser events, DOM state, and UI behavior. It calls application use cases for multi-step operations.

Presentation code can call a gateway or repository directly for transport-only work.

### Communication protocol

The `chrome.runtime` request, response, and push types move from `domain/diff/types.ts` to `application/gateway/messenger.ts`.

### Composition root

The `container.ts` file selects clients, supplies concrete values, and connects dependencies. It does not perform I/O. It does not apply policies.

## Simplicity Rules

- Do not group dependencies in a parameter object such as `FooDeps`.
- Pass each gateway, repository, state value, callback, and input explicitly.
- If a use case has too many parameters, divide its responsibilities.
- Do not create an abstraction only to reduce repetition.
- Keep a single-use operation inline unless extraction gives a clear design benefit.
- A clear benefit includes an independent concept, a shared boundary, a non-trivial policy, or an important flow step.
- Outside application use cases, choose file boundaries from cohesive responsibilities.
- Do not divide files or functions to meet a size target.
- Do not add generic error wrappers or generic helper layers.
- Do not put test-only code in the production source tree.
- Remove obsolete storage formats, migrations, and aliases.
- Add comments only for a reason or a constraint.
- Delete comments that restate the code.

These rules make `view-mode-storage.ts` an inline candidate. The file has one caller. It does not own an independent policy.

These rules also remove `application/internal/diff-fakes.ts` from the production tree. Tests can contain small local repetition.

## Data Flow

The primary extension flow remains:

```text
content -> messenger -> background -> use case
        -> client or repository or WASM
        -> Result or push -> content render
```

The content script detects the page. Then it sends a typed request. The background entry point supplies each use-case dependency explicitly.

The use case gets GitHub data and stored data. It calls WASM. Then it returns a `Result` or a later push.

The content script owns the final UI state and render operation.

## Refactoring Stages

### 1. Content runtime

Simplify `content/index.ts`, DOM detection, view state, and overlay coordination. Preserve SPA, React remount, Device Flow, and view-mode behavior.

Move the logic from `view-mode-storage.ts` into its only caller. Remove test cases that only lock an implementation method.

### 2. Semantic diff

Separate request handling, raw diff creation, GUID resolution, source merging, and asynchronous pushes by responsibility.

Keep dependencies as explicit parameters. Do not replace them with a dependency object, factory object, or service class.

Move transport protocol types out of the domain. Remove the shared fake harness from the production tree.

### 3. GitHub and storage

Make each client implement its full gateway or repository interface. Remove I/O and conversion logic from `container.ts`.

Remove the old `pat` migration and its tests. Keep GitHub pagination, rate-limit, fallback, and storage-quota behavior.

### 4. Renderer and demo

Keep the renderer cohesive. Do not divide it because of its line count.

If both contexts use the same policy, share content and demo code. Do not put context differences behind adapters.

### 5. Final audit

Align `docs/extension.md`, layer rules, exports, comments, and tests with the final code. Remove dead or duplicate code.

## Failure Handling

Clients classify concrete HTTP, Chrome, WASM, and storage failures. Use cases return expected failures as explicit `Result` values.

Only programmer errors and unexpected runtime failures cause a rejection. Each failure changes form at one boundary only.

The fetch queue owns rate-limit retries. Prefetch failures do not block a user action.

If GUID or source resolution fails, the use case returns the available diff. It also reports the resolution status.

An asynchronous push reports completion after success or failure. This rule stops content waiters that stay active forever.

Storage failures do not stop an otherwise usable page. A comment explains why the code can ignore each such failure.

## Test Policy

Test count and coverage percentage are not goals. Each test must justify its maintenance cost.

A test must satisfy all these statements:

- The test detects a realistic regression with a clear effect.
- The test protects a stable contract.
- No other test detects the same risk with enough precision.
- The test does not depend unnecessarily on an implementation method.
- The detection value is higher than the maintenance cost.

Keep tests for these risks:

- Major flows through a real browser, extension, and WASM.
- React remount, virtualization, and SPA navigation.
- GitHub pagination, rate limits, and fallback behavior.
- Queue progress, backoff, and priority.
- WASM, security, and storage boundaries.
- Complex domain branches and parity between implementations.

Delete tests that only examine DOM classes, icons, private call counts, or obsolete compatibility behavior.

If a higher-level test detects the same risk with enough precision, delete the lower-level tests.

If each level detects a different failure cause, a historical failure can have tests at two levels.

Do not use mocks or stubs. Use real implementations, real `Response` objects, and in-memory repositories.

Tests under `src/` obey the layer import direction.
The `extension/test/` directory is a test composition root outside the product layers.
Put tests that compose multiple layers under `extension/test/`.
The `extension/fixtures/` directory contains shared static test data.
If one file uses a helper, keep it in that test file.
Do not put test-only helpers in `extension/src/`.
An in-memory storage implementation derives failures from its complete state and capacity.
A virtual clock advances time when `sleep(ms)` runs.
Test implementations do not use programmed responses, dependency bags, spies, or private call counts.

## Design Enforcement

The `docs/extension.md` file remains the authoritative design document for the extension. This refactor adds these rules to that file.

The `layering.test.ts` file enforces only rules that static imports can show reliably:

- Layer dependency direction.
- Domain isolation.
- Access through `application/gateway/`.
- Privacy of `internal/` directories.
- Access to the composition root.
- Placement of infrastructure clients.

Do not add a complex source parser to enforce judgment-based rules. Keep those rules in `docs/extension.md`.

## Verification

Run targeted tests after each refactoring stage. Then run all extension checks from `extension/`.

```bash
pnpm run size
pnpm run lint
pnpm run typecheck
pnpm test
pnpm run build
pnpm run demo
pnpm run e2e
```

The current branch has one formatting failure in `device-page.test.ts`. Correct this failure during the first implementation stage.

## Completion Criteria

- User-visible features and major workflows keep their behavior.
- Obsolete compatibility code no longer exists.
- No dependency bag exists.
- No test-only module exists in the production tree.
- Unnecessary abstractions, exports, comments, and tests no longer exist.
- The design document and implementation agree.
- All extension checks pass.
- The existing `renovate.json` change remains untouched.
