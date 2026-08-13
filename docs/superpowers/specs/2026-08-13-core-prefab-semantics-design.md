# Core Prefab Semantics Refactor

Date: 2026-08-13
Status: Proposed

## Purpose

This refactor makes `core/` easier to change without changing its public behavior.

The first implementation has three goals:

- Make recoverable parse failures different from allocation failures.
- Give Unity prefab semantics one clear owner.
- Remove the production dependency cycle between `diff.zig` and `diff_overrides.zig`.

The implementation keeps the current flat Zig module structure. It does not copy the directory layers from `site/` or `extension/`.

## Constraints

- Preserve the `prefablens.diff.v2` JSON schema.
- Preserve the public functions in `root.zig`.
- Keep `core/` independent of file, network, browser, and extension I/O.
- Continue to receive source prefab bytes from the caller.
- Continue to use a caller-owned allocator for result memory.
- Use direct function parameters. Do not add dependency bags or context objects to public APIs.
- Use real Unity YAML fixtures and real WASM integration tests.
- Do not add mocks or stubs.
- Keep the current performance and WASM size budgets.
- Keep tolerant handling for malformed Unity YAML where the current contract permits it.

## Current Structure

The public flow is:

```text
root.zig
  -> diff.zig
     -> parser.zig
     -> diff_overrides.zig
  -> tree.zig
     -> tree_chain.zig
  -> instantiate.zig
  -> json.zig
```

This structure has useful properties. `root.zig` is small, `core/` owns no I/O, and each diff uses one arena.

Three details now make changes harder:

1. `instantiate.zig` catches every source parse error and returns a degraded result.
2. Prefab rules exist in `diff_overrides.zig`, `instantiate.zig`, `tree.zig`, and `tree_chain.zig`.
3. `diff_overrides.zig` calls `diff.zig` to create a display value, while `diff.zig` already imports `diff_overrides.zig`.

`model.zig` also contains both parsed YAML types and public result types. That split is useful, but it is not part of this implementation.

## Selected Approach

Add one flat semantic module named `prefab.zig`. Move shared prefab rules into this module in small stages.

First, correct the error contract. Next, extract prefab semantics and remove the dependency cycle.

This order keeps each change reviewable. It also separates a correctness fix from structural movement.

### Alternatives

#### Reorganize all files by processing stage

This option creates parser, semantic, diff, and presentation directories in one change.

It creates a large move before the semantic boundaries are stable. This design defers the option.

#### Copy the extension layer structure

The extension benefits from presentation, application, domain, and infrastructure boundaries. `core/` is a small allocation-oriented Zig library with no I/O.

The same directory structure adds indirection without adding a useful boundary. This design rejects the option.

#### Add a generic pipeline or visitor

The current algorithms use direct data flow and arena allocation. A generic abstraction hides control flow and error propagation.

This design rejects the option.

## Error Contract

`parser.zig` will define this explicit error set:

```zig
pub const Error = std.mem.Allocator.Error || error{NestingTooDeep};
```

Recursive parser functions will return `Error` instead of `anyerror`. Recursive allocation-only functions in `diff.zig` will return `std.mem.Allocator.Error`.

Source prefab expansion will handle parser errors as follows:

- `NestingTooDeep` leaves only that instance in the degraded view.
- `OutOfMemory` returns to the caller.

This rule preserves the existing recovery behavior for an unsafe source asset. It prevents resource exhaustion from appearing as a valid partial diff.

The parser will keep its current tolerant rules for malformed values. Invalid numeric header fields still become zero, and unsupported document bodies still become empty maps.

`root.zig` will expose these named public error sets:

```zig
pub const DiffError = parser.Error;
pub const JsonError = DiffError || std.Io.Writer.Error;
```

The two `diffBytes` functions will return `DiffError`. The two `diffToJson` functions will return `JsonError`.

## Prefab Semantic Boundary

`prefab.zig` will own concepts that describe Unity `PrefabInstance` data. It will not own the diff algorithm or tree construction.

The module will provide these concepts:

- `Assets`, the GUID-to-source-bytes map.
- `Modification`, a validated view of one `m_Modifications` item and its target reference.
- Iteration over valid modifications in source order.
- The identity key for `(target fileID, propertyPath)`.
- The effective value rule, which selects a set `objectReference` before `value`.
- Source prefab GUID lookup.
- Lookup of a scalar modification value by property path.

The iterator will skip malformed modification entries. This behavior matches the current tolerant readers.

The module will not allocate while it reads a modification. Key creation can allocate because current maps use string keys.

Consumers will have these responsibilities:

- `diff_overrides.zig` compares modifications and creates `OverrideDiff` rows.
- `instantiate.zig` applies modifications to parsed source documents.
- `tree.zig` reads the source GUID for each prefab instance.
- `tree_chain.zig` resolves hierarchy links and asks `prefab.zig` for override values.
- `assets_tlv.zig` decodes bytes into `prefab.Assets`.
- `root.zig` re-exports `prefab.Assets` as `Assets`.

This boundary gives the serialized Unity concept one owner. It does not create a general utility module.

## Dependency Cycle Removal

The synthesized scalar value for vectors belongs to display formatting. Move `parenJoinNode` from `diff.zig` to `inspector.zig` with a descriptive name.

Both `diff.zig` and `diff_overrides.zig` will call `inspector.zig`. Production declarations will no longer depend on each other in both directions.

When tests need full diff behavior, they can import the public composition path. Test imports must not affect production ownership.

## Data Flow After the Refactor

```text
root.zig
  -> diff.zig
     -> parser.zig
     -> diff_overrides.zig
        -> prefab.zig
        -> inspector.zig
  -> tree.zig
     -> prefab.zig
     -> tree_chain.zig
        -> prefab.zig
  -> instantiate.zig
     -> parser.zig
     -> prefab.zig
  -> json.zig
```

For a one-sided prefab instance, the flow remains:

1. Read the source GUID from the instance document.
2. Add a missing source to `needed_sources`.
3. Parse a supplied source with the same arena.
4. Apply matching modifications and removed components.
5. Run the existing one-sided diff and tree builder.
6. Expand nested instances within the current depth and cycle limits.
7. Keep unapplied modifications as override rows.

## Testing

The implementation will keep the current regression suite. When a function moves, its tests will move with it.

Add focused tests for these contracts:

- `parser.parse` returns `NestingTooDeep` for unsafe nesting.
- `parser.parse` returns `OutOfMemory` from a real bounded allocator.
- Source expansion degrades only for `NestingTooDeep`.
- Source expansion returns `OutOfMemory` to the caller.
- `prefab.Modification` skips malformed entries and preserves valid source order.
- The effective value rule prefers a non-empty object reference.
- Duplicate modification keys keep the existing last-value behavior.
- Source GUID and scalar modification lookup preserve current results.

Use a real `std.heap.FixedBufferAllocator` for allocation failure tests. Do not replace the allocator or parser with a fake implementation.

Run these checks after each implementation stage:

```sh
zig build lint --summary all
zig build test --summary all
zig build wasm --summary all
node --test core/tests/*.test.mjs
zig build perf
```

Run these extension checks after the final stage because the extension loads the real WASM module:

```sh
cd extension
pnpm test
pnpm size
pnpm e2e
```

## Implementation Stages

### Stage 1: Correct error propagation

- Add explicit parser and diff recursion error sets.
- Change source expansion to catch only `NestingTooDeep`.
- Add allocation failure regression tests.

### Stage 2: Extract prefab semantics

- Add `prefab.zig` and its focused tests.
- Move `Assets` and shared modification readers into it.
- Replace duplicate readers in all consumers.
- Keep public names and output unchanged.

### Stage 3: Remove the dependency cycle

- Move synthesized vector display values into `inspector.zig`.
- Remove the production import from `diff_overrides.zig` to `diff.zig`.
- Run native, WASM, integration, performance, and size checks.

Each stage will be a separate implementation commit. A stage must pass its relevant checks before the next stage starts.

## Deferred Work

The following changes are outside this implementation:

- Split `model.zig` into parsed YAML types and public result types.
- Rename existing public functions or result fields.
- Change the JSON schema or WASM ABI.
- Add directory layers under `core/src/`.
- Replace direct functions with a generic pipeline.
- Remove existing tests only because code moved.

After this refactor, the `model.zig` split can use the stable semantic dependency graph. A separate change will contain that follow-up.

## Acceptance Criteria

- Public native and WASM behavior stays unchanged for existing fixtures.
- Allocation failures are never converted into successful partial diffs.
- `m_Modifications` parsing and value selection have one implementation.
- `diff.zig` and `diff_overrides.zig` have no production dependency cycle.
- All baseline tests pass.
- WASM golden tests pass.
- Performance and compressed WASM size stay within their current budgets.
