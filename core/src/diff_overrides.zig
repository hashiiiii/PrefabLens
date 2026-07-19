// PrefabInstance override diff: m_Modifications rows keyed by target+propertyPath,
// plus placement/structural summaries for instances present on only one side.
const std = @import("std");
const model = @import("model.zig");
const inspector = @import("inspector.zig");
const diffmod = @import("diff.zig");
const testing = std.testing;

const Node = model.Node;
const Status = model.Status;

const findDoc = diffmod.findDoc;

test "diff: sortByGroup keeps same-group rows contiguous beyond known ranks" {
    // The renderer relies on "rows of the same group are contiguous" as a core invariant.
    // Pin directly that this holds even if groupOf returns a fourth group name in the future.
    var rows = [_]model.OverrideDiff{
        .{ .group = "Overrides", .label = "a", .status = .added, .before = null, .after = null },
        .{ .group = "Custom", .label = "b", .status = .added, .before = null, .after = null },
        .{ .group = "Overrides", .label = "c", .status = .added, .before = null, .after = null },
    };
    sortByGroup(&rows);
    try testing.expectEqualStrings("Custom", rows[0].group);
    try testing.expectEqualStrings("Overrides", rows[1].group);
    try testing.expectEqualStrings("Overrides", rows[2].group);
    // Relative order within a group is stable (a before c).
    try testing.expectEqualStrings("a", rows[1].label);
    try testing.expectEqualStrings("c", rows[2].label);
}

test "diff: prefab instance override keyed by target+propertyPath" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 0.41646004
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    // Reorder while changing only x: reordering is not a diff.
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 0), d.fields.len);
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position.x", d.overrides[0].label);
    try testing.expectEqualStrings("0.41646004", d.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("1", d.overrides[0].after.?.scalar);
}

test "diff: modified instance overrides are sorted group-contiguous, Transform first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: rangeMin
        \\      value: 1
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 0
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 100
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    // Raw YAML order is Overrides, Transform, Overrides: input with non-contiguous groups.
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: rangeMin
        \\      value: 2
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 5
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 150
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 3), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Overrides", d.overrides[1].group);
    try testing.expectEqualStrings("Overrides", d.overrides[2].group);
    // Within Overrides, keep the original relative order (rangeMin before maxHp).
    try testing.expectEqualStrings("Range Min", d.overrides[1].label);
    try testing.expectEqualStrings("Max Hp", d.overrides[2].label);
}

test "diff: added prefab instance emits placement summary rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 2.03
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.y
        \\      value: 3.63
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.z
        \\      value: 1.11797
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.w
        \\      value: 1
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.x
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.y
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.z
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalEulerAnglesHint.x
        \\      value: 0
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.added, d.status);
    // Recorded placement is emitted as a single synthesized row even at default values (identity Rotation).
    // EulerAnglesHint (hidden in Inspector) and m_Name (absorbed into the node name) are not emitted.
    try testing.expectEqual(@as(usize, 2), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position", d.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", d.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Transform", d.overrides[1].group);
    try testing.expectEqualStrings("Rotation", d.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", d.overrides[1].after.?.scalar);
}

test "diff: added prefab instance keeps partial scale override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Scale.y", d.overrides[0].label);
    try testing.expectEqualStrings("2", d.overrides[0].after.?.scalar);
}

test "diff: removed prefab instance mirrors overrides to before" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 55}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, before, "");
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.removed, d.status);
    // Mirror of added: values on the before side, structural summary removed with the before-side count.
    try testing.expectEqual(@as(usize, 2), d.overrides.len);
    try testing.expectEqualStrings("Scale.y", d.overrides[0].label);
    try testing.expectEqual(model.Status.removed, d.overrides[0].status);
    try testing.expectEqualStrings("2", d.overrides[0].before.?.scalar);
    try testing.expect(d.overrides[0].after == null);
    try testing.expectEqualStrings("Added Components (1)", d.overrides[1].label);
    try testing.expectEqual(model.Status.removed, d.overrides[1].status);
}

test "diff: non-empty added components produce a summary row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 55}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try diffmod.compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Overrides", d.overrides[0].group);
    try testing.expectEqualStrings("Added Components (1)", d.overrides[0].label);
}

const Mod = struct { target: i64, path: []const u8, value: ?*Node, obj_ref: ?*Node };

fn collectMods(arena: std.mem.Allocator, doc: *const model.Document) ![]Mod {
    var mods: std.ArrayList(Mod) = .empty;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return mods.toOwnedSlice(arena);
    if (m.* != .map) return mods.toOwnedSlice(arena);
    const list = model.findValue(m.map, "m_Modifications") orelse return mods.toOwnedSlice(arena);
    if (list.* != .seq) return mods.toOwnedSlice(arena);
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar) continue;
        const target: i64 = blk: {
            const t = model.findValue(item.map, "target") orelse break :blk 0;
            break :blk switch (t.*) {
                .ref => |r| r.file_id,
                else => 0,
            };
        };
        try mods.append(arena, .{
            .target = target,
            .path = pp.scalar,
            .value = model.findValue(item.map, "value"),
            .obj_ref = objRefIfSet(model.findValue(item.map, "objectReference")),
        });
    }
    return mods.toOwnedSlice(arena);
}

fn objRefIfSet(n: ?*Node) ?*Node {
    const node = n orelse return null;
    return switch (node.*) {
        .ref => |r| if (r.file_id != 0 or r.guid != null) node else null,
        else => null,
    };
}

// objectReference if set, otherwise value.
fn modValue(m: Mod) ?*Node {
    return m.obj_ref orelse m.value;
}

// Mod identity key shared with instantiate (target fileID + propertyPath).
pub fn modKeyOf(arena: std.mem.Allocator, target: i64, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}:{s}", .{ target, path });
}

fn modKey(arena: std.mem.Allocator, m: Mod) ![]const u8 {
    return modKeyOf(arena, m.target, m.path);
}

fn nodeEqlOpt(a: ?*const Node, b: ?*const Node) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return Node.eql(a.?, b.?);
}

fn makeOverride(arena: std.mem.Allocator, property_path: []const u8, status: Status, before: ?*const Node, after: ?*const Node) !model.OverrideDiff {
    return .{
        .group = inspector.groupOf(property_path),
        .label = try inspector.displayPath(arena, property_path),
        .status = status,
        .before = before,
        .after = after,
    };
}

pub fn diffOverrides(arena: std.mem.Allocator, before_doc: ?*const model.Document, after_doc: *const model.Document) ![]model.OverrideDiff {
    var out: std.ArrayList(model.OverrideDiff) = .empty;
    const after_mods = try collectMods(arena, after_doc);
    const before_mods: []Mod = if (before_doc) |bd| try collectMods(arena, bd) else &.{};

    var before_map = std.StringHashMap(Mod).init(arena);
    for (before_mods) |m| try before_map.put(try modKey(arena, m), m);

    var seen = std.StringHashMap(void).init(arena);
    for (after_mods) |am| {
        const key = try modKey(arena, am);
        try seen.put(key, {});
        if (inspector.isHidden(am.path)) continue;
        const av: ?*const Node = modValue(am);
        if (before_map.get(key)) |bm| {
            const bv: ?*const Node = modValue(bm);
            if (nodeEqlOpt(bv, av)) continue;
            try out.append(arena, try makeOverride(arena, am.path, .modified, bv, av));
        } else {
            try out.append(arena, try makeOverride(arena, am.path, .added, null, av));
        }
    }
    // removed: deterministic in before-side order.
    for (before_mods) |bm| {
        if (seen.contains(try modKey(arena, bm))) continue;
        if (inspector.isHidden(bm.path)) continue;
        try out.append(arena, try makeOverride(arena, bm.path, .removed, modValue(bm), null));
    }
    try appendStructuralSummaries(arena, &out, before_doc, after_doc);
    sortByGroup(out.items);
    return out.toOwnedSlice(arena);
}

// Stable sort by group (Transform → GameObject → Overrides).
// The renderer emits headings assuming rows of the same group are contiguous, so
// rebundle the raw m_Modifications order by group.
fn groupRank(group: []const u8) u2 {
    if (std.mem.eql(u8, group, "Transform")) return 0;
    if (std.mem.eql(u8, group, "GameObject")) return 1;
    return 2;
}

fn sortByGroup(overrides: []model.OverrideDiff) void {
    const Ctx = struct {
        fn lessThan(_: void, a: model.OverrideDiff, b: model.OverrideDiff) bool {
            const ra = groupRank(a.group);
            const rb = groupRank(b.group);
            if (ra != rb) return ra < rb;
            // Equal rank (catch-all) tie-breaks by group name, keeping same-group
            // contiguity even as groupOf gains unknown group names.
            return std.mem.order(u8, a.group, b.group) == .lt;
        }
    };
    std.sort.block(model.OverrideDiff, overrides, {}, Ctx.lessThan);
}

const Placement = struct { prefix: []const u8, label: []const u8, comps: []const []const u8 };
const placements = [_]Placement{
    .{ .prefix = "m_LocalPosition", .label = "Position", .comps = &.{ "x", "y", "z" } },
    .{ .prefix = "m_LocalRotation", .label = "Rotation", .comps = &.{ "x", "y", "z", "w" } },
    .{ .prefix = "m_LocalScale", .label = "Scale", .comps = &.{ "x", "y", "z" } },
};

fn scalarOf(n: ?*Node) ?[]const u8 {
    const node = n orelse return null;
    return switch (node.*) {
        .scalar => |s| s,
        else => null,
    };
}

fn findMod(mods: []Mod, path: []const u8) ?Mod {
    for (mods) |m| if (std.mem.eql(u8, m.path, path)) return m;
    return null;
}

// Full override enumeration for an instance present on only one side (added/removed).
// Values go on after if added, on before if removed.
pub fn soleInstanceOverrides(arena: std.mem.Allocator, doc: *const model.Document, status: Status) ![]model.OverrideDiff {
    return soleOverridesFromMods(arena, doc, try dedupModsLastWins(arena, try collectMods(arena, doc)), status);
}

// Collapse duplicate (target, propertyPath) to one, last-wins (display position is the first occurrence). Real files
// have no duplicates, but instantiate's push-down appends the outer mod at the tail, so
// align the degraded view with the same "outer wins" semantics as application.
fn dedupModsLastWins(arena: std.mem.Allocator, mods: []Mod) ![]Mod {
    var map: std.StringArrayHashMapUnmanaged(Mod) = .empty;
    for (mods) |m| try map.put(arena, try modKey(arena, m), m);
    var out: std.ArrayList(Mod) = .empty;
    for (map.values()) |m| try out.append(arena, m);
    return out.toOwnedSlice(arena);
}

// Leftover rows of an expanded instance (for instantiate): drop mods applied to the
// synthesis, keep only the unapplied ones in the usual degraded view (don't drop silently).
pub fn soleInstanceOverridesSkipping(arena: std.mem.Allocator, doc: *const model.Document, status: Status, applied: *const std.StringHashMapUnmanaged(void)) ![]model.OverrideDiff {
    const all = try dedupModsLastWins(arena, try collectMods(arena, doc));
    var kept: std.ArrayList(Mod) = .empty;
    for (all) |m| {
        if (applied.contains(try modKey(arena, m))) continue;
        try kept.append(arena, m);
    }
    return soleOverridesFromMods(arena, doc, kept.items, status);
}

fn soleOverridesFromMods(arena: std.mem.Allocator, doc: *const model.Document, mods: []Mod, status: Status) ![]model.OverrideDiff {
    var out: std.ArrayList(model.OverrideDiff) = .empty;

    // Placement summary: a single synthesized row if all components are present.
    var consumed = [_]bool{false} ** placements.len;
    for (placements, 0..) |p, pi| {
        var vals: [4][]const u8 = undefined;
        var all = true;
        for (p.comps, 0..) |c, i| {
            const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ p.prefix, c });
            const m = findMod(mods, path) orelse {
                all = false;
                break;
            };
            const v = scalarOf(m.value) orelse {
                all = false;
                break;
            };
            vals[i] = v;
        }
        if (!all) continue;
        consumed[pi] = true;
        const n = try diffmod.parenJoinNode(arena, vals[0..p.comps.len]);
        try out.append(arena, .{
            .group = "Transform",
            .label = p.label,
            .status = status,
            .before = if (status == .removed) n else null,
            .after = if (status == .added) n else null,
        });
    }

    for (mods) |m| {
        if (inspector.isHidden(m.path)) continue;
        if (std.mem.eql(u8, m.path, "m_Name")) continue; // absorbed into the node name
        const in_consumed = blk: {
            for (placements, 0..) |p, pi| {
                if (consumed[pi] and std.mem.startsWith(u8, m.path, p.prefix) and
                    m.path.len > p.prefix.len and m.path[p.prefix.len] == '.') break :blk true;
            }
            break :blk false;
        };
        if (in_consumed) continue;
        const v = modValue(m);
        try out.append(arena, try makeOverride(
            arena,
            m.path,
            status,
            if (status == .removed) v else null,
            if (status == .added) v else null,
        ));
    }
    if (status == .added) {
        try appendStructuralSummaries(arena, &out, null, doc);
    } else {
        try appendStructuralSummaries(arena, &out, doc, null);
    }
    sortByGroup(out.items);
    return out.toOwnedSlice(arena);
}

fn modificationSeqLen(doc: *const model.Document, key: []const u8) usize {
    const m = model.findValue(doc.body.map, "m_Modification") orelse return 0;
    if (m.* != .map) return 0;
    const v = model.findValue(m.map, key) orelse return 0;
    return switch (v.*) {
        .seq => |s| s.len,
        else => 0,
    };
}

// Full expansion of m_Added*/m_Removed* is out of scope. A single count-summary row prevents information from silently vanishing.
fn appendStructuralSummaries(arena: std.mem.Allocator, out: *std.ArrayList(model.OverrideDiff), before_doc: ?*const model.Document, after_doc: ?*const model.Document) !void {
    const keys = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "m_AddedGameObjects", .label = "Added GameObjects" },
        .{ .key = "m_AddedComponents", .label = "Added Components" },
        .{ .key = "m_RemovedComponents", .label = "Removed Components" },
        .{ .key = "m_RemovedGameObjects", .label = "Removed GameObjects" },
    };
    for (keys) |e| {
        const alen = if (after_doc) |ad| modificationSeqLen(ad, e.key) else 0;
        const blen = if (before_doc) |bd| modificationSeqLen(bd, e.key) else 0;
        if (alen == blen) continue;
        // Count from the surviving side: if the whole instance is removed, emit the before count.
        const count = if (after_doc != null) alen else blen;
        try out.append(arena, .{
            .group = "Overrides",
            .label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ e.label, count }),
            .status = if (alen > blen) .added else .removed,
            .before = null,
            .after = null,
        });
    }
}
