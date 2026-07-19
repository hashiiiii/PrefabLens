// Source-prefab merging for PrefabInstance.
// Merge = parse the source -> apply m_Modifications to the Document -> reuse the existing
// one-sided compute + tree.build -> graft onto the instance node. core owns no I/O;
// the host supplies guid -> bytes (Assets). Guids with no supply go into needed_sources.
const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");
const diffmod = @import("diff.zig");
const diff_overrides = @import("diff_overrides.zig");
const tree = @import("tree.zig");

pub const Assets = std.StringHashMapUnmanaged([]const u8);

const Ctx = struct {
    arena: std.mem.Allocator,
    assets: *const Assets,
    // guids that need supplying -> side (first-seen order kept to make decisions deterministic).
    needed: std.StringArrayHashMapUnmanaged(model.SourceSide) = .empty,
    // Full set of referenced guids (for merging into unresolvedGuids, first-seen order).
    guids: std.StringArrayHashMapUnmanaged(void) = .empty,
    // guids of the ancestor chain (cycle guard). Reusing the same source among siblings is allowed.
    chain: std.ArrayList([]const u8) = .empty,
};

pub fn expand(arena: std.mem.Allocator, res: *model.DiffResult, fd: diffmod.FlatDiff, assets: *const Assets) !void {
    var ctx = Ctx{ .arena = arena, .assets = assets };
    // Merge source-derived external references (scripts/materials etc.) into the
    // top-level unresolvedGuids so they too become subject to host resolution.
    for (res.unresolved_guids) |g| try ctx.guids.put(arena, g, {});

    var docs = std.AutoHashMap(i64, *model.Document).init(arena);
    // Raw docs of sole-status instances (for reading m_Modifications). added exists only
    // on after, removed only on before, so inserting both lets either side be looked up.
    for (fd.before) |*d| try docs.put(d.file_id, d);
    for (fd.after) |*d| try docs.put(d.file_id, d);

    for (res.roots) |*node| try expandNode(&ctx, node, &docs, 0);

    res.unresolved_guids = ctx.guids.keys();
    res.needed_sources = try neededSlice(&ctx);
}

fn neededSlice(ctx: *Ctx) ![]model.NeededSource {
    var out: std.ArrayList(model.NeededSource) = .empty;
    var it = ctx.needed.iterator();
    while (it.next()) |e| try out.append(ctx.arena, .{ .guid = e.key_ptr.*, .side = e.value_ptr.* });
    return out.toOwnedSlice(ctx.arena);
}

fn expandNode(ctx: *Ctx, node: *model.ObjectDiff, docs: *std.AutoHashMap(i64, *model.Document), depth: usize) !void {
    for (node.children) |*child| try expandNode(ctx, child, docs, depth);
    if (node.kind != .prefab_instance) return;
    if (node.status != .added and node.status != .removed) return;
    const guid = node.source_guid orelse return;
    if (depth >= model.max_prefab_nesting or inChain(ctx, guid)) return;
    const side: model.SourceSide = if (node.status == .added) .after else .before;
    const bytes = ctx.assets.get(guid) orelse {
        try ctx.needed.put(ctx.arena, guid, side);
        return;
    };
    const inst_doc = docs.get(node.file_id) orelse return;

    // Parse the source and apply this instance's m_RemovedComponents / m_Modifications.
    // Don't let a broken source asset sink the whole diff: on parse failure, leave just that
    // instance in the degraded view (override enumeration).
    const src_docs = parser.parse(ctx.arena, bytes) catch return;
    applyRemovedComponents(inst_doc, src_docs);
    var applied = try applyModifications(ctx.arena, inst_doc, src_docs, guid);

    // Enumerate fully as a one-sided diff and turn it into an ObjectDiff via the existing pipeline.
    const none = try parser.parse(ctx.arena, "");
    const sub_fd = if (node.status == .added)
        try diffmod.computeParsed(ctx.arena, none, src_docs)
    else
        try diffmod.computeParsed(ctx.arena, src_docs, none);
    const sub = try tree.build(ctx.arena, sub_fd);
    for (sub_fd.unresolved_guids) |g| try ctx.guids.put(ctx.arena, g, {});

    // Recursively expand nested instances (push our own guid onto the ancestor chain).
    try ctx.chain.append(ctx.arena, guid);
    defer _ = ctx.chain.pop();
    var sub_docs = std.AutoHashMap(i64, *model.Document).init(ctx.arena);
    for (sub_fd.before) |*d| try sub_docs.put(d.file_id, d);
    for (sub_fd.after) |*d| try sub_docs.put(d.file_id, d);
    for (sub.roots) |*r| try expandNode(ctx, r, &sub_docs, depth + 1);

    // Graft: for a single root, lift its contents up into the instance node (same as Unity's
    // hierarchy display: instance = merge of the source root). A variant file's root is a
    // PrefabInstance, so carry over its leftover overrides too and collapse the duplicate node.
    var inner_overrides: []model.OverrideDiff = &.{};
    if (sub.roots.len == 1) {
        node.components = try concatComponents(ctx.arena, node.components, sub.roots[0].components, sub.loose);
        node.children = try concatObjects(ctx.arena, node.children, sub.roots[0].children);
        inner_overrides = sub.roots[0].overrides;
    } else {
        node.components = try concatComponents(ctx.arena, node.components, &.{}, sub.loose);
        node.children = try concatObjects(ctx.arena, node.children, sub.roots);
    }
    // Keep unapplied mods as rows (don't drop them silently).
    const leftover = try diff_overrides.soleInstanceOverridesSkipping(ctx.arena, inst_doc, node.status, &applied);
    node.overrides = try concatOverrides(ctx.arena, leftover, inner_overrides);
}

fn concatOverrides(arena: std.mem.Allocator, a: []model.OverrideDiff, b: []model.OverrideDiff) ![]model.OverrideDiff {
    if (b.len == 0) return a;
    var out: std.ArrayList(model.OverrideDiff) = .empty;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, b);
    return out.toOwnedSlice(arena);
}

fn inChain(ctx: *Ctx, guid: []const u8) bool {
    for (ctx.chain.items) |g| if (std.mem.eql(u8, g, guid)) return true;
    return false;
}

fn concatComponents(arena: std.mem.Allocator, a: []model.ComponentDiff, b: []model.ComponentDiff, c: []model.ComponentDiff) ![]model.ComponentDiff {
    var out: std.ArrayList(model.ComponentDiff) = .empty;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, b);
    try out.appendSlice(arena, c);
    return out.toOwnedSlice(arena);
}

fn concatObjects(arena: std.mem.Allocator, a: []model.ObjectDiff, b: []model.ObjectDiff) ![]model.ObjectDiff {
    var out: std.ArrayList(model.ObjectDiff) = .empty;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, b);
    return out.toOwnedSlice(arena);
}

// Mark the referents of m_RemovedComponents (source-internal fileIDs) as stripped
// (computeParsed excludes stripped docs).
fn applyRemovedComponents(inst_doc: *const model.Document, src_docs: []model.Document) void {
    const m = model.findValue(inst_doc.body.map, "m_Modification") orelse return;
    if (m.* != .map) return;
    const list = model.findValue(m.map, "m_RemovedComponents") orelse return;
    if (list.* != .seq) return;
    for (list.seq) |item| {
        if (item.* != .ref) continue;
        for (src_docs) |*d| {
            if (d.file_id == item.ref.file_id) d.stripped = true;
        }
    }
}

const AppliedSet = std.StringHashMapUnmanaged(void);

// Apply m_Modifications to the source Document (those whose target.guid is the source guid).
// A fileID that doesn't match directly belongs to a nested instance's namespace: Unity's nested
// fileID is "instance fileID XOR source-internal fileID", so append the XOR-transformed mod to the
// instance's m_Modifications tail to push it down (tail = outer wins last, same as the Inspector).
// Returns the key set of mods that were applied or pushed down (for the leftover degraded view).
fn applyModifications(arena: std.mem.Allocator, inst_doc: *const model.Document, src_docs: []model.Document, source_guid: []const u8) !AppliedSet {
    var applied: AppliedSet = .empty;
    const m = model.findValue(inst_doc.body.map, "m_Modification") orelse return applied;
    if (m.* != .map) return applied;
    const list = model.findValue(m.map, "m_Modifications") orelse return applied;
    if (list.* != .seq) return applied;
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar) continue;
        const target = model.findValue(item.map, "target") orelse continue;
        if (target.* != .ref) continue;
        const tguid = target.ref.guid orelse continue;
        if (!std.mem.eql(u8, tguid, source_guid)) continue;
        const value = model.findValue(item.map, "value");
        const obj_ref = objRefIfSet(model.findValue(item.map, "objectReference"));
        // objectReference if set, otherwise value (same rule as diff.zig's modValue).
        const eff = obj_ref orelse (value orelse continue);
        var handled = false;
        for (src_docs) |*d| {
            if (d.file_id != target.ref.file_id) continue;
            setByPropertyPath(d.body, pp.scalar, eff);
            handled = true;
            break;
        }
        if (!handled) handled = try pushDown(arena, src_docs, target.ref.file_id, pp, value, obj_ref);
        if (handled) try applied.put(arena, try diff_overrides.modKeyOf(arena, target.ref.file_id, pp.scalar), {});
    }
    return applied;
}

// Append the XOR-transformed mod to every instance doc. Only in the correct instance does the
// inner fileID match and get applied; others are pushed down recursively or surface as leftover rows
// (extra rows in a source with multiple instances are tolerated — safer than dropping information).
fn pushDown(arena: std.mem.Allocator, src_docs: []model.Document, target_id: i64, pp: *model.Node, value: ?*model.Node, obj_ref: ?*model.Node) !bool {
    var pushed = false;
    for (src_docs) |*d| {
        if (d.class_id != 1001 or d.stripped) continue;
        const pguid = sourceGuidOf(d) orelse continue;
        if (try appendMod(arena, d, target_id ^ d.file_id, pguid, pp, value, obj_ref)) pushed = true;
    }
    return pushed;
}

fn sourceGuidOf(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

fn appendMod(arena: std.mem.Allocator, pi_doc: *model.Document, inner_id: i64, pguid: []const u8, pp: *model.Node, value: ?*model.Node, obj_ref: ?*model.Node) !bool {
    const m = model.findValue(pi_doc.body.map, "m_Modification") orelse return false;
    if (m.* != .map) return false;
    const list = model.findValue(m.map, "m_Modifications") orelse return false;
    if (list.* != .seq) return false;
    const target = try arena.create(model.Node);
    target.* = .{ .ref = .{ .file_id = inner_id, .guid = pguid, .type_id = 3 } };
    var entries: std.ArrayList(model.Entry) = .empty;
    try entries.append(arena, .{ .key = "target", .value = target });
    try entries.append(arena, .{ .key = "propertyPath", .value = pp });
    if (value) |v| try entries.append(arena, .{ .key = "value", .value = v });
    if (obj_ref) |o| try entries.append(arena, .{ .key = "objectReference", .value = o });
    const item = try arena.create(model.Node);
    item.* = .{ .map = try entries.toOwnedSlice(arena) };
    const new_seq = try arena.alloc(*model.Node, list.seq.len + 1);
    @memcpy(new_seq[0..list.seq.len], list.seq);
    new_seq[list.seq.len] = item;
    list.seq = new_seq;
    return true;
}

fn objRefIfSet(n: ?*model.Node) ?*model.Node {
    const node = n orelse return null;
    return switch (node.*) {
        .ref => |r| if (r.file_id != 0 or r.guid != null) node else null,
        else => null,
    };
}

// Replace a leaf via a path like "m_LocalScale.y" / "m_Materials.Array.data[0]".
// Paths with a missing intermediate or a type mismatch are silently dropped (safe side, since this is display merging).
fn setByPropertyPath(body: *model.Node, path: []const u8, value: *model.Node) void {
    var cur: *model.Node = body;
    var it = std.mem.splitScalar(u8, path, '.');
    var pending: ?[]const u8 = it.next();
    while (pending) |seg| {
        const next = it.next();
        if (std.mem.eql(u8, seg, "Array")) {
            pending = next;
            continue; // Unity's virtual segment
        }
        if (std.mem.startsWith(u8, seg, "data[")) {
            const close = std.mem.indexOfScalar(u8, seg, ']') orelse return;
            const idx = std.fmt.parseInt(usize, seg["data[".len..close], 10) catch return;
            if (cur.* != .seq or idx >= cur.seq.len) return;
            if (next == null) {
                cur.seq[idx] = value;
                return;
            }
            cur = cur.seq[idx];
            pending = next;
            continue;
        }
        if (cur.* != .map) return;
        var advanced = false;
        for (cur.map) |*e| {
            if (!std.mem.eql(u8, e.key, seg)) continue;
            if (next == null) {
                e.value = value;
                return;
            }
            cur = e.value;
            advanced = true;
            break;
        }
        if (!advanced) return;
        pending = next;
    }
}

const testing = std.testing;
const root = @import("root.zig");

const test_source =
    \\--- !u!1 &10
    \\GameObject:
    \\  m_Name: Cyl
    \\  m_Component:
    \\  - component: {fileID: 40}
    \\--- !u!4 &40
    \\Transform:
    \\  m_GameObject: {fileID: 10}
    \\  m_LocalScale: {x: 1, y: 1, z: 1}
;

const test_variant =
    \\--- !u!1001 &1001
    \\PrefabInstance:
    \\  m_Modification:
    \\    m_Modifications:
    \\    - target: {fileID: 40, guid: srcguid, type: 3}
    \\      propertyPath: m_LocalScale.y
    \\      value: 2
    \\    - target: {fileID: 10, guid: srcguid, type: 3}
    \\      propertyPath: m_Name
    \\      value: Cyl Variant
    \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
;

test "instantiate: merged variant shows full source values with overrides applied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", test_source);
    const res = try root.diffBytesWithAssets(arena, "", test_variant, &assets);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqualStrings("Cyl Variant", inst.name);
    // Expansion succeeds: overrides empty, the source Transform appears as a component,
    // holding the override-applied Scale (1, 2, 1) in full enumeration.
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
    try testing.expectEqual(@as(usize, 0), inst.overrides.len);
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    const tr = inst.components[0];
    try testing.expectEqual(@as(u32, 4), tr.class_id);
    try testing.expectEqual(model.Status.added, tr.status);
    try testing.expectEqual(@as(usize, 1), tr.fields.len);
    try testing.expectEqualStrings("Scale", tr.fields[0].path);
    try testing.expectEqualStrings("(1, 2, 1)", tr.fields[0].after.?.scalar);
}

test "instantiate: missing asset degrades and reports neededSources with side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: Assets = .empty;

    // added direction: stays in the degraded view (full override enumeration), side is after.
    const added = try root.diffBytesWithAssets(arena, "", test_variant, &empty);
    try testing.expectEqual(@as(usize, 1), added.needed_sources.len);
    try testing.expectEqualStrings("srcguid", added.needed_sources[0].guid);
    try testing.expectEqual(model.SourceSide.after, added.needed_sources[0].side);
    try testing.expect(added.roots[0].overrides.len != 0);

    // removed direction: side is before.
    const removed = try root.diffBytesWithAssets(arena, test_variant, "", &empty);
    try testing.expectEqual(@as(usize, 1), removed.needed_sources.len);
    try testing.expectEqual(model.SourceSide.before, removed.needed_sources[0].side);
}

test "instantiate: cyclic source reference terminates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The source itself contains a PrefabInstance of the same guid (corrupt data).
    // Just verify the ancestor-chain cycle guard stops it and it doesn't land in needed either.
    const cyclic_source =
        \\--- !u!1001 &7
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: loopguid, type: 3}
    ;
    const variant =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: loopguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "loopguid", cyclic_source);
    const res = try root.diffBytesWithAssets(arena, "", variant, &assets);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
}

test "instantiate: unparseable source degrades to the override view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A broken source that reliably exceeds the parser's max_nesting_depth (128).
    var hostile: std.ArrayList(u8) = .empty;
    try hostile.appendSlice(arena, "--- !u!1 &1\nGameObject:\n");
    for (1..200) |depth| {
        try hostile.appendNTimes(arena, ' ', depth * 2);
        try hostile.appendSlice(arena, "a:\n");
    }
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", hostile.items);
    // The whole diff succeeds and the instance stays in the degraded view (overrides remain).
    const res = try root.diffBytesWithAssets(arena, "", test_variant, &assets);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expect(res.roots[0].overrides.len != 0);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
}

test "instantiate: removed components are dropped from the merged tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\--- !u!1 &10
        \\GameObject:
        \\  m_Name: Cyl
        \\  m_Component:
        \\  - component: {fileID: 40}
        \\  - component: {fileID: 50}
        \\--- !u!4 &40
        \\Transform:
        \\  m_GameObject: {fileID: 10}
        \\--- !u!65 &50
        \\BoxCollider:
        \\  m_GameObject: {fileID: 10}
        \\  m_IsTrigger: 0
    ;
    const variant =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_RemovedComponents:
        \\    - {fileID: 50, guid: srcguid, type: 3}
        \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", source);
    const res = try root.diffBytesWithAssets(arena, "", variant, &assets);
    const inst = res.roots[0];
    // BoxCollider (fileID 50) is removed: only the Transform remains.
    for (inst.components) |c| try testing.expect(c.class_id != 65);
}

test "instantiate: outer overrides push down through nested instances" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 3-level structure: outer -> variant (guid varguid) -> base (guid baseguid).
    // Unity references nested objects as "instance fileID XOR source fileID".
    // outer's mod targets base's Transform (&40) through the instance (&100) inside the variant:
    // target fileID = 100 ^ 40 = 76.
    const base =
        \\--- !u!1 &10
        \\GameObject:
        \\  m_Name: Base
        \\  m_Component:
        \\  - component: {fileID: 40}
        \\--- !u!4 &40
        \\Transform:
        \\  m_GameObject: {fileID: 10}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const variant =
        \\--- !u!1001 &100
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: baseguid, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\  m_SourcePrefab: {fileID: 100100000, guid: baseguid, type: 3}
    ;
    const outer =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 76, guid: varguid, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 9
        \\  m_SourcePrefab: {fileID: 100100000, guid: varguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "varguid", variant);
    try assets.put(arena, "baseguid", base);
    const res = try root.diffBytesWithAssets(arena, "", outer, &assets);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    // The single instance root collapses into the outer node, not a duplicate node.
    try testing.expectEqual(@as(usize, 0), inst.children.len);
    try testing.expectEqual(@as(usize, 0), inst.overrides.len);
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    // The outer override applies last, so 9 wins over the variant's 1.
    try testing.expectEqualStrings("Position", inst.components[0].fields[0].path);
    try testing.expectEqualStrings("(9, 0, 0)", inst.components[0].fields[0].after.?.scalar);
}

test "instantiate: pushed-down overrides win in the degraded view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Same 3-level structure as the push-down test, but the base-side asset is not supplied.
    // The inner instance falls into the degraded view, and the pushed-down outer value (9)
    // wins last over the variant's own value (1) and appears as a row.
    const variant =
        \\--- !u!1001 &100
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: baseguid, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\  m_SourcePrefab: {fileID: 100100000, guid: baseguid, type: 3}
    ;
    const outer =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 76, guid: varguid, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 9
        \\  m_SourcePrefab: {fileID: 100100000, guid: varguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "varguid", variant);
    const res = try root.diffBytesWithAssets(arena, "", outer, &assets);
    try testing.expectEqual(@as(usize, 1), res.needed_sources.len);
    try testing.expectEqualStrings("baseguid", res.needed_sources[0].guid);
    const inst = res.roots[0];
    try testing.expectEqual(@as(usize, 1), inst.overrides.len);
    try testing.expectEqualStrings("Position.x", inst.overrides[0].label);
    try testing.expectEqualStrings("9", inst.overrides[0].after.?.scalar);
}

test "instantiate: unappliable overrides stay visible as rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const variant =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: srcguid, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    - target: {fileID: 999, guid: otherguid, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 5
        \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", test_source);
    const res = try root.diffBytesWithAssets(arena, "", variant, &assets);
    const inst = res.roots[0];
    // Scale.y is applied to the merge. The unapplicable otherguid row is kept, not silently dropped.
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    try testing.expectEqualStrings("(1, 2, 1)", inst.components[0].fields[0].after.?.scalar);
    try testing.expectEqual(@as(usize, 1), inst.overrides.len);
    try testing.expectEqualStrings("Position.x", inst.overrides[0].label);
    try testing.expectEqualStrings("5", inst.overrides[0].after.?.scalar);
}

test "instantiate: setByPropertyPath handles nested and array paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try parser.parse(arena,
        \\--- !u!23 &5
        \\MeshRenderer:
        \\  m_Materials:
        \\  - {fileID: 2100000, guid: mat0, type: 2}
        \\  - {fileID: 2100000, guid: mat1, type: 2}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    );
    var value = model.Node{ .scalar = "9" };

    // Nested path.
    setByPropertyPath(docs[0].body, "m_LocalScale.y", &value);
    const scale = model.findValue(docs[0].body.map, "m_LocalScale").?;
    try testing.expectEqualStrings("9", model.findValue(scale.map, "y").?.scalar);

    // Array.data[i] path (leaf replacement).
    setByPropertyPath(docs[0].body, "m_Materials.Array.data[1]", &value);
    const mats = model.findValue(docs[0].body.map, "m_Materials").?;
    try testing.expectEqualStrings("9", mats.seq[1].scalar);

    // A missing path and an out-of-range index are no-ops (no panic).
    setByPropertyPath(docs[0].body, "m_Missing.x", &value);
    setByPropertyPath(docs[0].body, "m_Materials.Array.data[99]", &value);
}
