# Core Prefab Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Unity prefab semantics one owner and preserve the current native, JSON, and WASM behavior.

**Architecture:** Keep the flat module structure under `core/src/`. Add `prefab.zig` for shared `PrefabInstance` reads and use explicit error sets.

**Tech Stack:** Zig 0.16.0, Node.js test runner, pnpm, Vitest, Playwright, freestanding WASM

**Spec:** `docs/superpowers/specs/2026-08-13-core-prefab-semantics-design.md`

## Global Constraints

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
- Keep `model.zig`, the JSON schema, and the WASM ABI unchanged.
- Comments must explain a reason that the code does not show.

## File Map

- Create `core/src/prefab.zig` for shared `PrefabInstance` reads and modification identity.
- Modify `core/src/parser.zig` to define `parser.Error` and remove recursive `anyerror` returns.
- Modify `core/src/root.zig` to publish exact error sets and re-export `prefab.Assets`.
- Modify `core/src/diff.zig` to use allocation-only recursion errors and the Inspector tuple formatter.
- Modify `core/src/diff_overrides.zig` to consume `prefab.Modification` and remove its production import of `diff.zig`.
- Modify `core/src/instantiate.zig` to propagate allocation errors and consume shared prefab rules.
- Modify `core/src/tree.zig` to use shared source GUID and scalar modification reads.
- Modify `core/src/tree_chain.zig` to keep only hierarchy traversal.
- Modify `core/src/assets_tlv.zig` to decode `prefab.Assets` directly.
- Modify `core/src/inspector.zig` to own synthesized tuple display values.

---

### Task 1: Expose Allocation Failures

**Files:**

- Modify: `core/src/parser.zig:375-640`
- Modify: `core/src/diff.zig:572-716`
- Modify: `core/src/instantiate.zig:53-69`
- Modify: `core/src/root.zig:17-40`
- Test: `core/src/parser.zig`
- Test: `core/src/instantiate.zig`

**Interfaces:**

- Consumes: `std.mem.Allocator.Error` and `std.Io.Writer.Error` from Zig 0.16.0.
- Produces: `parser.Error`, `root.DiffError`, and `root.JsonError`.
- Produces: Source expansion returns `OutOfMemory` and recovers only from `NestingTooDeep`.

- [ ] **Step 1: Add the parser allocation regression test**

Add this test near the current nesting test in `parser.zig`:

```zig
test "parse: allocation failure reaches the caller" {
    var buffer: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    try testing.expectError(
        error.OutOfMemory,
        parse(fixed.allocator(), "--- !u!1 &1\nGameObject:\n  m_Name: A\n"),
    );
}
```

- [ ] **Step 2: Add the source expansion allocation regression test**

Add this test in `instantiate.zig`:

```zig
test "instantiate: source allocation failure reaches the caller" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
    ;
    const fd = try diffmod.compute(arena, "", after);
    var result = try tree.build(arena, fd);

    var source: std.ArrayList(u8) = .empty;
    for (0..2048) |index| {
        const document = try std.fmt.allocPrint(
            arena,
            "--- !u!1 &{d}\nGameObject:\n  m_Name: Object{d}\n",
            .{ index + 1, index + 1 },
        );
        try source.appendSlice(arena, document);
    }
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", source.items);

    var buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    try testing.expectError(
        error.OutOfMemory,
        expand(fixed.allocator(), &result, fd, &assets),
    );
}
```

- [ ] **Step 3: Add the source nesting recovery test**

Add this test in `instantiate.zig`:

```zig
test "instantiate: unsafe source nesting keeps the degraded instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
    ;
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena, "--- !u!114 &1\nMonoBehaviour:\n  m_Field: ");
    for (0..130) |_| try source.appendSlice(arena, "{a: ");
    try source.append(arena, '1');
    for (0..130) |_| try source.append(arena, '}');

    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", source.items);
    const result = try root.diffBytesWithAssets(arena, "", after, &assets);
    try testing.expectEqual(@as(usize, 1), result.roots.len);
    try testing.expectEqual(@as(usize, 0), result.roots[0].children.len);
}
```

- [ ] **Step 4: Run the new tests before the fix**

Run:

```sh
zig test core/src/root.zig --test-filter "allocation failure reaches the caller"
```

Expected: The parser and nesting tests pass. The source allocation test fails because `expand` returns success.

- [ ] **Step 5: Define explicit parser errors**

Add this declaration after the parser type aliases:

```zig
pub const Error = std.mem.Allocator.Error || error{NestingTooDeep};
```

Use `Error` for `parse`, `parseDocument`, and all recursive parser functions. Use `std.mem.Allocator.Error` for allocation-only helpers.

The recursive signatures must include:

```zig
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error![]Document
fn parseDocument(p: *Parser) Error!Document
fn parseBlock(p: *Parser, indent: usize, depth: usize) Error!*Node
fn parseMap(p: *Parser, indent: usize, depth: usize) Error!*Node
fn parseNestedValue(p: *Parser, key_indent: usize, depth: usize) Error!*Node
fn parseSeq(p: *Parser, indent: usize, depth: usize) Error!*Node
fn parseSeqMapItem(p: *Parser, dash_indent: usize, first_line: []const u8, depth: usize) Error!*Node
fn parseValue(arena: std.mem.Allocator, raw: []const u8, depth: usize) Error!*Node
fn parseFlow(arena: std.mem.Allocator, source: []const u8, depth: usize) Error!*Node
fn parseFlowSeq(arena: std.mem.Allocator, source: []const u8, depth: usize) Error!*Node
fn unquote(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]const u8
```

- [ ] **Step 6: Restrict the recovery path in source expansion**

Replace the broad catch in `expandNode` with this switch:

```zig
const src_docs = parser.parse(ctx.arena, bytes) catch |err| switch (err) {
    error.NestingTooDeep => return,
    error.OutOfMemory => return error.OutOfMemory,
};
```

- [ ] **Step 7: Remove `anyerror` from diff recursion**

Change `diffNode`, `diffMap`, `diffSeq`, `flattenSubtree`, and `collectGuids` to return `std.mem.Allocator.Error!void`.

- [ ] **Step 8: Publish the root error contract**

Add these declarations and exact return types in `root.zig`:

```zig
pub const DiffError = parser.Error;
pub const JsonError = DiffError || std.Io.Writer.Error;

pub fn diffBytes(
    arena: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
) DiffError!model.DiffResult

pub fn diffBytesWithAssets(
    arena: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
    assets: *const Assets,
) DiffError!model.DiffResult

pub fn diffToJson(
    arena: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
) JsonError![]u8

pub fn diffToJsonWithAssets(
    arena: std.mem.Allocator,
    before_src: []const u8,
    after_src: []const u8,
    assets: *const Assets,
) JsonError![]u8
```

Keep the current function bodies.

- [ ] **Step 9: Run the native checks**

Run:

```sh
zig build lint --summary all
zig build test --summary all
```

Expected: The lint step succeeds and all tests pass.

- [ ] **Step 10: Make sure that broad recursive error sets are absent**

Run:

```sh
rg -n "anyerror|parser\.parse\([^\n]*\) catch return" core/src
```

Expected: The command prints no matches.

- [ ] **Step 11: Commit the error contract**

```sh
git add core/src/parser.zig core/src/diff.zig core/src/instantiate.zig core/src/root.zig
git commit -m "refactor: expose core allocation errors"
```

---

### Task 2: Add the Prefab Semantic Module

**Files:**

- Create: `core/src/prefab.zig`
- Modify: `core/src/root.zig:5-58`
- Test: `core/src/prefab.zig`

**Interfaces:**

- Consumes: `model.Document`, `model.Node`, and `model.Ref`.
- Produces: `prefab.Assets = std.StringHashMapUnmanaged([]const u8)`.
- Produces: `prefab.ModificationIterator`, `prefab.modifications`, `prefab.sourceGuid`, and `prefab.scalarModificationValue`.

- [ ] **Step 1: Add the failing module tests**

Create `prefab.zig` with imports and these tests. Keep the production declarations absent for this step.

```zig
const std = @import("std");
const model = @import("model.zig");
const Node = model.Node;
const testing = std.testing;

test "prefab: modifications skip malformed entries in source order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try @import("parser.zig").parse(arena,
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - invalid
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      value: missing-path
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: First
        \\    - target: {fileID: 9, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 100
    );

    var iterator = modifications(&docs[0]);
    const first = iterator.next().?;
    const second = iterator.next().?;
    try testing.expectEqual(@as(i64, 8), first.targetFileId());
    try testing.expectEqualStrings("m_Name", first.property_path);
    try testing.expectEqual(@as(i64, 9), second.targetFileId());
    try testing.expectEqualStrings("maxHp", second.property_path);
    try testing.expect(iterator.next() == null);
}

test "prefab: effective value prefers a set object reference" {
    var scalar = Node{ .scalar = "100" };
    var empty_ref = Node{ .ref = .{ .file_id = 0 } };
    var set_ref = Node{ .ref = .{ .file_id = 42 } };

    const scalar_mod = Modification.init(null, "value", &scalar, &empty_ref);
    const ref_mod = Modification.init(null, "reference", &scalar, &set_ref);
    try testing.expect(scalar_mod.effectiveValue() == &scalar);
    try testing.expect(ref_mod.effectiveValue() == &set_ref);
}

test "prefab: source and scalar lookups keep serialized values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const docs = try @import("parser.zig").parse(arena_state.allocator(),
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: source-guid, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\  m_SourcePrefab: {fileID: 100100000, guid: source-guid, type: 3}
    );

    try testing.expectEqualStrings("source-guid", sourceGuid(&docs[0]).?);
    try testing.expectEqualStrings("Cylinder", scalarModificationValue(&docs[0], "m_Name").?);
}
```

- [ ] **Step 2: Run the new tests before the implementation**

Run:

```sh
zig test core/src/prefab.zig
```

Expected: Compilation fails because the prefab interfaces do not exist.

- [ ] **Step 3: Implement the modification view and iterator**

Add these declarations before the tests:

```zig
pub const Assets = std.StringHashMapUnmanaged([]const u8);

pub const Modification = struct {
    target: ?model.Ref,
    property_path: []const u8,
    value: ?*Node,
    object_reference: ?*Node,

    pub fn init(target: ?model.Ref, property_path: []const u8, value: ?*Node, raw_object_reference: ?*Node) Modification {
        return .{
            .target = target,
            .property_path = property_path,
            .value = value,
            .object_reference = setObjectReference(raw_object_reference),
        };
    }

    pub fn targetFileId(self: Modification) i64 {
        return if (self.target) |target| target.file_id else 0;
    }

    pub fn effectiveValue(self: Modification) ?*Node {
        return self.object_reference orelse self.value;
    }

    pub fn key(self: Modification, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{d}:{s}", .{ self.targetFileId(), self.property_path });
    }
};

pub const ModificationIterator = struct {
    items: []*Node,
    index: usize = 0,

    pub fn next(self: *ModificationIterator) ?Modification {
        while (self.index < self.items.len) {
            const item = self.items[self.index];
            self.index += 1;
            if (item.* != .map) continue;
            const path = model.findValue(item.map, "propertyPath") orelse continue;
            if (path.* != .scalar) continue;
            const target = if (model.findValue(item.map, "target")) |node|
                switch (node.*) {
                    .ref => |value| value,
                    else => null,
                }
            else
                null;
            return Modification.init(
                target,
                path.scalar,
                model.findValue(item.map, "value"),
                model.findValue(item.map, "objectReference"),
            );
        }
        return null;
    }
};

pub fn modifications(doc: *const model.Document) ModificationIterator {
    const modification = model.findValue(doc.body.map, "m_Modification") orelse return .{ .items = &.{} };
    if (modification.* != .map) return .{ .items = &.{} };
    const list = model.findValue(modification.map, "m_Modifications") orelse return .{ .items = &.{} };
    if (list.* != .seq) return .{ .items = &.{} };
    return .{ .items = list.seq };
}

fn setObjectReference(node: ?*Node) ?*Node {
    const reference = node orelse return null;
    return switch (reference.*) {
        .ref => |value| if (value.file_id != 0 or value.guid != null) reference else null,
        else => null,
    };
}
```

- [ ] **Step 4: Implement the document lookups**

Add these functions:

```zig
pub fn sourceGuid(doc: *const model.Document) ?[]const u8 {
    const source = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (source.*) {
        .ref => |value| value.guid,
        else => null,
    };
}

pub fn scalarModificationValue(doc: *const model.Document, property_path: []const u8) ?[]const u8 {
    var iterator = modifications(doc);
    while (iterator.next()) |modification| {
        if (!std.mem.eql(u8, modification.property_path, property_path)) continue;
        const value = modification.value orelse continue;
        return switch (value.*) {
            .scalar => |scalar| scalar,
            else => null,
        };
    }
    return null;
}
```

- [ ] **Step 5: Register the module in the root test graph**

Import `prefab.zig` in `root.zig` and reference it in the root test block:

```zig
const prefab = @import("prefab.zig");
```

```zig
_ = prefab;
```

- [ ] **Step 6: Run the semantic module and full native tests**

Run:

```sh
zig test core/src/prefab.zig
zig build lint --summary all
zig build test --summary all
```

Expected: All commands succeed.

- [ ] **Step 7: Commit the semantic boundary**

```sh
git add core/src/prefab.zig core/src/root.zig
git commit -m "refactor: add prefab semantic boundary"
```

---

### Task 3: Move Consumers to Prefab Semantics

**Files:**

- Modify: `core/src/diff_overrides.zig:300-522`
- Modify: `core/src/instantiate.zig:8-233`
- Modify: `core/src/tree.zig:5-30,141-150`
- Modify: `core/src/tree_chain.zig:4-73`
- Modify: `core/src/assets_tlv.zig:5-12`
- Modify: `core/src/root.zig:15-19`
- Test: `core/src/diff_overrides.zig`

**Interfaces:**

- Consumes: All public declarations from `prefab.zig` in Task 2.
- Produces: One implementation of modification parsing, value selection, key creation, source GUID lookup, and scalar lookup.

- [ ] **Step 1: Add a duplicate-key characterization test**

Add this test in `diff_overrides.zig`:

```zig
test "diff: duplicate sole-side modifications keep the last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try @import("parser.zig").parse(arena,
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 100
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 200
    );

    const overrides = try soleInstanceOverrides(arena, &docs[0], .added);
    try testing.expectEqual(@as(usize, 1), overrides.len);
    try testing.expectEqualStrings("200", overrides[0].after.?.scalar);
}
```

- [ ] **Step 2: Run the characterization test before movement**

Run:

```sh
zig test core/src/root.zig --test-filter "duplicate sole-side modifications"
```

Expected: The test passes with the current last-value behavior.

- [ ] **Step 3: Replace the local modification type in `diff_overrides.zig`**

Import `prefab.zig` and use this collector:

```zig
const prefab = @import("prefab.zig");
const Mod = prefab.Modification;

fn collectMods(arena: std.mem.Allocator, doc: *const model.Document) ![]Mod {
    var mods: std.ArrayList(Mod) = .empty;
    var iterator = prefab.modifications(doc);
    while (iterator.next()) |modification| try mods.append(arena, modification);
    return mods.toOwnedSlice(arena);
}
```

Replace local fields as follows:

```zig
m.target       -> m.targetFileId()
m.path         -> m.property_path
m.obj_ref      -> m.object_reference
modValue(m)    -> m.effectiveValue()
modKey(arena,m)-> m.key(arena)
```

Delete `objRefIfSet`, `modValue`, `modKeyOf`, and the old `Mod` declaration.

- [ ] **Step 4: Move `instantiate.zig` to the shared iterator**

Import `prefab.zig`, set `const Assets = prefab.Assets`, and replace the loop in `applyModifications`:

```zig
var iterator = prefab.modifications(inst_doc);
while (iterator.next()) |modification| {
    const target = modification.target orelse continue;
    const target_guid = target.guid orelse continue;
    if (!std.mem.eql(u8, target_guid, source_guid)) continue;
    const effective_value = modification.effectiveValue() orelse continue;
    var handled = false;
    for (src_docs) |*doc| {
        if (doc.file_id != target.file_id) continue;
        setByPropertyPath(doc.body, modification.property_path, effective_value);
        handled = true;
        break;
    }
    if (!handled) {
        handled = try pushDown(
            arena,
            src_docs,
            target.file_id,
            modification.property_path,
            modification.value,
            modification.object_reference,
        );
    }
    if (handled) try applied.put(arena, try modification.key(arena), {});
}
```

Change `pushDown` and `appendMod` to receive `property_path: []const u8`. Create the property path node inside `appendMod`:

```zig
const property_path_node = try arena.create(model.Node);
property_path_node.* = .{ .scalar = property_path };
try entries.append(arena, .{ .key = "propertyPath", .value = property_path_node });
```

Replace `sourceGuidOf` with `prefab.sourceGuid`. Delete `sourceGuidOf` and `objRefIfSet`.

- [ ] **Step 5: Move tree reads to `prefab.zig`**

Import `prefab.zig` in `tree.zig`. Replace the two calls as follows:

```zig
return prefab.scalarModificationValue(doc, "m_Name") orelse "";
```

```zig
.source_guid = if (doc) |value| prefab.sourceGuid(value) else null,
```

Delete `sourcePrefabGuid` from `tree.zig`. Delete `modificationValue` from `tree_chain.zig`.

- [ ] **Step 6: Move the `Assets` owner**

Change `assets_tlv.zig` to use this declaration:

```zig
const Assets = @import("prefab.zig").Assets;
```

Change `root.zig` to publish this alias:

```zig
pub const Assets = prefab.Assets;
```

Delete the public `Assets` declaration from `instantiate.zig`.

- [ ] **Step 7: Run the native checks**

Run:

```sh
zig build lint --summary all
zig build test --summary all
```

Expected: The lint step succeeds and all tests pass.

- [ ] **Step 8: Make sure that duplicate readers are absent**

Run:

```sh
rg -n "fn (sourcePrefabGuid|sourceGuidOf|modificationValue|objRefIfSet|modKeyOf|modValue)" core/src
rg -n 'findValue\([^\n]*"m_Modifications"' core/src
```

Expected: The first command prints no matches. The second command prints matches only in `prefab.zig` and mutation code in `instantiate.zig`.

- [ ] **Step 9: Commit the consumer migration**

```sh
git add core/src/prefab.zig core/src/diff_overrides.zig core/src/instantiate.zig core/src/tree.zig core/src/tree_chain.zig core/src/assets_tlv.zig core/src/root.zig
git commit -m "refactor: centralize prefab semantics"
```

---

### Task 4: Remove the Diff Dependency Cycle

**Files:**

- Modify: `core/src/inspector.zig:1-162`
- Modify: `core/src/diff.zig:650-676`
- Modify: `core/src/diff_overrides.zig:1-305,490-510`

**Interfaces:**

- Consumes: `model.Node` and the caller-owned allocator.
- Produces: `inspector.joinedScalarNode(arena, values) std.mem.Allocator.Error!*model.Node`.
- Produces: No production import from `diff_overrides.zig` to `diff.zig`.

- [ ] **Step 1: Add the failing Inspector formatter test**

Add this test in `inspector.zig`:

```zig
test "inspector: joined scalar node formats tuple values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const node = try joinedScalarNode(arena_state.allocator(), &.{ "2", "3", "1" });
    try testing.expectEqualStrings("(2, 3, 1)", node.scalar);
}
```

- [ ] **Step 2: Run the new test before movement**

Run:

```sh
zig test core/src/inspector.zig --test-filter "joined scalar node"
```

Expected: Compilation fails because `joinedScalarNode` does not exist.

- [ ] **Step 3: Move the tuple formatter to `inspector.zig`**

Add this function:

```zig
pub fn joinedScalarNode(arena: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!*model.Node {
    var output: std.ArrayList(u8) = .empty;
    try output.append(arena, '(');
    for (values, 0..) |value, index| {
        if (index != 0) try output.appendSlice(arena, ", ");
        try output.appendSlice(arena, value);
    }
    try output.append(arena, ')');
    const node = try arena.create(model.Node);
    node.* = .{ .scalar = try output.toOwnedSlice(arena) };
    return node;
}
```

Replace `parenJoinNode` calls in `diff.zig` and `diff_overrides.zig` with `inspector.joinedScalarNode`. Delete `parenJoinNode` from `diff.zig`.

- [ ] **Step 4: Restrict `diff.zig` imports to tests**

Delete the top-level `diffmod` and `findDoc` declarations from `diff_overrides.zig`.

In each full-diff test, add this local declaration before its first call:

```zig
const diffmod = @import("diff.zig");
```

Replace each `findDoc(fd, file_id)` call with `diffmod.findDoc(fd, file_id)`.

- [ ] **Step 5: Run the native and WASM checks**

Run:

```sh
zig build lint --summary all
zig build test --summary all
zig build wasm --summary all
node --test core/tests/*.test.mjs
zig build perf
```

Expected: All commands succeed. The performance output stays within both budgets.

- [ ] **Step 6: Make sure that the production cycle is absent**

Run:

```sh
rg -n '^const diffmod = @import\("diff\.zig"\);' core/src/diff_overrides.zig
rg -n 'parenJoinNode|anyerror' core/src
```

Expected: Both commands print no matches.

- [ ] **Step 7: Run the extension integration checks**

Run from `extension/`:

```sh
pnpm install --frozen-lockfile
pnpm test
pnpm size
pnpm e2e
```

Expected: Vitest, the compressed WASM size check, and Playwright succeed.

- [ ] **Step 8: Review the complete diff**

Run:

```sh
git diff --check
git diff --stat 1be6eaa
git diff 1be6eaa -- core/src
git status --short
```

Make sure that the diff contains no schema, ABI, `model.zig`, `site/`, or extension source changes.

- [ ] **Step 9: Commit the cycle removal**

```sh
git add core/src/inspector.zig core/src/diff.zig core/src/diff_overrides.zig
git commit -m "refactor: remove core diff cycle"
```

- [ ] **Step 10: Run final verification from a clean state**

Run:

```sh
git status --short
zig build lint --summary all
zig build test --summary all
zig build wasm --summary all
node --test core/tests/*.test.mjs
zig build perf
cd extension
pnpm test
pnpm size
pnpm e2e
```

Expected: Git prints no changed files. All checks succeed with the committed code.
