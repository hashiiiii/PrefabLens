# Extension Renderer and Demo Design

Date: 2026-08-12

Status: Approved for plan review

Base commit: `b27328cafb5ea6f163d42651044bade511daa874`

## Goal

Remove repeated file-view policy from the content script and the demo.

Keep the renderer cohesive. Remove tests that protect private markup or duplicated output rules.

Preserve all current extension and demo behavior.

## Constraints

- Do not split `render.ts` because of its line count.
- Share a policy only when the content script and the demo use the same policy.
- Keep context-specific lifecycle and transport work in each context.
- Pass each dependency as a direct parameter.
- Do not add a dependency object or an argument object.
- Add comments only when they explain a reason.
- Use `extension/fixtures/` for shared static test data only.
- Keep a stateful test implementation in its only test file.
- Do not use mocks, stubs, spies, or private call-count assertions.

## Current Structure

The renderer already serves both contexts. It owns DOM output, theme selection, action panels, tree layout, and field-value text.

The toggle and view-state modules also serve both contexts.

The repeated policy is in these files:

- `presentation/content/overlay/file-view.ts`
- `presentation/demo/index.ts`

Both files create a semantic host. Both files hide raw content and show semantic content.

Both files mount a per-file toggle. Both files start semantic work when the semantic view becomes active.

The surrounding lifecycle is different. GitHub can replace content DOM nodes. The demo DOM is static.

## File-View Controller

Add one small controller under `presentation/internal/`.

The controller owns these common rules:

- Create one semantic host and one shadow root.
- Attach the semantic host when it is not connected.
- Show raw content and hide the semantic host for Raw.
- Hide raw content and show the semantic host for Semantic.
- Keep the per-file toggle state equal to the active view.
- Call the semantic callback when Semantic becomes active.

Use this boundary:

```ts
export type FileViewController = {
  element: HTMLElement;
  apply(view: View): void;
  sync(view: View): void;
};

export function createFileViewController(
  initial: View,
  onSelect: (view: View) => void,
  setRawHidden: (hidden: boolean) => void,
  attachHost: (host: HTMLDivElement) => void,
  semanticVisible: () => boolean,
  onSemantic: (root: ShadowRoot) => void,
): FileViewController;
```

The controller receives direct callback parameters. It does not receive a `Deps`, `Options`, `Context`, or adapter object.

The controller returns the toggle element plus `apply` and `sync` functions.

`apply` updates the toggle and the view. Global view changes use this function.

`sync` repairs DOM visibility without a user selection. GitHub remount handling uses this function.

The semantic callback can run more than once. Each caller owns its request or render guard.

## Context Ownership

The content file view keeps this work:

- GitHub DOM attachment and collapse state
- React remount repair
- background messages
- semantic request state
- authorization retry registration
- size-gate retry
- resolved-push registration and watchdogs

The demo keeps this work:

- fixture URLs
- local diff creation
- static fixture index loading
- demo collapse buttons
- the one-render guard for static fixtures

The controller does not know about GitHub, fixtures, Chrome, WASM, storage, or semantic diff results.

## Renderer

Keep `presentation/internal/render.ts` as one file.

Its internal functions form one DOM rendering pipeline. A split adds navigation without a new dependency boundary.

Do not change renderer output in this stage.

## Error Handling

The controller does not catch errors. It changes DOM visibility and calls the semantic callback.

The content file view keeps its current expected-error panels and retry behavior.

The demo keeps its current error panel for fixture or WASM failures.

## Test Policy

Add focused controller tests with real DOM elements and the real toggle.

The controller tests protect these contracts:

- Raw and Semantic change raw and semantic visibility.
- The semantic host is created once and reattached after removal.
- Global `apply` changes the toggle without a user-selection callback.
- `sync` obeys the caller's semantic visibility state.

Use observable DOM state and callback results. Do not inspect private call counts.

Delete `value-format.parity.test.ts` in full. Each implementation already tests its public output.

The removed source parsers do not run the other implementations. They couple tests to private source syntax.

Keep `builtin-refs.parity.test.ts`. It compares generated data tables across three checked-in implementations.

Delete `styles.parity.test.ts`. CSS class-set equality is a private implementation detail.

The CLI owns its standalone page color-scheme test.

Consolidate the renderer tests around user-visible contracts. Delete tests that only inspect icons, CSS classes, chevron slots, or spinners.

Keep tests for these renderer risks:

- hierarchy, component grouping, field values, and fallback names
- untrusted repository text
- empty, incomplete, large-file, loading, and sign-in actions
- link security
- light, dark, and automatic theme selection

Fold small added-field and resolving assertions into the closest retained contract.

Delete direct toggle tests after the controller tests protect toggle selection and programmatic updates.

Keep only distinct view-state cases. Fold `clearOverrides` and pure no-op assertions into the default-change cases.

## Browser Coverage

Keep the current loaded-extension browser suite.

It protects real WASM output, Raw and Semantic switching, global switching, React remounts, size gates, retries, and sign-in.

Do not add a second browser suite for the static demo.

Add one demo composition test only if the controller wiring has a risk that its focused tests cannot detect.

## Documentation

Update `docs/extension.md` only when the final code adds a durable design rule.

Do not document file names that are private implementation details.

## Success Criteria

- The content script and the demo use one file-view controller.
- The renderer remains one cohesive file.
- The container remains free of I/O and conversion.
- No dependency object or argument object exists.
- Renderer output and browser behavior remain unchanged.
- Low-value parity, CSS, icon, class, and private-markup tests are absent.
- All extension checks and browser tests pass.
