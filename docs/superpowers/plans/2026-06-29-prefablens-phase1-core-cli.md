# PrefabLens Phase 1 (Core + CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Target: Zig 0.16.0.** The pinned toolchain is 0.16.0 (latest stable). NOTE: the code blocks in Tasks 2–13 below were first drafted against 0.14.x idioms (managed `std.ArrayList(T).init(allocator)`, `std.io.getStdOut().writer()`, the old `addExecutable` form). These are migrated to 0.16 idioms **per-task, just-in-time, and compile-verified** when each task is reached — do not treat the older code blocks as final. The 0.16 idioms you will use instead: unmanaged `std.ArrayList` (`var list: std.ArrayList(T) = .empty;` + `list.append(allocator, x)` + `list.toOwnedSlice(allocator)`), the new `std.Io` Writer for output, and the `root_module = b.createModule(.{...})` form in `build.zig`.
>
> **On the code in this plan:** Every code block is a complete, intended implementation — not pseudocode. The tests in each task are the contract. Follow TDD strictly: write the failing test, run it, make it pass. If a provided implementation does not compile or a test fails for a reason the test did not intend, fix the implementation to satisfy the test — do not weaken the test.

**Goal:** Ship a native CLI that semantically diffs Unity `.prefab` / `.unity` / `.asset` YAML files — matching objects by `fileID`, diffing fields (old→new), resolving local `guid` references via a `.meta` scan — and renders the result as an ANSI tree, structured JSON, or self-contained HTML.

**Architecture:** A pure Zig **core** library (`/core`) parses Unity-YAML into a document model, matches documents by `fileID`, computes a field-level diff, reconstructs the GameObject hierarchy, and serializes a structured `prefablens.diff.v1` JSON — with no I/O and no global state. A thin Zig **CLI** (`/cli`) links the core directly (no FFI), acquires the before/after bytes (files or git refs), resolves `guid`s through a local `.meta` index, and renders the `DiffResult`. This mirrors the spec's seam (§4.2): core returns a structured diff + an *unresolved guid set*; each host plugs its own resolver into that seam.

**Tech Stack:** Zig 0.16.0 (pinned), `std.testing` for unit/golden tests, GitHub Actions for CI. No third-party dependencies. Git is invoked as a subprocess for ref input.

## Global Constraints

These apply to **every** task. Values are copied verbatim from the design spec (`docs/superpowers/specs/2026-06-29-unity-prefab-diff-design.md`).

- **Zig version: pinned to `0.16.0`** (latest stable). Recorded in `mise.toml` (local install/pin), `.zigversion` (portable marker), and `build.zig.zon`'s `.minimum_zig_version`. We target current idioms (unmanaged `std.ArrayList`, `std.Io` Writer, `root_module` build form). Pinning matters because Zig is pre-1.0 and breaks across minor versions — never let an unpinned `brew install zig` silently move the toolchain. Reference code is compile-verified against the installed 0.16.0 as we go.
- **Core is host-independent and pure.** `/core` must not perform file/network I/O, must not hold global mutable state, and must not import anything from `/cli`. Input = two byte slices; output = `DiffResult` (and, via `json.zig`, JSON bytes). This guarantees the same core is reused unchanged by Chrome (Phase 2), Editor (Phase 3), AI/MCP (Phase 4).
- **Memory model: arena per diff.** All core allocations use a caller-provided `std.mem.Allocator` that is expected to be an arena; scalars are **slices into the input buffer (zero-copy)** — never duplicate string content in the core. The input buffers must outlive the `DiffResult`.
- **`fileID` is serialized as a JSON string,** never a number — Unity `fileID`s are `i64` and routinely exceed `2^53`, so a JSON number would lose precision. Example: `"fileId": "8534698540125898342"`.
- **Match key is `fileID`** (spec §5.5). Name-based secondary matching is explicitly **out of scope for Phase 1**.
- **Product naming:** the product is **PrefabLens**; the CLI binary is `prefablens`; the Zig package name is the enum literal `.prefablens`. Never use the string "Unity" as a product/brand name (trademark); it may appear only descriptively ("for Unity").
- **Performance budget (native), enforced in CI (spec §5.7):** typical prefab (≤200 KB) parse+diff **< 5 ms**; large scene (~10 MB) parse+diff **< 150 ms**; peak memory ≤ ~3× input size. (CI gate uses a generous multiplier to avoid runner-noise flakiness; see Task 13.)
- **Commits:** conventional-commit subjects, imperative mood, ≤ 72 chars. Commit at the end of every task (some tasks commit mid-way at natural checkpoints).

---

## Data Contract: `prefablens.diff.v1`

This is the cross-host output contract. The core produces it; the CLI renderers and (later) every other host consume it. Defined here once; Tasks 7–12 reference it.

```jsonc
{
  "schema": "prefablens.diff.v1",
  "unresolvedGuids": ["<guid>", ...],          // external guids the core could not resolve
  "resolved": { "<guid>": "<assetPath>", ... },// OPTIONAL: present only when a host resolver ran (CLI adds it; pure core omits it)
  "roots": [ GameObjectNode, ... ],            // top-level GameObjects (Transform has no parent)
  "loose": [ ComponentNode, ... ]              // documents not owned by a GameObject (e.g. a ScriptableObject .asset)
}

// GameObjectNode
{
  "kind": "gameObject",
  "fileId": "<i64 as string>",
  "name": "<m_Name or empty string>",
  "status": "added" | "removed" | "modified" | "unchanged",
  "components": [ ComponentNode, ... ],
  "children": [ GameObjectNode, ... ]
}

// ComponentNode
{
  "kind": "component",
  "fileId": "<i64 as string>",
  "classId": <number>,                         // Unity classID (small, safe as number)
  "typeName": "<resolved built-in type name or empty>",
  "scriptGuid": "<guid>" | null,               // for MonoBehaviour: m_Script.guid
  "scriptName": "<resolved name>" | null,      // OPTIONAL: filled by host resolver (CLI), else absent
  "status": "added" | "removed" | "modified" | "unchanged",
  "fields": [ FieldNode, ... ]                 // empty unless status == modified (or added/removed snapshot, see below)
}

// FieldNode  — one changed leaf
{
  "path": "<dotted/indexed path, e.g. m_LocalPosition.x or m_Component[2].component>",
  "status": "added" | "removed" | "modified",
  "before": Value | null,
  "after":  Value | null
}

// Value
"<scalar text>"                                 // a scalar
| { "ref": { "fileId": "<i64 as string>", "guid": "<guid>" | null, "type": <number> | null } }
```

Rules:
- `status: "unchanged"` nodes are **collapsed** out of `roots`/`loose`/`children`/`components` *unless* they are needed as a structural parent of a changed descendant (an unchanged GameObject that contains a modified component is kept, with `status: "unchanged"`, so the tree stays connected).
- For an `added` component/object, `fields` is empty and the node's mere presence + `status: "added"` conveys the addition. Same for `removed`. (Phase 1 does not snapshot every field of an added object.)
- Object key ordering in JSON: emit keys in the order shown above. Arrays preserve discovery order (document order from the *after* version; removed items keep their *before* order, appended after).

---

## File Structure

One Zig build at the repo root drives both `/core` and `/cli` (spec §8 permits combining them).

```
/.zigversion                     # "0.14.1"
/build.zig                       # core module + cli exe + test step + perf step
/build.zig.zon                   # package manifest (generated by `zig init`, then edited)
/.github/workflows/ci.yml        # install Zig 0.14.1; zig build test; perf gate
/core/
  src/
    root.zig                     # public surface: re-exports + diffBytes() convenience
    model.zig                    # Node, Document, Ref, FieldDiff, ComponentDiff, ObjectDiff, DiffResult, Status; Node.eql
    classid.zig                  # static classID -> type name table
    parser.zig                   # Unity-YAML subset parser -> []Document
    diff.zig                     # match-by-fileID + field diff -> flat per-document diffs + unresolved guids
    tree.zig                     # reconstruct GameObject hierarchy -> DiffResult (roots + loose)
    json.zig                     # DiffResult -> prefablens.diff.v1 bytes
  tests/
    fixtures/                    # large fixtures for perf (small ones are inline string literals)
      scene_10mb.unity           # generated by a script in Task 13 (not committed if huge; see task)
/cli/
  src/
    main.zig                     # arg parsing; run(allocator, args, stdout) testable entrypoint
    input.zig                    # file + git-ref acquisition (git show subprocess)
    resolve.zig                  # .meta scan -> guid->path index (host resolver)
    render_tree.zig              # ANSI tree renderer (default)
    render_html.zig              # self-contained HTML renderer (--html)
  tests/
    fixtures/                    # on-disk fixtures for CLI golden tests (real files the binary reads)
```

Each `src/*.zig` file owns one responsibility and contains its own `test {}` blocks (Zig convention). `root.zig` and `main.zig` are the two test roots wired in `build.zig`.

---

## Task 1: Toolchain pin, project scaffold, build wiring, CI skeleton

**Files:**
- Create: `.zigversion`
- Create/Modify: `build.zig`, `build.zig.zon` (generated by `zig init`, then edited)
- Create: `core/src/root.zig`, `cli/src/main.zig` (minimal smoke versions)
- Create: `.github/workflows/ci.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `zig build test` runs core + cli test roots; `zig build run -- ...` runs the CLI; module name `"core"` is importable from `/cli`. A green CI workflow.

- [ ] **Step 1: Install and pin Zig 0.16.0**

Using mise (already installed on this machine), from the repo root:
```bash
mise use zig@0.16.0
```
This installs Zig 0.16.0 and writes `mise.toml` pinning it for this directory.

Also create `.zigversion` (a portable marker some CI/tools read):
```
0.16.0
```

Verify the active toolchain:
```bash
zig version
```
Expected: `0.16.0`

- [ ] **Step 2: Scaffold with `zig init`**

From the repo root:
```bash
zig init
```
This generates `build.zig` and `build.zig.zon` with a correct `.fingerprint` (a machine-generated `u64` — never hand-write it) and `.name` for Zig 0.14.1. It also generates `src/` template files.

- [ ] **Step 3: Restructure into core/ and cli/ and write the smoke sources**

Remove the generated `src/` template (`src/main.zig`, `src/root.zig`) — we use `/core` and `/cli` instead.

Create `core/src/root.zig`:
```zig
const std = @import("std");

/// Phase 1 public surface grows in later tasks. Smoke test proves the build wiring.
pub fn version() []const u8 {
    return "0.1.0-dev";
}

test "core builds and version is reported" {
    try std.testing.expectEqualStrings("0.1.0-dev", version());
}
```

Create `cli/src/main.zig`:
```zig
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("prefablens {s}\n", .{core.version()});
}

test "cli can import core" {
    try std.testing.expectEqualStrings("0.1.0-dev", core.version());
}
```

- [ ] **Step 4: Write `build.zig`**

Replace the generated `build.zig` with:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reusable, host-independent core module (no target pin: it inherits the importer's).
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("core/src/root.zig"),
    });

    // CLI executable links the core module directly (no FFI).
    const exe = b.addExecutable(.{
        .name = "prefablens",
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("core", core_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the PrefabLens CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit/golden tests: two roots.
    const core_tests = b.addTest(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_tests = b.addTest(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests.root_module.addImport("core", core_mod);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}
```

- [ ] **Step 5: Edit `build.zig.zon`**

Open the generated `build.zig.zon`. Keep the generated `.fingerprint` untouched. Set `.name`, `.version`, add `.minimum_zig_version`, and set `.paths`:
```zig
.{
    .name = .prefablens,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.1",
    // .fingerprint = 0x...  <- KEEP whatever `zig init` generated; do not change.
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "core",
        "cli",
    },
}
```
> If `zig init` errored on the repo directory name (`prefab-lens` contains a hyphen, which is not a valid bare identifier), it will have left `.name` blank or invalid — setting `.name = .prefablens` here fixes it.

- [ ] **Step 6: Run the smoke tests**

Run: `zig build test`
Expected: PASS (no output, exit 0). If it fails, the build wiring or manifest is wrong — fix before continuing.

Run: `zig build run`
Expected output: `prefablens 0.1.0-dev`

- [ ] **Step 7: Update `.gitignore`**

Append Zig build artifacts:
```
# Zig
zig-cache/
.zig-cache/
zig-out/
```

- [ ] **Step 8: Write CI workflow**

Create `.github/workflows/ci.yml`:
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig 0.14.1
        uses: mlugg/setup-zig@v1
        with:
          version: 0.14.1
      - name: Build
        run: zig build
      - name: Test
        run: zig build test
```

- [ ] **Step 9: Commit**
```bash
git add .zigversion build.zig build.zig.zon core cli .github .gitignore
git commit -m "chore: scaffold Zig 0.14.1 monorepo with core module, CLI, and CI"
```

---

## Task 2: Core data model (`model.zig`)

**Files:**
- Create: `core/src/model.zig`
- Modify: `core/src/root.zig` (re-export `model`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Ref = struct { file_id: i64, guid: ?[]const u8 = null, type_id: ?i64 = null }`
  - `Entry = struct { key: []const u8, value: *Node }`
  - `Node = union(enum) { map: []Entry, seq: []*Node, scalar: []const u8, ref: Ref }`
  - `pub fn Node.eql(a: *const Node, b: *const Node) bool`
  - `Status = enum { added, removed, modified, unchanged }`
  - `FieldDiff = struct { path: []const u8, status: Status, before: ?*const Node, after: ?*const Node }`
  - `ComponentDiff = struct { file_id: i64, class_id: u32, type_name: []const u8, script_guid: ?[]const u8 = null, status: Status, fields: []FieldDiff }`
  - `ObjectDiff = struct { file_id: i64, name: []const u8, status: Status, components: []ComponentDiff, children: []ObjectDiff }`
  - `DiffResult = struct { roots: []ObjectDiff, loose: []ComponentDiff, unresolved_guids: [][]const u8 }`

- [ ] **Step 1: Write the failing test for `Node.eql`**

Create `core/src/model.zig` with only the test (and an empty stub so it compiles to a *failing* state):
```zig
const std = @import("std");

// (types will be added in Step 3)

test "Node.eql: scalars, refs, seqs, maps" {
    const a = std.testing.allocator;
    _ = a;
    // Scalars
    var s1 = Node{ .scalar = "100" };
    var s2 = Node{ .scalar = "100" };
    var s3 = Node{ .scalar = "150" };
    try std.testing.expect(Node.eql(&s1, &s2));
    try std.testing.expect(!Node.eql(&s1, &s3));

    // Refs: equal iff file_id, guid, type_id all match
    var r1 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r2 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r3 = Node{ .ref = .{ .file_id = 234, .guid = "xyz", .type_id = 3 } };
    try std.testing.expect(Node.eql(&r1, &r2));
    try std.testing.expect(!Node.eql(&r1, &r3));

    // Cross-kind is never equal
    try std.testing.expect(!Node.eql(&s1, &r1));

    // Seqs: elementwise
    var seq_a = [_]*Node{ &s1, &s3 };
    var seq_b = [_]*Node{ &s2, &s3 };
    var q1 = Node{ .seq = &seq_a };
    var q2 = Node{ .seq = &seq_b };
    try std.testing.expect(Node.eql(&q1, &q2));

    // Maps: same keys + equal values (order-insensitive)
    var e_a = [_]Entry{ .{ .key = "x", .value = &s1 }, .{ .key = "y", .value = &s3 } };
    var e_b = [_]Entry{ .{ .key = "y", .value = &s3 }, .{ .key = "x", .value = &s2 } };
    var m1 = Node{ .map = &e_a };
    var m2 = Node{ .map = &e_b };
    try std.testing.expect(Node.eql(&m1, &m2));
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'Node'` / `'Entry'`.

- [ ] **Step 3: Implement the model types and `eql`**

Replace the top of `core/src/model.zig` (above the test) with:
```zig
const std = @import("std");

/// External or local reference: `{fileID: N}` or `{fileID: N, guid: ..., type: N}`.
pub const Ref = struct {
    file_id: i64,
    guid: ?[]const u8 = null,
    type_id: ?i64 = null,
};

pub const Entry = struct {
    key: []const u8, // slice into source
    value: *Node,
};

/// A parsed Unity-YAML value. Scalars/keys/guids are slices into the input buffer.
pub const Node = union(enum) {
    map: []Entry,
    seq: []*Node,
    scalar: []const u8,
    ref: Ref,

    pub fn eql(a: *const Node, b: *const Node) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .scalar => |sa| std.mem.eql(u8, sa, b.scalar),
            .ref => |ra| blk: {
                const rb = b.ref;
                if (ra.file_id != rb.file_id) break :blk false;
                if (ra.type_id != rb.type_id) break :blk false;
                break :blk strEqOpt(ra.guid, rb.guid);
            },
            .seq => |sa| blk: {
                const sb = b.seq;
                if (sa.len != sb.len) break :blk false;
                for (sa, sb) |ea, eb| if (!eql(ea, eb)) break :blk false;
                break :blk true;
            },
            .map => |ma| blk: {
                const mb = b.map;
                if (ma.len != mb.len) break :blk false;
                for (ma) |entry| {
                    const other = findValue(mb, entry.key) orelse break :blk false;
                    if (!eql(entry.value, other)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

fn strEqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Look up a value by key in a map's entries (linear; Unity maps are small).
pub fn findValue(entries: []const Entry, key: []const u8) ?*Node {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

/// One Unity document: `--- !u!<class_id> &<file_id>` + a body mapping.
pub const Document = struct {
    class_id: u32,
    file_id: i64,
    type_name: []const u8, // the single top-level key, e.g. "GameObject"
    stripped: bool = false,
    body: *Node, // a .map node of the document's fields
};

pub const Status = enum { added, removed, modified, unchanged };

pub const FieldDiff = struct {
    path: []const u8, // dotted/indexed path, arena-built
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};

pub const ComponentDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
};

pub const ObjectDiff = struct {
    file_id: i64,
    name: []const u8,
    status: Status,
    components: []ComponentDiff,
    children: []ObjectDiff,
};

pub const DiffResult = struct {
    roots: []ObjectDiff,
    loose: []ComponentDiff,
    unresolved_guids: [][]const u8,
};
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Re-export from `root.zig`**

Edit `core/src/root.zig` — add under the existing `const std`:
```zig
pub const model = @import("model.zig");
```
(Keep `version()` and its test.)

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add core/src/model.zig core/src/root.zig
git commit -m "feat(core): add document/diff data model with Node.eql"
```

---

## Task 3: Static classID → type-name table (`classid.zig`)

**Files:**
- Create: `core/src/classid.zig`
- Modify: `core/src/root.zig` (re-export `classid`)

**Interfaces:**
- Consumes: nothing.
- Produces: `pub fn typeName(class_id: u32) ?[]const u8` — returns the Unity built-in component type name, or `null` for unknown classIDs (host/script-defined).

- [ ] **Step 1: Write the failing test**

Create `core/src/classid.zig`:
```zig
const std = @import("std");

test "classID lookup covers common types and returns null for unknown" {
    try std.testing.expectEqualStrings("GameObject", typeName(1).?);
    try std.testing.expectEqualStrings("Transform", typeName(4).?);
    try std.testing.expectEqualStrings("MonoBehaviour", typeName(114).?);
    try std.testing.expectEqualStrings("MeshRenderer", typeName(23).?);
    try std.testing.expectEqualStrings("RectTransform", typeName(224).?);
    try std.testing.expectEqualStrings("PrefabInstance", typeName(1001).?);
    try std.testing.expect(typeName(999999) == null);
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `zig build test`
Expected: FAIL — `use of undeclared identifier 'typeName'`.

- [ ] **Step 3: Implement the table**

Add above the test in `core/src/classid.zig`:
```zig
const Pair = struct { id: u32, name: []const u8 };

// Common Unity classIDs (subset sufficient for prefab/scene/asset diffing).
// Source: Unity "YAML Class ID Reference".
const table = [_]Pair{
    .{ .id = 1, .name = "GameObject" },
    .{ .id = 2, .name = "Component" },
    .{ .id = 4, .name = "Transform" },
    .{ .id = 8, .name = "Behaviour" },
    .{ .id = 20, .name = "Camera" },
    .{ .id = 21, .name = "Material" },
    .{ .id = 23, .name = "MeshRenderer" },
    .{ .id = 25, .name = "Renderer" },
    .{ .id = 33, .name = "MeshFilter" },
    .{ .id = 64, .name = "MeshCollider" },
    .{ .id = 65, .name = "BoxCollider" },
    .{ .id = 81, .name = "AudioListener" },
    .{ .id = 82, .name = "AudioSource" },
    .{ .id = 95, .name = "Animator" },
    .{ .id = 108, .name = "Light" },
    .{ .id = 114, .name = "MonoBehaviour" },
    .{ .id = 115, .name = "MonoScript" },
    .{ .id = 135, .name = "SphereCollider" },
    .{ .id = 136, .name = "CapsuleCollider" },
    .{ .id = 137, .name = "SkinnedMeshRenderer" },
    .{ .id = 143, .name = "CharacterController" },
    .{ .id = 198, .name = "ParticleSystem" },
    .{ .id = 199, .name = "ParticleSystemRenderer" },
    .{ .id = 212, .name = "SpriteRenderer" },
    .{ .id = 222, .name = "CanvasRenderer" },
    .{ .id = 223, .name = "Canvas" },
    .{ .id = 224, .name = "RectTransform" },
    .{ .id = 225, .name = "CanvasGroup" },
    .{ .id = 320, .name = "PlayableDirector" },
    .{ .id = 1001, .name = "PrefabInstance" },
    .{ .id = 1660057539, .name = "SceneRoots" },
};

pub fn typeName(class_id: u32) ?[]const u8 {
    for (table) |p| if (p.id == class_id) return p.name;
    return null;
}
```

- [ ] **Step 4: Run to confirm pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Re-export and commit**

Edit `core/src/root.zig`, add:
```zig
pub const classid = @import("classid.zig");
```
```bash
git add core/src/classid.zig core/src/root.zig
git commit -m "feat(core): add static Unity classID to type-name table"
```

---

## Task 4: Unity-YAML subset parser (`parser.zig`)

This is the largest core task. Build it test-first, one Unity pattern at a time. The parser is an indentation-driven recursive-descent over logical lines.

**Files:**
- Create: `core/src/parser.zig`
- Modify: `core/src/root.zig` (re-export `parser`)

**Interfaces:**
- Consumes: `model.Document`, `model.Node`, `model.Entry`, `model.Ref`.
- Produces: `pub fn parse(arena: std.mem.Allocator, source: []const u8) ![]model.Document`. All returned slices/strings are backed by `arena` or are slices into `source`.

- [ ] **Step 1: Write failing tests for the simplest cases (document split + flat map)**

Create `core/src/parser.zig` with the test block first:
```zig
const std = @import("std");
const model = @import("model.zig");
const Node = model.Node;
const Entry = model.Entry;
const Document = model.Document;

const testing = std.testing;

fn parseOne(arena: std.mem.Allocator, src: []const u8) !Document {
    const docs = try parse(arena, src);
    try testing.expectEqual(@as(usize, 1), docs.len);
    return docs[0];
}

test "parse: single document header + flat scalar fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\%YAML 1.1
        \\%TAG !u! tag:unity3d.com,2011:
        \\--- !u!1 &123456789
        \\GameObject:
        \\  m_Name: Player
        \\  m_IsActive: 1
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqual(@as(u32, 1), doc.class_id);
    try testing.expectEqual(@as(i64, 123456789), doc.file_id);
    try testing.expectEqualStrings("GameObject", doc.type_name);

    const name = model.findValue(doc.body.map, "m_Name").?;
    try testing.expectEqualStrings("Player", name.scalar);
    const active = model.findValue(doc.body.map, "m_IsActive").?;
    try testing.expectEqualStrings("1", active.scalar);
}

test "parse: multiple documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &100
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &200
        \\Transform:
        \\  m_GameObject: {fileID: 100}
    ;
    const docs = try parse(arena, src);
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqual(@as(i64, 100), docs[0].file_id);
    try testing.expectEqual(@as(u32, 4), docs[1].class_id);
    try testing.expectEqualStrings("Transform", docs[1].type_name);
}

test "parse: stripped flag on PrefabInstance documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &500 stripped
        \\GameObject:
        \\  m_Name: NestedRoot
    ;
    const doc = try parseOne(arena, src);
    try testing.expect(doc.stripped);
}
```

- [ ] **Step 2: Run — confirm failure (no `parse`)**

Run: `zig build test`
Expected: FAIL — `use of undeclared identifier 'parse'`.

- [ ] **Step 3: Implement the line model, document split, and block mapping**

Add above the tests in `core/src/parser.zig`:
```zig
const Ref = model.Ref;

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    arena: std.mem.Allocator,
    lines: []const Line,
    pos: usize = 0,

    fn peek(self: *const Parser) ?Line {
        return if (self.pos < self.lines.len) self.lines[self.pos] else null;
    }
    fn advance(self: *Parser) ?Line {
        const l = self.peek() orelse return null;
        self.pos += 1;
        return l;
    }
};

/// Tokenize into significant logical lines (indent + content), dropping
/// blanks, `%` directives, and `#` comments.
fn tokenize(arena: std.mem.Allocator, source: []const u8) ![]Line {
    var lines = std.ArrayList(Line).init(arena);
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw0| {
        var raw = raw0;
        if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        const content = raw[indent..];
        if (content.len == 0) continue;
        if (content[0] == '%') continue;
        if (content[0] == '#') continue;
        try lines.append(.{ .indent = indent, .text = content });
    }
    return lines.toOwnedSlice();
}

pub fn parse(arena: std.mem.Allocator, source: []const u8) ![]Document {
    var p = Parser{ .arena = arena, .lines = try tokenize(arena, source) };
    var docs = std.ArrayList(Document).init(arena);
    while (p.peek()) |line| {
        if (!std.mem.startsWith(u8, line.text, "---")) {
            _ = p.advance();
            continue;
        }
        try docs.append(try parseDocument(&p));
    }
    return docs.toOwnedSlice();
}

fn parseDocument(p: *Parser) !Document {
    const header = p.advance().?; // "--- !u!1 &123 [stripped]"
    var class_id: u32 = 0;
    var file_id: i64 = 0;
    var stripped = false;
    var toks = std.mem.tokenizeScalar(u8, header.text, ' ');
    while (toks.next()) |t| {
        if (std.mem.startsWith(u8, t, "!u!")) {
            class_id = std.fmt.parseInt(u32, t[3..], 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "&")) {
            file_id = std.fmt.parseInt(i64, t[1..], 10) catch 0;
        } else if (std.mem.eql(u8, t, "stripped")) {
            stripped = true;
        }
    }

    var type_name: []const u8 = "";
    var body: *Node = undefined;
    if (p.peek()) |first| {
        if (!std.mem.startsWith(u8, first.text, "---")) {
            _ = p.advance(); // the "TypeName:" line at indent 0
            type_name = stripTrailingColon(first.text);
            body = try parseBlock(p, indentOfNext(p, 2));
        } else {
            body = try emptyMap(p.arena);
        }
    } else {
        body = try emptyMap(p.arena);
    }

    return Document{
        .class_id = class_id,
        .file_id = file_id,
        .type_name = type_name,
        .stripped = stripped,
        .body = body,
    };
}

/// The body's first field indent (Unity uses 2, but be tolerant): peek the
/// next line; if it's deeper than 0, use its indent, else default.
fn indentOfNext(p: *const Parser, default_indent: usize) usize {
    if (p.peek()) |l| if (l.indent > 0 and !std.mem.startsWith(u8, l.text, "---")) return l.indent;
    return default_indent;
}

/// Parse a block (mapping or sequence) whose entries sit at exactly `indent`.
fn parseBlock(p: *Parser, indent: usize) anyerror!*Node {
    const first = p.peek() orelse return emptyMap(p.arena);
    if (first.indent < indent or std.mem.startsWith(u8, first.text, "---")) return emptyMap(p.arena);
    if (std.mem.startsWith(u8, first.text, "- ") or std.mem.eql(u8, first.text, "-")) {
        return parseSeq(p, indent);
    }
    return parseMap(p, indent);
}

fn parseMap(p: *Parser, indent: usize) anyerror!*Node {
    var entries = std.ArrayList(Entry).init(p.arena);
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        _ = p.advance();
        const kv = splitKeyValue(line.text);
        var value: *Node = undefined;
        if (kv.value.len == 0) {
            // nested block at deeper indent (map or seq); could also be empty.
            const child_indent = indentOfNext(p, indent + 2);
            if (child_indent > indent) {
                value = try parseBlock(p, child_indent);
            } else {
                value = try emptyMap(p.arena);
            }
        } else {
            value = try parseValue(p.arena, kv.value);
        }
        try entries.append(.{ .key = kv.key, .value = value });
    }
    return makeNode(p.arena, .{ .map = try entries.toOwnedSlice() });
}

fn parseSeq(p: *Parser, indent: usize) anyerror!*Node {
    var items = std.ArrayList(*Node).init(p.arena);
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (!(std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-"))) break;
        _ = p.advance();
        const rest = if (line.text.len >= 2) std.mem.trimLeft(u8, line.text[1..], " ") else "";
        if (rest.len == 0) {
            // "-" alone: nested block belongs to this item at deeper indent.
            const ci = indentOfNext(p, indent + 2);
            try items.append(try parseBlock(p, ci));
        } else if (looksLikeMapEntry(rest)) {
            // compact map item: first entry on the dash line, continuation at indent+2.
            try items.append(try parseSeqMapItem(p, indent, rest));
        } else {
            try items.append(try parseValue(p.arena, rest));
        }
    }
    return makeNode(p.arena, .{ .seq = try items.toOwnedSlice() });
}

/// A sequence item that is a mapping, e.g.
///   - target: {fileID: 0}
///     propertyPath: m_Name
///     value: Foo
fn parseSeqMapItem(p: *Parser, dash_indent: usize, first_line: []const u8) anyerror!*Node {
    var entries = std.ArrayList(Entry).init(p.arena);
    const kv = splitKeyValue(first_line);
    if (kv.value.len == 0) {
        const ci = indentOfNext(p, dash_indent + 4);
        try entries.append(.{ .key = kv.key, .value = try parseBlock(p, ci) });
    } else {
        try entries.append(.{ .key = kv.key, .value = try parseValue(p.arena, kv.value) });
    }
    // Continuation entries are indented two past the dash (aligned after "- ").
    const cont_indent = dash_indent + 2;
    while (p.peek()) |line| {
        if (line.indent != cont_indent) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        _ = p.advance();
        const e = splitKeyValue(line.text);
        var value: *Node = undefined;
        if (e.value.len == 0) {
            const ci = indentOfNext(p, cont_indent + 2);
            value = if (ci > cont_indent) try parseBlock(p, ci) else try emptyMap(p.arena);
        } else {
            value = try parseValue(p.arena, e.value);
        }
        try entries.append(.{ .key = e.key, .value = value });
    }
    return makeNode(p.arena, .{ .map = try entries.toOwnedSlice() });
}

// ---------- helpers ----------

fn makeNode(arena: std.mem.Allocator, value: Node) !*Node {
    const n = try arena.create(Node);
    n.* = value;
    return n;
}

fn emptyMap(arena: std.mem.Allocator) !*Node {
    return makeNode(arena, .{ .map = &[_]Entry{} });
}

fn stripTrailingColon(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    return if (t.len > 0 and t[t.len - 1] == ':') t[0 .. t.len - 1] else t;
}

const KV = struct { key: []const u8, value: []const u8 };

/// Split "key: value" / "key:" at the first ": " or trailing ":".
/// Does not split inside a flow value (the value starts after the first colon).
fn splitKeyValue(line: []const u8) KV {
    // Find the first ":" that is followed by a space or end-of-line.
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ':' and (i + 1 == line.len or line[i + 1] == ' ')) {
            const key = std.mem.trim(u8, line[0..i], " ");
            const value = std.mem.trim(u8, line[i + 1 ..], " ");
            return .{ .key = key, .value = value };
        }
    }
    return .{ .key = std.mem.trim(u8, line, " "), .value = "" };
}

fn looksLikeMapEntry(s: []const u8) bool {
    if (s.len > 0 and s[0] == '{') return false; // flow value, not a map entry
    const kv = splitKeyValue(s);
    return kv.key.len > 0 and kv.value.len != s.len; // a real "key:" was found
}
```

> Note: `parseValue` (flow maps/seqs, refs, scalars) is added in Step 5 — this step won't compile until then, so do Steps 3 and 5 together, then run the tests.

- [ ] **Step 4: Write failing tests for flow values and refs**

Append to the test section of `core/src/parser.zig`:
```zig
test "parse: nested map and block sequence of refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 114}
        \\  m_Layer: 0
    ;
    const doc = try parseOne(arena, src);
    const comps = model.findValue(doc.body.map, "m_Component").?;
    try testing.expectEqual(@as(usize, 2), comps.seq.len);
    const first = model.findValue(comps.seq[0].map, "component").?;
    try testing.expectEqual(@as(i64, 4), first.ref.file_id);
}

test "parse: ref with guid and type, and a non-ref flow map (vector)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &114
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abcdef0123456789, type: 3}
        \\  m_LocalPosition: {x: 1, y: 2, z: 3}
        \\  maxHp: 100
    ;
    const doc = try parseOne(arena, src);
    const script = model.findValue(doc.body.map, "m_Script").?;
    try testing.expectEqual(@as(i64, 11500000), script.ref.file_id);
    try testing.expectEqualStrings("abcdef0123456789", script.ref.guid.?);
    try testing.expectEqual(@as(i64, 3), script.ref.type_id.?);

    const pos = model.findValue(doc.body.map, "m_LocalPosition").?;
    // A flow map without fileID stays a .map, not a .ref.
    const x = model.findValue(pos.map, "x").?;
    try testing.expectEqualStrings("1", x.scalar);

    const hp = model.findValue(doc.body.map, "maxHp").?;
    try testing.expectEqualStrings("100", hp.scalar);
}

test "parse: multi-entry sequence map (modifications)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Renamed
        \\      objectReference: {fileID: 0}
    ;
    const doc = try parseOne(arena, src);
    const mod = model.findValue(doc.body.map, "m_Modification").?;
    const mods = model.findValue(mod.map, "m_Modifications").?;
    try testing.expectEqual(@as(usize, 1), mods.seq.len);
    const item = mods.seq[0];
    try testing.expectEqualStrings("m_Name", model.findValue(item.map, "propertyPath").?.scalar);
    try testing.expectEqualStrings("Renamed", model.findValue(item.map, "value").?.scalar);
    try testing.expectEqual(@as(i64, 7), model.findValue(item.map, "target").?.ref.file_id);
}

test "parse: quoted scalar and empty flow seq" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "Hello: World"
        \\  m_TagString: []
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqualStrings("Hello: World", model.findValue(doc.body.map, "m_Name").?.scalar);
    const tags = model.findValue(doc.body.map, "m_TagString").?;
    try testing.expectEqual(@as(usize, 0), tags.seq.len);
}
```

- [ ] **Step 5: Implement `parseValue` (flow maps/seqs, refs, scalars)**

Add to `core/src/parser.zig` (helpers section):
```zig
fn parseValue(arena: std.mem.Allocator, raw: []const u8) anyerror!*Node {
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return makeNode(arena, .{ .scalar = "" });
    if (s[0] == '{') return parseFlow(arena, s);
    if (s[0] == '[') return parseFlowSeq(arena, s);
    return makeNode(arena, .{ .scalar = unquote(s) });
}

/// Parse a flow mapping `{a: b, c: d}`. If it has a `fileID` key, return a Ref node.
fn parseFlow(arena: std.mem.Allocator, s: []const u8) anyerror!*Node {
    const inner = stripBrackets(s, '{', '}');
    var entries = std.ArrayList(Entry).init(arena);
    var it = splitTopLevel(inner);
    while (it.next()) |part| {
        const kv = splitKeyValue(part);
        if (kv.key.len == 0) continue;
        const value = try parseValue(arena, kv.value);
        try entries.append(.{ .key = kv.key, .value = value });
    }
    const es = try entries.toOwnedSlice();
    if (model.findValue(es, "fileID")) |fid_node| {
        return makeNode(arena, .{ .ref = .{
            .file_id = scalarToInt(i64, fid_node) orelse 0,
            .guid = if (model.findValue(es, "guid")) |g| g.scalar else null,
            .type_id = if (model.findValue(es, "type")) |t| scalarToInt(i64, t) else null,
        } });
    }
    return makeNode(arena, .{ .map = es });
}

fn parseFlowSeq(arena: std.mem.Allocator, s: []const u8) anyerror!*Node {
    const inner = std.mem.trim(u8, stripBrackets(s, '[', ']'), " ");
    var items = std.ArrayList(*Node).init(arena);
    if (inner.len != 0) {
        var it = splitTopLevel(inner);
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " ");
            if (t.len != 0) try items.append(try parseValue(arena, t));
        }
    }
    return makeNode(arena, .{ .seq = try items.toOwnedSlice() });
}

fn scalarToInt(comptime T: type, n: *const Node) ?T {
    return switch (n.*) {
        .scalar => |s| std.fmt.parseInt(T, std.mem.trim(u8, s, " "), 10) catch null,
        else => null,
    };
}

fn stripBrackets(s: []const u8, open: u8, close: u8) []const u8 {
    var t = std.mem.trim(u8, s, " ");
    if (t.len >= 1 and t[0] == open) t = t[1..];
    if (t.len >= 1 and t[t.len - 1] == close) t = t[0 .. t.len - 1];
    return t;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Iterator over comma-separated parts at brace/bracket depth 0.
const TopLevelIter = struct {
    s: []const u8,
    i: usize = 0,
    fn next(self: *TopLevelIter) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        var depth: usize = 0;
        const start = self.i;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c == '{' or c == '[') depth += 1;
            if (c == '}' or c == ']') {
                if (depth > 0) depth -= 1;
            }
            if (c == ',' and depth == 0) {
                const part = self.s[start..self.i];
                self.i += 1;
                return part;
            }
        }
        return self.s[start..self.i];
    }
};

fn splitTopLevel(s: []const u8) TopLevelIter {
    return .{ .s = s };
}
```

- [ ] **Step 6: Run all parser tests**

Run: `zig build test`
Expected: PASS (all 7 parser tests). Fix the implementation against any failing test until green.

- [ ] **Step 7: Re-export and commit**

Edit `core/src/root.zig`, add:
```zig
pub const parser = @import("parser.zig");
```
```bash
git add core/src/parser.zig core/src/root.zig
git commit -m "feat(core): add Unity-YAML subset parser (blocks, flow, refs)"
```

---

## Task 5: Diff engine (`diff.zig`) — match by fileID + field diff

Produces a **flat** per-document diff (one `ComponentDiff`-shaped record per document) plus the unresolved-guid set. The GameObject hierarchy is assembled in Task 6.

**Files:**
- Create: `core/src/diff.zig`
- Modify: `core/src/root.zig` (re-export `diff`)

**Interfaces:**
- Consumes: `parser.parse`, `model.Document`, `model.Node`, `model.ComponentDiff`, `model.FieldDiff`, `model.Status`, `classid.typeName`.
- Produces:
  - `DocDiff = struct { file_id: i64, class_id: u32, type_name: []const u8, script_guid: ?[]const u8, status: model.Status, fields: []model.FieldDiff }`
  - `FlatDiff = struct { docs: []DocDiff, unresolved_guids: [][]const u8, before: []model.Document, after: []model.Document }`
  - `pub fn compute(arena, before_src: []const u8, after_src: []const u8) !FlatDiff`

- [ ] **Step 1: Write failing tests**

Create `core/src/diff.zig`:
```zig
const std = @import("std");
const model = @import("model.zig");
const testing = std.testing;

fn findDoc(fd: FlatDiff, file_id: i64) ?DocDiff {
    for (fd.docs) |d| if (d.file_id == file_id) return d;
    return null;
}

test "diff: modified scalar field is detected old->new" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc, type: 3}
        \\  maxHp: 100
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc, type: 3}
        \\  maxHp: 150
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 5).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqualStrings("abc", d.script_guid.?);
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    try testing.expectEqualStrings("maxHp", d.fields[0].path);
    try testing.expectEqual(model.Status.modified, d.fields[0].status);
    try testing.expectEqualStrings("100", d.fields[0].before.?.scalar);
    try testing.expectEqualStrings("150", d.fields[0].after.?.scalar);
}

test "diff: added and removed documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: B
    ;
    const fd = try compute(arena, before, after);
    try testing.expectEqual(model.Status.unchanged, findDoc(fd, 1).?.status);
    try testing.expectEqual(model.Status.added, findDoc(fd, 2).?.status);

    const fd2 = try compute(arena, after, before);
    try testing.expectEqual(model.Status.removed, findDoc(fd2, 2).?.status);
}

test "diff: nested field path and added field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 5, z: 0}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.modified, d.status);
    // Expect one modified leaf (m_LocalPosition.y) plus added subtree (m_LocalScale.*).
    var saw_y = false;
    var saw_added_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "m_LocalPosition.y")) {
            saw_y = true;
            try testing.expectEqual(model.Status.modified, f.status);
            try testing.expectEqualStrings("0", f.before.?.scalar);
            try testing.expectEqualStrings("5", f.after.?.scalar);
        }
        if (std.mem.startsWith(u8, f.path, "m_LocalScale")) {
            saw_added_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
        }
    }
    try testing.expect(saw_y and saw_added_scale);
}

test "diff: unresolved guids collected from external refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: aaaa, type: 3}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbbb, type: 3}
    ;
    const fd = try compute(arena, before, after);
    // Both aaaa and bbbb are external guids referenced; both should appear.
    var saw_a = false;
    var saw_b = false;
    for (fd.unresolved_guids) |g| {
        if (std.mem.eql(u8, g, "aaaa")) saw_a = true;
        if (std.mem.eql(u8, g, "bbbb")) saw_b = true;
    }
    try testing.expect(saw_a and saw_b);
}
```

- [ ] **Step 2: Run — confirm failure**

Run: `zig build test`
Expected: FAIL — `use of undeclared identifier 'compute'` / `'FlatDiff'`.

- [ ] **Step 3: Implement the diff engine**

Add above the tests in `core/src/diff.zig`:
```zig
const parser = @import("parser.zig");
const classid = @import("classid.zig");
const Node = model.Node;
const Status = model.Status;
const FieldDiff = model.FieldDiff;

pub const DocDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
};

pub const FlatDiff = struct {
    docs: []DocDiff,
    unresolved_guids: [][]const u8,
    before: []model.Document,
    after: []model.Document,
};

fn findDocById(docs: []model.Document, file_id: i64) ?*model.Document {
    for (docs) |*d| if (d.file_id == file_id) return d;
    return null;
}

fn scriptGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_Script") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

fn resolvedTypeName(arena: std.mem.Allocator, doc: *const model.Document) ![]const u8 {
    if (classid.typeName(doc.class_id)) |n| return n;
    // Unknown classID: fall back to the document's own top key.
    _ = arena;
    return doc.type_name;
}

pub fn compute(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !FlatDiff {
    const before = try parser.parse(arena, before_src);
    const after = try parser.parse(arena, after_src);

    var docs = std.ArrayList(DocDiff).init(arena);
    var guids = GuidSet.init(arena);

    // Walk the union of file_ids: iterate `after` first (preserves after order),
    // then `before`-only documents.
    for (after) |*ad| {
        try collectGuids(&guids, ad.body);
        const bd = findDocById(before, ad.file_id);
        if (bd) |b| {
            try collectGuids(&guids, b.body);
            var fields = std.ArrayList(FieldDiff).init(arena);
            try diffNode(arena, &fields, "", b.body, ad.body);
            try docs.append(.{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(arena, ad),
                .script_guid = scriptGuid(ad),
                .status = if (fields.items.len == 0) .unchanged else .modified,
                .fields = try fields.toOwnedSlice(),
            });
        } else {
            try docs.append(.{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(arena, ad),
                .script_guid = scriptGuid(ad),
                .status = .added,
                .fields = &[_]FieldDiff{},
            });
        }
    }
    for (before) |*bd| {
        if (findDocById(after, bd.file_id) != null) continue;
        try collectGuids(&guids, bd.body);
        try docs.append(.{
            .file_id = bd.file_id,
            .class_id = bd.class_id,
            .type_name = try resolvedTypeName(arena, bd),
            .script_guid = scriptGuid(bd),
            .status = .removed,
            .fields = &[_]FieldDiff{},
        });
    }

    return .{
        .docs = try docs.toOwnedSlice(),
        .unresolved_guids = try guids.toSlice(),
        .before = before,
        .after = after,
    };
}

/// Recursive field diff. `prefix` is the dotted/indexed path to `a`/`b`.
fn diffNode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: *const Node,
    b: *const Node,
) anyerror!void {
    // Same kind?
    if (std.meta.activeTag(a.*) == .map and std.meta.activeTag(b.*) == .map) {
        try diffMap(arena, out, prefix, a.map, b.map);
        return;
    }
    if (std.meta.activeTag(a.*) == .seq and std.meta.activeTag(b.*) == .seq) {
        try diffSeq(arena, out, prefix, a.seq, b.seq);
        return;
    }
    // Leaf (scalar/ref) or kind change.
    if (!Node.eql(a, b)) {
        try out.append(.{ .path = prefix, .status = .modified, .before = a, .after = b });
    }
}

fn diffMap(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: []model.Entry,
    b: []model.Entry,
) anyerror!void {
    // keys in a: modified/removed/recurse
    for (a) |ea| {
        const path = try joinKey(arena, prefix, ea.key);
        if (model.findValue(b, ea.key)) |bv| {
            try diffNode(arena, out, path, ea.value, bv);
        } else {
            try out.append(.{ .path = path, .status = .removed, .before = ea.value, .after = null });
        }
    }
    // keys only in b: added
    for (b) |eb| {
        if (model.findValue(a, eb.key) == null) {
            const path = try joinKey(arena, prefix, eb.key);
            try out.append(.{ .path = path, .status = .added, .before = null, .after = eb.value });
        }
    }
}

fn diffSeq(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: []*Node,
    b: []*Node,
) anyerror!void {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try diffNode(arena, out, path, a[i], b[i]);
    }
    while (i < a.len) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try out.append(.{ .path = path, .status = .removed, .before = a[i], .after = null });
    }
    while (i < b.len) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try out.append(.{ .path = path, .status = .added, .before = null, .after = b[i] });
    }
}

fn joinKey(arena: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]const u8 {
    if (prefix.len == 0) return key;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
}

// ---- guid collection ----

const GuidSet = struct {
    map: std.StringHashMap(void),
    order: std.ArrayList([]const u8),

    fn init(arena: std.mem.Allocator) GuidSet {
        return .{ .map = std.StringHashMap(void).init(arena), .order = std.ArrayList([]const u8).init(arena) };
    }
    fn add(self: *GuidSet, guid: []const u8) !void {
        if (self.map.contains(guid)) return;
        try self.map.put(guid, {});
        try self.order.append(guid);
    }
    fn toSlice(self: *GuidSet) ![][]const u8 {
        return self.order.toOwnedSlice();
    }
};

fn collectGuids(set: *GuidSet, node: *const Node) anyerror!void {
    switch (node.*) {
        .ref => |r| if (r.guid) |g| try set.add(g),
        .map => |entries| for (entries) |e| try collectGuids(set, e.value),
        .seq => |items| for (items) |it| try collectGuids(set, it),
        .scalar => {},
    }
}
```

- [ ] **Step 4: Run the diff tests**

Run: `zig build test`
Expected: PASS (all 4 diff tests + prior tests). Fix until green.

- [ ] **Step 5: Re-export and commit**

Edit `core/src/root.zig`, add:
```zig
pub const diff = @import("diff.zig");
```
```bash
git add core/src/diff.zig core/src/root.zig
git commit -m "feat(core): add fileID-matched recursive field diff engine"
```

---

## Task 6: GameObject hierarchy reconstruction (`tree.zig`)

Turns the flat `DocDiff` list into the `DiffResult` tree: components grouped under their GameObject, GameObjects nested by Transform parentage, unchanged-but-empty nodes collapsed.

**Files:**
- Create: `core/src/tree.zig`
- Modify: `core/src/root.zig` (re-export `tree`, add `diffBytes` convenience)

**Interfaces:**
- Consumes: `diff.FlatDiff`, `diff.DocDiff`, `model.Document`, `model.DiffResult`, `model.ObjectDiff`, `model.ComponentDiff`, `classid.typeName`.
- Produces:
  - `pub fn build(arena, fd: diff.FlatDiff) !model.DiffResult`
  - (in `root.zig`) `pub fn diffBytes(arena, before_src, after_src) !model.DiffResult`

- [ ] **Step 1: Write failing tests**

Create `core/src/tree.zig`:
```zig
const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

fn findRoot(res: model.DiffResult, file_id: i64) ?model.ObjectDiff {
    for (res.roots) |o| if (o.file_id == file_id) return o;
    return null;
}

test "tree: GameObject groups its components; modified component bubbles up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 100
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 250
    ;
    const res = try root.diffBytes(arena, before, after);
    const go = findRoot(res, 1).?;
    try testing.expectEqualStrings("Player", go.name);
    // Player itself is structurally unchanged but kept because a child component changed.
    try testing.expectEqual(model.Status.unchanged, go.status);
    // Components: the Transform (unchanged, no fields) is collapsed; MonoBehaviour kept.
    var saw_modified_mb = false;
    for (go.components) |c| {
        if (c.file_id == 5) {
            saw_modified_mb = true;
            try testing.expectEqual(model.Status.modified, c.status);
            try testing.expectEqualStrings("MonoBehaviour", c.type_name);
        }
    }
    try testing.expect(saw_modified_mb);
}

test "tree: child GameObject nests under parent via Transform m_Father" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src_before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Child
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    // after: child renamed
    const src_after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: ChildRenamed
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    const res = try root.diffBytes(arena, src_before, src_after);
    const parent = findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 1), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
}

test "tree: ScriptableObject .asset becomes a loose component" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    ;
    const after =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}
```

- [ ] **Step 2: Add `diffBytes` to `root.zig` and run to confirm failure**

Edit `core/src/root.zig`:
```zig
pub const tree = @import("tree.zig");

pub fn diffBytes(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !model.DiffResult {
    const fd = try diff.compute(arena, before_src, after_src);
    return tree.build(arena, fd);
}
```
Run: `zig build test`
Expected: FAIL — `tree.build` undeclared.

- [ ] **Step 3: Implement hierarchy reconstruction**

Add above the tests in `core/src/tree.zig`:
```zig
const diffmod = @import("diff.zig");

const ComponentDiff = model.ComponentDiff;
const ObjectDiff = model.ObjectDiff;
const Status = model.Status;

/// Index helpers over the parsed documents (use the union of before+after).
const Index = struct {
    arena: std.mem.Allocator,
    fd: diffmod.FlatDiff,
    // file_id -> DocDiff (status + fields), for quick component construction.
    diff_by_id: std.AutoHashMap(i64, diffmod.DocDiff),
    // file_id -> *Document for the *structural* (after-preferred) version.
    doc_by_id: std.AutoHashMap(i64, *model.Document),

    fn structuralDoc(self: *Index, file_id: i64) ?*model.Document {
        return self.doc_by_id.get(file_id);
    }
};

fn refFileId(node: ?*model.Node) ?i64 {
    const n = node orelse return null;
    return switch (n.*) {
        .ref => |r| r.file_id,
        else => null,
    };
}

fn gameObjectIdOfComponent(doc: *model.Document) ?i64 {
    return refFileId(model.findValue(doc.body.map, "m_GameObject"));
}

fn transformOf(idx: *Index, go_id: i64) ?*model.Document {
    // The GameObject lists its components; find the one whose doc is a Transform/RectTransform.
    const go = idx.structuralDoc(go_id) orelse return null;
    const comps = model.findValue(go.body.map, "m_Component") orelse return null;
    if (comps.* != .seq) return null;
    for (comps.seq) |item| {
        const cref = if (item.* == .map) model.findValue(item.map, "component") else null;
        const cid = refFileId(cref) orelse continue;
        const cdoc = idx.structuralDoc(cid) orelse continue;
        if (cdoc.class_id == 4 or cdoc.class_id == 224) return cdoc;
    }
    return null;
}

fn parentGoId(idx: *Index, go_id: i64) ?i64 {
    const tr = transformOf(idx, go_id) orelse return null;
    const father_id = refFileId(model.findValue(tr.body.map, "m_Father")) orelse return null;
    if (father_id == 0) return null;
    const father_tr = idx.structuralDoc(father_id) orelse return null;
    return gameObjectIdOfComponent(father_tr);
}

fn goName(idx: *Index, go_id: i64) []const u8 {
    const go = idx.structuralDoc(go_id) orelse return "";
    const n = model.findValue(go.body.map, "m_Name") orelse return "";
    return switch (n.*) {
        .scalar => |s| s,
        else => "",
    };
}

fn makeComponent(dd: diffmod.DocDiff) ComponentDiff {
    return .{
        .file_id = dd.file_id,
        .class_id = dd.class_id,
        .type_name = dd.type_name,
        .script_guid = dd.script_guid,
        .status = dd.status,
        .fields = dd.fields,
    };
}

pub fn build(arena: std.mem.Allocator, fd: diffmod.FlatDiff) !model.DiffResult {
    var idx = Index{
        .arena = arena,
        .fd = fd,
        .diff_by_id = std.AutoHashMap(i64, diffmod.DocDiff).init(arena),
        .doc_by_id = std.AutoHashMap(i64, *model.Document).init(arena),
    };
    for (fd.docs) |d| try idx.diff_by_id.put(d.file_id, d);
    // Structural docs: prefer after, fall back to before (for removed objects).
    for (fd.before) |*d| try idx.doc_by_id.put(d.file_id, d);
    for (fd.after) |*d| try idx.doc_by_id.put(d.file_id, d); // overwrites -> after wins

    // Partition documents: GameObjects, their components, and loose docs.
    var go_ids = std.ArrayList(i64).init(arena);
    // components grouped by owning GameObject id
    var comps_by_go = std.AutoHashMap(i64, std.ArrayList(ComponentDiff)).init(arena);
    var loose = std.ArrayList(ComponentDiff).init(arena);

    for (fd.docs) |d| {
        if (d.class_id == 1) {
            try go_ids.append(d.file_id);
            continue;
        }
        const owner = blk: {
            const doc = idx.structuralDoc(d.file_id) orelse break :blk null;
            break :blk gameObjectIdOfComponent(doc);
        };
        if (owner) |go_id| {
            const gop = try comps_by_go.getOrPut(go_id);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(ComponentDiff).init(arena);
            // Collapse unchanged components with no fields.
            if (d.status != .unchanged) try gop.value_ptr.append(makeComponent(d));
        } else {
            // No owning GameObject -> loose (e.g. ScriptableObject, or PrefabInstance).
            if (d.status != .unchanged) try loose.append(makeComponent(d));
        }
    }

    // Build ObjectDiff per GameObject (without children yet).
    var obj_by_id = std.AutoHashMap(i64, ObjectDiff).init(arena);
    for (go_ids.items) |go_id| {
        const gd = idx.diff_by_id.get(go_id).?;
        const comps: []ComponentDiff = if (comps_by_go.get(go_id)) |list| list.items else &[_]ComponentDiff{};
        try obj_by_id.put(go_id, .{
            .file_id = go_id,
            .name = goName(&idx, go_id),
            .status = gd.status,
            .components = comps,
            .children = &[_]ObjectDiff{},
        });
    }

    // Assemble parent/child links.
    var children_of = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    var roots_ids = std.ArrayList(i64).init(arena);
    for (go_ids.items) |go_id| {
        if (parentGoId(&idx, go_id)) |pid| {
            if (obj_by_id.contains(pid)) {
                const e = try children_of.getOrPut(pid);
                if (!e.found_existing) e.value_ptr.* = std.ArrayList(i64).init(arena);
                try e.value_ptr.append(go_id);
                continue;
            }
        }
        try roots_ids.append(go_id);
    }

    // Recursively materialize, pruning unchanged subtrees with no changed descendants.
    var roots = std.ArrayList(ObjectDiff).init(arena);
    for (roots_ids.items) |rid| {
        if (try materialize(arena, &obj_by_id, &children_of, rid)) |node| {
            try roots.append(node);
        }
    }

    return .{
        .roots = try roots.toOwnedSlice(),
        .loose = try loose.toOwnedSlice(),
        .unresolved_guids = fd.unresolved_guids,
    };
}

/// Build the ObjectDiff for `go_id` with its kept children. Returns null if the
/// node and its entire subtree are unchanged with no kept components.
fn materialize(
    arena: std.mem.Allocator,
    obj_by_id: *std.AutoHashMap(i64, ObjectDiff),
    children_of: *std.AutoHashMap(i64, std.ArrayList(i64)),
    go_id: i64,
) anyerror!?ObjectDiff {
    var self = obj_by_id.get(go_id).?;
    var kept_children = std.ArrayList(ObjectDiff).init(arena);
    if (children_of.get(go_id)) |kids| {
        for (kids.items) |cid| {
            if (try materialize(arena, obj_by_id, children_of, cid)) |child| {
                try kept_children.append(child);
            }
        }
    }
    self.children = try kept_children.toOwnedSlice();
    const has_change = self.status != .unchanged or self.components.len != 0 or self.children.len != 0;
    if (!has_change) return null;
    return self;
}
```

- [ ] **Step 4: Run the tree tests**

Run: `zig build test`
Expected: PASS. Fix until green. Pay attention to the "loose component" and "child nesting" cases — they exercise the index lookups.

- [ ] **Step 5: Commit**
```bash
git add core/src/tree.zig core/src/root.zig
git commit -m "feat(core): reconstruct GameObject hierarchy into DiffResult tree"
```

---

## Task 7: JSON serialization (`json.zig`) — `prefablens.diff.v1`

**Files:**
- Create: `core/src/json.zig`
- Modify: `core/src/root.zig` (re-export `json`, add `diffToJson`)

**Interfaces:**
- Consumes: `model.DiffResult`, `model.ObjectDiff`, `model.ComponentDiff`, `model.FieldDiff`, `model.Node`, `model.Status`.
- Produces:
  - `pub const Resolver = std.StringHashMap([]const u8);`
  - `pub fn serialize(arena, res: model.DiffResult, resolved: ?*const Resolver) ![]u8` — bytes of `prefablens.diff.v1` JSON (see Data Contract).
  - (in `root.zig`) `pub fn diffToJson(arena, before_src, after_src) ![]u8` (calls `serialize(.., null)`).

- [ ] **Step 1: Write the failing golden test**

Create `core/src/json.zig`:
```zig
const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

test "json: modified loose component matches golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    ;
    const after =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    ;
    const out = try root.diffToJson(arena, before, after);
    const golden =
        \\{"schema":"prefablens.diff.v1","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","status":"modified","fields":[{"path":"volume","status":"modified","before":"0.5","after":"0.8"}]}]}
    ;
    try testing.expectEqualStrings(golden, out);
}

test "json: fileId is a string, ref value serialized as object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 100}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 200}
    ;
    const out = try root.diffToJson(arena, before, after);
    try testing.expect(std.mem.indexOf(u8, out, "\"fileId\":\"5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"after\":{\"ref\":{\"fileId\":\"200\",\"guid\":null,\"type\":null}}") != null);
}

test "json: string escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: a
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "a\"b"
    ;
    const out = try root.diffToJson(arena, before, after);
    // The quote inside the value must be escaped in JSON output.
    try testing.expect(std.mem.indexOf(u8, out, "a\\\"b") != null);
}
```

- [ ] **Step 2: Add re-export + `diffToJson` and run to confirm failure**

Edit `core/src/root.zig`:
```zig
pub const json = @import("json.zig");

pub fn diffToJson(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) ![]u8 {
    const res = try diffBytes(arena, before_src, after_src);
    return json.serialize(arena, res, null);
}
```
Run: `zig build test`
Expected: FAIL — `json.serialize` undeclared.

- [ ] **Step 3: Implement the JSON writer**

Add above the tests in `core/src/json.zig`:
```zig
const Node = model.Node;
const Status = model.Status;

pub const Resolver = std.StringHashMap([]const u8);

pub fn serialize(arena: std.mem.Allocator, res: model.DiffResult, resolved: ?*const Resolver) ![]u8 {
    var buf = std.ArrayList(u8).init(arena);
    const w = buf.writer();

    try w.writeAll("{\"schema\":\"prefablens.diff.v1\"");

    try w.writeAll(",\"unresolvedGuids\":[");
    for (res.unresolved_guids, 0..) |g, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, g);
    }
    try w.writeByte(']');

    if (resolved) |r| {
        try w.writeAll(",\"resolved\":{");
        var it = r.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonString(w, e.key_ptr.*);
            try w.writeByte(':');
            try writeJsonString(w, e.value_ptr.*);
        }
        try w.writeByte('}');
    }

    try w.writeAll(",\"roots\":[");
    for (res.roots, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, o, resolved);
    }
    try w.writeAll("],\"loose\":[");
    for (res.loose, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

fn writeObject(w: anytype, o: model.ObjectDiff, resolved: ?*const Resolver) !void {
    try w.writeAll("{\"kind\":\"gameObject\",\"fileId\":");
    try writeI64String(w, o.file_id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, o.name);
    try w.writeAll(",\"status\":");
    try writeStatus(w, o.status);
    try w.writeAll(",\"components\":[");
    for (o.components, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("],\"children\":[");
    for (o.children, 0..) |child, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, child, resolved);
    }
    try w.writeAll("]}");
}

fn writeComponent(w: anytype, c: model.ComponentDiff, resolved: ?*const Resolver) !void {
    try w.writeAll("{\"kind\":\"component\",\"fileId\":");
    try writeI64String(w, c.file_id);
    try w.print(",\"classId\":{d},\"typeName\":", .{c.class_id});
    try writeJsonString(w, c.type_name);
    try w.writeAll(",\"scriptGuid\":");
    if (c.script_guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
    if (resolved) |r| {
        if (c.script_guid) |g| {
            if (r.get(g)) |path| {
                try w.writeAll(",\"scriptName\":");
                try writeJsonString(w, path);
            }
        }
    }
    try w.writeAll(",\"status\":");
    try writeStatus(w, c.status);
    try w.writeAll(",\"fields\":[");
    for (c.fields, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try writeField(w, f);
    }
    try w.writeAll("]}");
}

fn writeField(w: anytype, f: model.FieldDiff) !void {
    try w.writeAll("{\"path\":");
    try writeJsonString(w, f.path);
    try w.writeAll(",\"status\":");
    try writeStatus(w, f.status);
    try w.writeAll(",\"before\":");
    try writeValue(w, f.before);
    try w.writeAll(",\"after\":");
    try writeValue(w, f.after);
    try w.writeByte('}');
}

fn writeValue(w: anytype, node: ?*const Node) !void {
    const n = node orelse {
        try w.writeAll("null");
        return;
    };
    switch (n.*) {
        .scalar => |s| try writeJsonString(w, s),
        .ref => |r| {
            try w.writeAll("{\"ref\":{\"fileId\":");
            try writeI64String(w, r.file_id);
            try w.writeAll(",\"guid\":");
            if (r.guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
            try w.writeAll(",\"type\":");
            if (r.type_id) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
            try w.writeAll("}}");
        },
        // Maps/seqs as field leaves are uncommon (they recurse), but render compactly.
        .map => try w.writeAll("\"<map>\""),
        .seq => try w.writeAll("\"<seq>\""),
    }
}

fn writeStatus(w: anytype, s: Status) !void {
    const text = switch (s) {
        .added => "\"added\"",
        .removed => "\"removed\"",
        .modified => "\"modified\"",
        .unchanged => "\"unchanged\"",
    };
    try w.writeAll(text);
}

fn writeI64String(w: anytype, v: i64) !void {
    try w.print("\"{d}\"", .{v});
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
```

> Note on the escaping test: the fixture value `"a\"b"` in the Zig multiline string is the literal characters `a`, `"`, `b` once parsed by the YAML parser's `unquote` (the surrounding quotes are stripped, the inner `\"` stays as backslash-quote in the raw slice). JSON output must contain `a\"b` (backslash + quote). If the assertion mismatches, inspect the raw scalar the parser produced and adjust `unquote` only if it is wrong — the JSON escaper is the component under test here.

- [ ] **Step 4: Run the golden tests**

Run: `zig build test`
Expected: PASS. The first test is an exact-string golden — if it mismatches, print `out` (`std.debug.print("{s}\n", .{out});`) and reconcile byte-for-byte against the Data Contract ordering. Fix the serializer (not the contract).

- [ ] **Step 5: Commit**
```bash
git add core/src/json.zig core/src/root.zig
git commit -m "feat(core): serialize DiffResult to prefablens.diff.v1 JSON"
```

---

## Task 8: CLI core path — arg parsing, file input, `--json` (`main.zig`)

Gives the CLI a testable `run()` entrypoint and end-to-end validation of the core through the binary (spec §7: CLI is Phase 1's primary test harness).

**Files:**
- Modify: `cli/src/main.zig`

**Interfaces:**
- Consumes: `core.diffToJson`.
- Produces:
  - `pub const Options = struct { before: []const u8, after: []const u8, format: Format };` with `Format = enum { tree, json, html };`
  - `pub fn parseArgs(args: []const []const u8) !Options`
  - `pub fn run(arena, args: []const []const u8, stdout: anytype) !u8` — returns process exit code.
  - `main()` wires real argv + stdout to `run`.

- [ ] **Step 1: Write failing tests for arg parsing and `--json` end-to-end**

Replace `cli/src/main.zig` test block (and add the prod stubs are added in Step 3). First, the tests:
```zig
const std = @import("std");
const core = @import("core");
const testing = std.testing;

test "parseArgs: two paths default to tree format" {
    const args = [_][]const u8{ "a.prefab", "b.prefab" };
    const opt = try parseArgs(&args);
    try testing.expectEqualStrings("a.prefab", opt.before);
    try testing.expectEqualStrings("b.prefab", opt.after);
    try testing.expectEqual(Format.tree, opt.format);
}

test "parseArgs: --json sets json format" {
    const args = [_][]const u8{ "--json", "a.prefab", "b.prefab" };
    const opt = try parseArgs(&args);
    try testing.expectEqual(Format.json, opt.format);
}

test "run: --json with two real files prints core JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Write fixtures into a temp dir.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(.{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realpathAlloc(arena, "before.asset");
    const after_path = try tmp.dir.realpathAlloc(arena, "after.asset");

    var out = std.ArrayList(u8).init(arena);
    const code = try run(arena, &.{ "--json", before_path, after_path }, out.writer());
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"schema\":\"prefablens.diff.v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"after\":\"0.8\"") != null);
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `zig build test`
Expected: FAIL — `parseArgs` / `Format` / `run` undeclared.

- [ ] **Step 3: Implement arg parsing, file reading, and `run`**

Add above the tests in `cli/src/main.zig`:
```zig
pub const Format = enum { tree, json, html };

pub const Options = struct {
    before: []const u8,
    after: []const u8,
    format: Format = .tree,
    project_root: ?[]const u8 = null, // for .meta resolution (Task 9)
};

pub const ArgError = error{ MissingOperands, UnknownFlag };

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var format: Format = .tree;
    var project_root: ?[]const u8 = null;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, a, "--html")) {
            format = .html;
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return ArgError.MissingOperands;
            project_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return ArgError.UnknownFlag;
        } else {
            if (pos_count >= 2) return ArgError.UnknownFlag;
            positionals[pos_count] = a;
            pos_count += 1;
        }
    }
    if (pos_count != 2) return ArgError.MissingOperands;
    return .{
        .before = positionals[0].?,
        .after = positionals[1].?,
        .format = format,
        .project_root = project_root,
    };
}

const max_file_bytes = 64 * 1024 * 1024; // 64 MB guard

fn readFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(arena, path, max_file_bytes);
}

pub fn run(arena: std.mem.Allocator, args: []const []const u8, stdout: anytype) !u8 {
    const opt = parseArgs(args) catch |err| {
        switch (err) {
            ArgError.MissingOperands => try stdout.writeAll("usage: prefablens [--json|--html] [--project DIR] <before> <after>\n"),
            ArgError.UnknownFlag => try stdout.writeAll("error: unknown flag\n"),
        }
        return 2;
    };

    const before = try readFile(arena, opt.before);
    const after = try readFile(arena, opt.after);

    switch (opt.format) {
        .json => {
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        .tree => {
            // Implemented in Task 11; for now, emit JSON as a placeholder path is NOT allowed.
            // Task 11 replaces this branch. Until then, fall through to JSON so the binary works.
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        .html => {
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
    }
    return 0;
}

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try std.process.argsAlloc(arena);
    // argv[0] is the program name; pass the rest.
    const args = argv[1..];

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const code = try run(arena, args, stdout_buf.writer());
    try stdout_buf.flush();
    return code;
}
```

> The `.tree` and `.html` branches intentionally fall back to JSON output for now; Tasks 11 and 12 replace them. This keeps the binary runnable and every test green at each step. (`main` now returns `u8`; Zig allows `pub fn main() !u8`.)

- [ ] **Step 4: Run the CLI tests**

Run: `zig build test`
Expected: PASS.

Manually verify end-to-end:
```bash
printf -- '--- !u!114 &1\nMonoBehaviour:\n  hp: 1\n' > /tmp/a.asset
printf -- '--- !u!114 &1\nMonoBehaviour:\n  hp: 2\n' > /tmp/b.asset
zig build run -- --json /tmp/a.asset /tmp/b.asset
```
Expected: a single line of `prefablens.diff.v1` JSON containing `"before":"1","after":"2"`.

- [ ] **Step 5: Commit**
```bash
git add cli/src/main.zig
git commit -m "feat(cli): add testable run() with arg parsing and --json output"
```

---

## Task 9: `.meta` guid resolver (`resolve.zig`)

Builds a `guid → asset path` index by scanning a Unity project for `*.meta` files, so the CLI can show real names instead of opaque guids (spec §4.3 CLI row).

**Files:**
- Create: `cli/src/resolve.zig`
- Modify: `cli/src/main.zig` (wire resolver into `--json` when `--project` given; import the test root)

**Interfaces:**
- Consumes: filesystem (`std.fs`).
- Produces:
  - `pub const Index = std.StringHashMap([]const u8); // guid -> path`
  - `pub fn buildIndex(arena, project_root: []const u8) !Index` — recursively scans `project_root` for `*.meta`, parses the `guid:` line, maps guid → the asset path (the `.meta` path minus the `.meta` suffix, relative to project_root).

- [ ] **Step 1: Write the failing test**

Create `cli/src/resolve.zig`:
```zig
const std = @import("std");
const testing = std.testing;

test "buildIndex maps guid to asset path from .meta files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("Assets/Scripts");
    try tmp.dir.writeFile(.{ .sub_path = "Assets/Scripts/Player.cs", .data = "// code" });
    try tmp.dir.writeFile(.{ .sub_path = "Assets/Scripts/Player.cs.meta", .data =
        \\fileFormatVersion: 2
        \\guid: 1234567890abcdef1234567890abcdef
        \\MonoImporter:
        \\  serializedVersion: 2
    });

    const root = try tmp.dir.realpathAlloc(arena, ".");
    var index = try buildIndex(arena, root);
    const path = index.get("1234567890abcdef1234567890abcdef").?;
    try testing.expect(std.mem.endsWith(u8, path, "Assets/Scripts/Player.cs"));
}
```

- [ ] **Step 2: Run to confirm failure**

Add a temporary import so the test root sees this file. Edit `cli/src/main.zig`, add near the top imports:
```zig
pub const resolve = @import("resolve.zig");

test {
    std.testing.refAllDecls(@This());
    _ = resolve;
}
```
Run: `zig build test`
Expected: FAIL — `buildIndex` undeclared.

- [ ] **Step 3: Implement the recursive `.meta` scan**

Add above the test in `cli/src/resolve.zig`:
```zig
pub const Index = std.StringHashMap([]const u8);

pub fn buildIndex(arena: std.mem.Allocator, project_root: []const u8) !Index {
    var index = Index.init(arena);
    var dir = try std.fs.cwd().openDir(project_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".meta")) continue;

        const meta_bytes = dir.readFileAlloc(arena, entry.path, 1 * 1024 * 1024) catch continue;
        const guid = parseGuid(meta_bytes) orelse continue;

        // Asset path = the .meta path without the trailing ".meta", made absolute.
        const asset_rel = entry.path[0 .. entry.path.len - ".meta".len];
        const asset_abs = try std.fs.path.join(arena, &.{ project_root, asset_rel });
        // Store an owned copy of the guid key (slice into meta_bytes is fine since arena-lived).
        try index.put(try arena.dupe(u8, guid), asset_abs);
    }
    return index;
}

fn parseGuid(meta: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, meta, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, trimmed, "guid:")) {
            return std.mem.trim(u8, trimmed["guid:".len..], " \r");
        }
    }
    return null;
}
```

- [ ] **Step 4: Run the resolver test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Wire the resolver into `--json` output**

In `cli/src/main.zig`, change the `.json` branch of `run` to use the resolver when `--project` was passed. Replace the `.json` branch with:
```zig
        .json => {
            const res = try core.diffBytes(arena, before, after);
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                const built = try resolve.buildIndex(arena, proj);
                idx = built; // Index and Resolver are both StringHashMap([]const u8)
                resolver_ptr = &idx;
            }
            const out = try core.json.serialize(arena, res, resolver_ptr);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
```
> `resolve.Index` and `core.json.Resolver` are the same type (`std.StringHashMap([]const u8)`), so the built index is passed directly.

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add cli/src/resolve.zig cli/src/main.zig
git commit -m "feat(cli): resolve guids to asset paths via .meta project scan"
```

---

## Task 10: Git ref input (`input.zig`)

Lets the CLI diff against git revisions (spec §6.1): `prefablens HEAD~1 HEAD <path>` style, `--staged`, and working-tree comparison.

**Files:**
- Create: `cli/src/input.zig`
- Modify: `cli/src/main.zig` (recognize git-ref mode)

**Interfaces:**
- Consumes: `std.process.Child` (runs `git`).
- Produces:
  - `pub fn showAtRef(arena, repo_dir: []const u8, ref: []const u8, path: []const u8) ![]u8` — returns the file contents at `<ref>:<path>` (via `git show`), or `&[_]u8{}` if the file does not exist at that ref (added/deleted side).

- [ ] **Step 1: Write the failing integration test**

Create `cli/src/input.zig`:
```zig
const std = @import("std");
const testing = std.testing;

fn git(arena: std.mem.Allocator, dir: []const u8, argv: []const []const u8) !void {
    var full = std.ArrayList([]const u8).init(arena);
    try full.append("git");
    try full.appendSlice(argv);
    const res = try std.process.Child.run(.{ .allocator = arena, .argv = full.items, .cwd = dir });
    if (res.term != .Exited or res.term.Exited != 0) return error.GitFailed;
}

test "showAtRef returns file contents at a commit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(arena, ".");

    try git(arena, dir, &.{ "init", "-q" });
    try git(arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(arena, dir, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(.{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try git(arena, dir, &.{ "add", "Foo.prefab" });
    try git(arena, dir, &.{ "commit", "-q", "-m", "first" });

    const content = try showAtRef(arena, dir, "HEAD", "Foo.prefab");
    try testing.expectEqualStrings("v1\n", content);

    // A path absent at the ref yields empty bytes, not an error.
    const missing = try showAtRef(arena, dir, "HEAD", "Nope.prefab");
    try testing.expectEqual(@as(usize, 0), missing.len);
}
```

- [ ] **Step 2: Wire the import and run to confirm failure**

Edit `cli/src/main.zig`, add to imports + the `test {}` block:
```zig
pub const input = @import("input.zig");
```
And inside the existing `test { ... }` block add `_ = input;`.

Run: `zig build test`
Expected: FAIL — `showAtRef` undeclared.

- [ ] **Step 3: Implement `showAtRef`**

Add above the test in `cli/src/input.zig`:
```zig
pub fn showAtRef(arena: std.mem.Allocator, repo_dir: []const u8, ref: []const u8, path: []const u8) ![]u8 {
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, path });
    const res = try std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "git", "show", spec },
        .cwd = repo_dir,
        .max_output_bytes = 256 * 1024 * 1024,
    });
    switch (res.term) {
        .Exited => |c| {
            if (c == 0) return res.stdout;
            // Non-zero: path absent at ref (added/deleted side) -> empty.
            return &[_]u8{};
        },
        else => return error.GitFailed,
    }
}
```

- [ ] **Step 4: Run the integration test**

Run: `zig build test`
Expected: PASS (requires `git` on PATH — it is, per environment).

- [ ] **Step 5: Add git-ref mode to the CLI**

In `cli/src/main.zig`, extend the model so two refs + a path can be supplied. Add a `--git` mode: `prefablens --git <beforeRef> <afterRef> <path>`. Add to `parseArgs` a new shape and to `run` a branch that, when git mode is set, calls `input.showAtRef` for both refs instead of `readFile`. Concretely, add to `Options`:
```zig
    git_mode: bool = false,
    git_ref_before: []const u8 = "",
    git_ref_after: []const u8 = "",
    git_path: []const u8 = "",
```
In `parseArgs`, before the positional handling, detect `--git`:
```zig
        } else if (std.mem.eql(u8, a, "--git")) {
            // Expect: --git <beforeRef> <afterRef> <path>
            if (i + 3 >= args.len) return ArgError.MissingOperands;
            return .{
                .before = "",
                .after = "",
                .format = format,
                .project_root = project_root,
                .git_mode = true,
                .git_ref_before = args[i + 1],
                .git_ref_after = args[i + 2],
                .git_path = args[i + 3],
            };
```
> Place this branch so that `--json`/`--html`/`--project` parsed *before* `--git` still apply (they set `format`/`project_root` which are captured in the returned struct). Flags after `--git` are treated as its operands; document that `--git` must come last.

In `run`, replace the two `readFile` lines with:
```zig
    const before = if (opt.git_mode)
        try input.showAtRef(arena, ".", opt.git_ref_before, opt.git_path)
    else
        try readFile(arena, opt.before);
    const after = if (opt.git_mode)
        try input.showAtRef(arena, ".", opt.git_ref_after, opt.git_path)
    else
        try readFile(arena, opt.after);
```
Add a test for the new parse shape:
```zig
test "parseArgs: --git captures refs and path" {
    const args = [_][]const u8{ "--json", "--git", "HEAD~1", "HEAD", "Foo.prefab" };
    const opt = try parseArgs(&args);
    try testing.expect(opt.git_mode);
    try testing.expectEqualStrings("HEAD~1", opt.git_ref_before);
    try testing.expectEqualStrings("HEAD", opt.git_ref_after);
    try testing.expectEqualStrings("Foo.prefab", opt.git_path);
    try testing.expectEqual(Format.json, opt.format);
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add cli/src/input.zig cli/src/main.zig
git commit -m "feat(cli): add git-ref input via git show subprocess"
```

---

## Task 11: ANSI tree renderer (`render_tree.zig`)

The default human-facing output (spec §6.1): a colored GameObject tree with field old→new lines.

**Files:**
- Create: `cli/src/render_tree.zig`
- Modify: `cli/src/main.zig` (use it for the `.tree` branch)

**Interfaces:**
- Consumes: `core.model.DiffResult`, `core.json.Resolver`.
- Produces: `pub fn render(arena, w: anytype, res: core.model.DiffResult, resolved: ?*const core.json.Resolver, color: bool) !void`

- [ ] **Step 1: Write the failing test (color disabled for stable golden)**

Create `cli/src/render_tree.zig`:
```zig
const std = @import("std");
const core = @import("core");
const testing = std.testing;

test "render: modified field shown old -> new without color" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    ;
    const after =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    ;
    const res = try core.diffBytes(arena, before, after);
    var out = std.ArrayList(u8).init(arena);
    try render(arena, out.writer(), res, null, false);
    const text = out.items;
    try testing.expect(std.mem.indexOf(u8, text, "MonoBehaviour") != null);
    try testing.expect(std.mem.indexOf(u8, text, "volume") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "->") != null);
    // No ANSI escape when color is disabled.
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
}
```

- [ ] **Step 2: Wire import, confirm failure**

Edit `cli/src/main.zig` imports + `test {}`:
```zig
pub const render_tree = @import("render_tree.zig");
```
(`_ = render_tree;` in the test block.)
Run: `zig build test`
Expected: FAIL — `render` undeclared.

- [ ] **Step 3: Implement the renderer**

Add above the test in `cli/src/render_tree.zig`:
```zig
const model = core.model;

const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";
};

fn statusColor(s: model.Status) []const u8 {
    return switch (s) {
        .added => Color.green,
        .removed => Color.red,
        .modified => Color.yellow,
        .unchanged => Color.dim,
    };
}

fn statusSign(s: model.Status) []const u8 {
    return switch (s) {
        .added => "+",
        .removed => "-",
        .modified => "~",
        .unchanged => " ",
    };
}

pub fn render(
    arena: std.mem.Allocator,
    w: anytype,
    res: model.DiffResult,
    resolved: ?*const core.json.Resolver,
    color: bool,
) !void {
    for (res.roots) |o| try renderObject(arena, w, o, resolved, color, 0);
    for (res.loose) |c| try renderComponent(arena, w, c, resolved, color, 0);
    if (res.unresolved_guids.len != 0 and resolved == null) {
        try w.print("\n({d} unresolved guid reference(s); pass --project DIR to resolve)\n", .{res.unresolved_guids.len});
    }
}

fn indent(w: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

fn paint(w: anytype, color: bool, code: []const u8, text: []const u8) !void {
    if (color) try w.writeAll(code);
    try w.writeAll(text);
    if (color) try w.writeAll(Color.reset);
}

fn renderObject(
    arena: std.mem.Allocator,
    w: anytype,
    o: model.ObjectDiff,
    resolved: ?*const core.json.Resolver,
    color: bool,
    depth: usize,
) !void {
    try indent(w, depth);
    try paint(w, color, statusColor(o.status), statusSign(o.status));
    const name = if (o.name.len != 0) o.name else "(GameObject)";
    try w.print(" {s}\n", .{name});
    for (o.components) |c| try renderComponent(arena, w, c, resolved, color, depth + 1);
    for (o.children) |child| try renderObject(arena, w, child, resolved, color, depth + 1);
}

fn renderComponent(
    arena: std.mem.Allocator,
    w: anytype,
    c: model.ComponentDiff,
    resolved: ?*const core.json.Resolver,
    color: bool,
    depth: usize,
) !void {
    try indent(w, depth);
    try paint(w, color, statusColor(c.status), statusSign(c.status));
    var display = c.type_name;
    if (c.script_guid) |g| {
        if (resolved) |r| {
            if (r.get(g)) |p| display = std.fs.path.basename(p);
        }
    }
    try w.print(" {s}\n", .{display});
    for (c.fields) |f| try renderField(arena, w, f, color, depth + 1);
}

fn renderField(arena: std.mem.Allocator, w: anytype, f: model.FieldDiff, color: bool, depth: usize) !void {
    _ = arena;
    try indent(w, depth);
    try paint(w, color, statusColor(f.status), statusSign(f.status));
    try w.print(" {s}: ", .{f.path});
    switch (f.status) {
        .modified => {
            try writeValueText(w, f.before);
            try w.writeAll(" -> ");
            try writeValueText(w, f.after);
        },
        .added => try writeValueText(w, f.after),
        .removed => try writeValueText(w, f.before),
        .unchanged => {},
    }
    try w.writeByte('\n');
}

fn writeValueText(w: anytype, node: ?*const model.Node) !void {
    const n = node orelse {
        try w.writeAll("∅");
        return;
    };
    switch (n.*) {
        .scalar => |s| try w.writeAll(s),
        .ref => |r| {
            if (r.guid) |g| {
                try w.print("{{guid:{s}, fileID:{d}}}", .{ g, r.file_id });
            } else {
                try w.print("{{fileID:{d}}}", .{r.file_id});
            }
        },
        .map => try w.writeAll("{...}"),
        .seq => try w.writeAll("[...]"),
    }
}
```

- [ ] **Step 4: Run renderer test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Use the renderer in `main.zig`**

In `run`, replace the `.tree` branch body (the JSON fallback) with:
```zig
        .tree => {
            const res = try core.diffBytes(arena, before, after);
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                idx = try resolve.buildIndex(arena, proj);
                resolver_ptr = &idx;
            }
            // Color when stdout is a TTY is decided in main(); tests pass color=false.
            try render_tree.render(arena, stdout, res, resolver_ptr, false);
        },
```
> Color detection (TTY check) can be added in `main()` later by passing a `color` flag through; Phase 1 keeps `render` color-parameterized and defaults the wired call to `false` for deterministic output. (A `--color` flag is a trivial future addition.)

Run: `zig build test`
Expected: PASS.

Manually verify:
```bash
zig build run -- /tmp/a.asset /tmp/b.asset
```
Expected: a tree showing `~ MonoBehaviour` and `~ hp: 1 -> 2`.

- [ ] **Step 6: Commit**
```bash
git add cli/src/render_tree.zig cli/src/main.zig
git commit -m "feat(cli): add ANSI tree renderer as default output"
```

---

## Task 12: HTML renderer (`render_html.zig`)

Self-contained, shareable HTML output (spec §6.1, `--html`).

**Files:**
- Create: `cli/src/render_html.zig`
- Modify: `cli/src/main.zig` (use it for the `.html` branch)

**Interfaces:**
- Consumes: `core.model.DiffResult`, `core.json.Resolver`.
- Produces: `pub fn render(arena, w: anytype, res: core.model.DiffResult, resolved: ?*const core.json.Resolver) !void` — writes a complete `<!DOCTYPE html>` document with inline CSS (no external assets).

- [ ] **Step 1: Write the failing test**

Create `cli/src/render_html.zig`:
```zig
const std = @import("std");
const core = @import("core");
const testing = std.testing;

test "html: self-contained document with escaped content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A<x>
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A<x>
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    var out = std.ArrayList(u8).init(arena);
    try render(arena, out.writer(), res, null);
    const html = out.items;
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    // HTML special chars escaped: "A<x>" -> "A&lt;x&gt;"
    try testing.expect(std.mem.indexOf(u8, html, "A&lt;x&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hp") != null);
}
```

- [ ] **Step 2: Wire import + confirm failure**

Edit `cli/src/main.zig` imports + `test {}`:
```zig
pub const render_html = @import("render_html.zig");
```
(`_ = render_html;` in the test block.)
Run: `zig build test`
Expected: FAIL — `render` undeclared.

- [ ] **Step 3: Implement the HTML renderer**

Add above the test in `cli/src/render_html.zig`:
```zig
const model = core.model;

const head =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<title>PrefabLens diff</title>
    \\<style>
    \\body{font:14px/1.5 ui-monospace,Menlo,Consolas,monospace;background:#0d1117;color:#c9d1d9;margin:1.5rem}
    \\.tree{white-space:pre}
    \\.added{color:#3fb950}.removed{color:#f85149}.modified{color:#d29922}.unchanged{color:#8b949e}
    \\.go{font-weight:600}.field{color:#c9d1d9}
    \\.old{color:#f85149}.new{color:#3fb950}
    \\h1{font-size:1rem;color:#58a6ff}
    \\</style></head><body>
    \\<h1>PrefabLens — prefablens.diff.v1</h1>
    \\<div class="tree">
;

const tail =
    \\</div></body></html>
;

pub fn render(
    arena: std.mem.Allocator,
    w: anytype,
    res: model.DiffResult,
    resolved: ?*const core.json.Resolver,
) !void {
    try w.writeAll(head);
    for (res.roots) |o| try renderObject(arena, w, o, resolved, 0);
    for (res.loose) |c| try renderComponent(arena, w, c, resolved, 0);
    try w.writeAll(tail);
}

fn cls(s: model.Status) []const u8 {
    return switch (s) {
        .added => "added",
        .removed => "removed",
        .modified => "modified",
        .unchanged => "unchanged",
    };
}

fn sign(s: model.Status) []const u8 {
    return switch (s) {
        .added => "+",
        .removed => "-",
        .modified => "~",
        .unchanged => " ",
    };
}

fn pad(w: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

fn renderObject(arena: std.mem.Allocator, w: anytype, o: model.ObjectDiff, resolved: ?*const core.json.Resolver, depth: usize) !void {
    try pad(w, depth);
    try w.print("<span class=\"{s} go\">{s} ", .{ cls(o.status), sign(o.status) });
    try writeEscaped(w, if (o.name.len != 0) o.name else "(GameObject)");
    try w.writeAll("</span>\n");
    for (o.components) |c| try renderComponent(arena, w, c, resolved, depth + 1);
    for (o.children) |child| try renderObject(arena, w, child, resolved, depth + 1);
}

fn renderComponent(arena: std.mem.Allocator, w: anytype, c: model.ComponentDiff, resolved: ?*const core.json.Resolver, depth: usize) !void {
    _ = arena;
    try pad(w, depth);
    var display = c.type_name;
    if (c.script_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
        display = std.fs.path.basename(p);
    };
    try w.print("<span class=\"{s}\">{s} ", .{ cls(c.status), sign(c.status) });
    try writeEscaped(w, display);
    try w.writeAll("</span>\n");
    for (c.fields) |f| try renderField(w, f, depth + 1);
}

fn renderField(w: anytype, f: model.FieldDiff, depth: usize) !void {
    try pad(w, depth);
    try w.print("<span class=\"{s} field\">{s} ", .{ cls(f.status), sign(f.status) });
    try writeEscaped(w, f.path);
    try w.writeAll(": ");
    switch (f.status) {
        .modified => {
            try w.writeAll("<span class=\"old\">");
            try writeValueEscaped(w, f.before);
            try w.writeAll("</span> → <span class=\"new\">");
            try writeValueEscaped(w, f.after);
            try w.writeAll("</span>");
        },
        .added => {
            try w.writeAll("<span class=\"new\">");
            try writeValueEscaped(w, f.after);
            try w.writeAll("</span>");
        },
        .removed => {
            try w.writeAll("<span class=\"old\">");
            try writeValueEscaped(w, f.before);
            try w.writeAll("</span>");
        },
        .unchanged => {},
    }
    try w.writeAll("</span>\n");
}

fn writeValueEscaped(w: anytype, node: ?*const model.Node) !void {
    const n = node orelse {
        try w.writeAll("∅");
        return;
    };
    switch (n.*) {
        .scalar => |s| try writeEscaped(w, s),
        .ref => |r| {
            if (r.guid) |g| {
                try w.print("{{guid:{s}, fileID:{d}}}", .{ g, r.file_id });
            } else {
                try w.print("{{fileID:{d}}}", .{r.file_id});
            }
        },
        .map => try w.writeAll("{...}"),
        .seq => try w.writeAll("[...]"),
    }
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}
```

- [ ] **Step 4: Run the HTML test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Use the renderer in `main.zig`**

Replace the `.html` branch body in `run` with:
```zig
        .html => {
            const res = try core.diffBytes(arena, before, after);
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                idx = try resolve.buildIndex(arena, proj);
                resolver_ptr = &idx;
            }
            try render_html.render(arena, stdout, res, resolver_ptr);
        },
```
Run: `zig build test`
Expected: PASS.

Manually verify:
```bash
zig build run -- --html /tmp/a.asset /tmp/b.asset > /tmp/diff.html
head -1 /tmp/diff.html
```
Expected: `<!DOCTYPE html>`.

- [ ] **Step 6: Commit**
```bash
git add cli/src/render_html.zig cli/src/main.zig
git commit -m "feat(cli): add self-contained HTML renderer (--html)"
```

---

## Task 13: Performance budget gate (CI)

Enforces the native performance budget (spec §5.7) so regressions fail CI.

**Files:**
- Create: `core/src/perf.zig`
- Modify: `build.zig` (add a `perf` step), `.github/workflows/ci.yml` (run it)

**Interfaces:**
- Consumes: `parser`, `diff` (via a generated large fixture).
- Produces: a `zig build perf` step that builds a synthetic large scene in-memory, times `core.diffBytes`, and exits non-zero if over the CI threshold.

- [ ] **Step 1: Write the perf harness as a test (small budget first to prove the gate)**

Create `core/src/perf.zig`:
```zig
const std = @import("std");
const root = @import("root.zig");

/// Build a synthetic scene with `n` GameObjects, each with a Transform and a
/// MonoBehaviour, as a single YAML byte buffer.
fn buildScene(arena: std.mem.Allocator, n: usize, hp: usize) ![]u8 {
    var buf = std.ArrayList(u8).init(arena);
    const w = buf.writer();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const go: i64 = @intCast(1 + i * 3);
        const tr: i64 = go + 1;
        const mb: i64 = go + 2;
        try w.print(
            \\--- !u!1 &{d}
            \\GameObject:
            \\  m_Name: GO{d}
            \\  m_Component:
            \\  - component: {{fileID: {d}}}
            \\  - component: {{fileID: {d}}}
            \\--- !u!4 &{d}
            \\Transform:
            \\  m_GameObject: {{fileID: {d}}}
            \\  m_Father: {{fileID: 0}}
            \\--- !u!114 &{d}
            \\MonoBehaviour:
            \\  m_GameObject: {{fileID: {d}}}
            \\  m_Script: {{fileID: 0, guid: abc, type: 3}}
            \\  hp: {d}
            \\
        , .{ go, i, tr, mb, tr, go, mb, go, hp });
    }
    return buf.toOwnedSlice();
}

/// Returns nanoseconds for one before/after diff over `n` objects.
pub fn timeDiff(arena: std.mem.Allocator, n: usize) !u64 {
    const before = try buildScene(arena, n, 1);
    const after = try buildScene(arena, n, 2);
    var timer = try std.time.Timer.start();
    const res = try root.diffBytes(arena, before, after);
    std.mem.doNotOptimizeAway(&res);
    return timer.read();
}

test "perf: small scene diff completes well under budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ns = try timeDiff(arena, 200); // ~200 objects ~= a small prefab
    // Generous sanity bound for a debug test build (real budget enforced by `zig build perf`).
    try std.testing.expect(ns < 500 * std.time.ns_per_ms);
}
```

- [ ] **Step 2: Re-export and run to confirm the test passes**

Edit `core/src/root.zig`:
```zig
pub const perf = @import("perf.zig");
```
Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Add a release-mode `perf` executable + build step**

Create `core/src/perf_main.zig`:
```zig
const std = @import("std");
const perf = @import("perf.zig");

// Budget multipliers leave headroom for CI runner noise; nominal targets are
// spec §5.7 (typical < 5ms, ~10MB scene < 150ms). We size a ~10MB scene and
// assert it diffs under a generous CI ceiling.
const big_objects = 50_000; // ~10 MB of YAML at ~200 bytes/object
const ci_ceiling_ms = 600; // 4x the 150ms nominal; fails only on real regressions

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ns = try perf.timeDiff(arena, big_objects);
    const ms = ns / std.time.ns_per_ms;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("perf: {d} objects diffed in {d} ms (ceiling {d} ms)\n", .{ big_objects, ms, ci_ceiling_ms });
    if (ms > ci_ceiling_ms) {
        try stdout.print("PERF BUDGET EXCEEDED\n", .{});
        std.process.exit(1);
    }
}
```

Add to `build.zig`, before the final lines of `build()`:
```zig
    const perf_exe = b.addExecutable(.{
        .name = "perf",
        .root_source_file = b.path("core/src/perf_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const run_perf = b.addRunArtifact(perf_exe);
    const perf_step = b.step("perf", "Run the performance budget gate (ReleaseFast)");
    perf_step.dependOn(&run_perf.step);
```

Run: `zig build perf`
Expected: prints `perf: 50000 objects diffed in <N> ms (ceiling 600 ms)` and exits 0. If it exceeds, the diff has a real performance problem — investigate before continuing.

- [ ] **Step 4: Wire perf into CI**

Edit `.github/workflows/ci.yml`, add a step after Test:
```yaml
      - name: Performance budget
        run: zig build perf
```

- [ ] **Step 5: Commit**
```bash
git add core/src/perf.zig core/src/perf_main.zig core/src/root.zig build.zig .github/workflows/ci.yml
git commit -m "feat(core): enforce native parse+diff performance budget in CI"
```

---

## Final verification

- [ ] Run the whole suite and the perf gate:
```bash
zig build test && zig build perf
```
Expected: all tests pass; perf prints under the ceiling.

- [ ] End-to-end smoke across all three formats:
```bash
zig build run -- /tmp/a.asset /tmp/b.asset            # ANSI tree
zig build run -- --json /tmp/a.asset /tmp/b.asset     # prefablens.diff.v1 JSON
zig build run -- --html /tmp/a.asset /tmp/b.asset      # HTML document
```

- [ ] Confirm CI is green on a pushed branch.

---

## Self-Review (performed against the spec)

**1. Spec coverage**

| Spec Phase 1 requirement (§9 "入れる") | Task |
|---|---|
| Zig 共通コア: パーサ | Task 4 |
| fileID 突合 | Task 5 |
| フィールド diff | Task 5 |
| 静的 classID テーブル | Task 3 |
| ローカル参照解決（同一ファイル内 fileID） | Tasks 5–6 (refs carried; local fileID matched in tree) |
| 構造化 JSON 出力 (`prefablens.diff.v1`) | Task 7 |
| CLI: ファイル入力 | Task 8 |
| CLI: git ref 入力 (`--git`, working tree) | Task 10 |
| CLI: ローカル `.meta` 走査による guid 解決 | Task 9 |
| CLI: ANSI ツリー出力 | Task 11 |
| CLI: `--json` 出力 | Task 8 |
| CLI: `--html` 出力 | Task 12 |
| フィクスチャ＋ゴールデンテスト | Every task (inline fixtures + golden in Tasks 7, 11, 12) |
| CI | Task 1 |
| 性能予算 (§5.7, native) | Task 13 |
| 名前ベース二次マッチングは入れない | Honored — fileID-only matching (Task 5) |
| Chrome/Editor/AI は入れない | Honored — not in this plan |

Gaps intentionally deferred (noted in spec as later/non-Phase-1): C ABI / WASM target (Phase 2 — core stays pure Zig API; `abi.zig` added with Chrome), `--staged` exact convenience flag (working-tree + arbitrary refs covered by `--git`; `--staged` is a thin alias addable later), WASM bundle-size budget (Phase 2, where WASM exists).

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". The only non-literal value is `build.zig.zon`'s `.fingerprint`, which is *machine-generated by `zig init`* (Task 1 Step 2) and must not be invented — this is correct, not a placeholder. The `.tree`/`.html` JSON fallbacks in Task 8 are explicitly temporary and replaced in Tasks 11/12 (each task leaves the build green).

**3. Type consistency:** `core.diffBytes`, `core.diffToJson`, `core.json.serialize`, `core.json.Resolver`, `diff.compute`/`FlatDiff`/`DocDiff`, `tree.build`, `model.*`, `parser.parse`, `classid.typeName`, CLI `parseArgs`/`run`/`Options`/`Format`, `resolve.buildIndex`/`Index`, `input.showAtRef`, `render_tree.render`, `render_html.render`, `perf.timeDiff` are used identically across the tasks that define and consume them. `resolve.Index` and `core.json.Resolver` are deliberately the same type (`std.StringHashMap([]const u8)`) so the index passes straight through.
