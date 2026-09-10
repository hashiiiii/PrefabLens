// PrefabInstance override diff: m_Modifications rows keyed by target+propertyPath,
// plus placement/structural summaries for instances present on only one side.
const std = @import("std");
const model = @import("model.zig");
const inspector = @import("inspector.zig");
const prefab = @import("prefab.zig");
const testing = std.testing;

const Node = model.Node;
const Status = model.Status;

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
    const diffmod = @import("diff.zig");
    const fd = try diffmod.compute(arena, before, after);
    const d = diffmod.findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.component.status);
    try testing.expectEqual(@as(usize, 3), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Overrides", d.overrides[1].group);
    try testing.expectEqualStrings("Overrides", d.overrides[2].group);
    // Within Overrides, keep the original relative order (rangeMin before maxHp).
    try testing.expectEqualStrings("Range Min", d.overrides[1].label);
    try testing.expectEqualStrings("Max Hp", d.overrides[2].label);
}

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

const Mod = prefab.Modification;

fn collectMods(arena: std.mem.Allocator, doc: *const model.Document) ![]Mod {
    var mods: std.ArrayList(Mod) = .empty;
    var iterator = prefab.modifications(doc);
    while (iterator.next()) |modification| try mods.append(arena, modification);
    return mods.toOwnedSlice(arena);
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
    for (before_mods) |m| try before_map.put(try m.key(arena), m);

    var seen = std.StringHashMap(void).init(arena);
    for (after_mods) |am| {
        const key = try am.key(arena);
        try seen.put(key, {});
        if (inspector.isHidden(am.property_path)) continue;
        const av: ?*const Node = am.effectiveValue();
        if (before_map.get(key)) |bm| {
            const bv: ?*const Node = bm.effectiveValue();
            if (nodeEqlOpt(bv, av)) continue;
            if (std.mem.eql(u8, am.property_path, "m_Name") and !inspector.shouldEmitNameOverride(.modified, bv, av)) continue;
            try out.append(arena, try makeOverride(arena, am.property_path, .modified, bv, av));
        } else {
            if (std.mem.eql(u8, am.property_path, "m_Name") and !inspector.shouldEmitNameOverride(.added, null, av)) continue;
            try out.append(arena, try makeOverride(arena, am.property_path, .added, null, av));
        }
    }
    // removed: deterministic in before-side order.
    for (before_mods) |bm| {
        if (seen.contains(try bm.key(arena))) continue;
        if (inspector.isHidden(bm.property_path)) continue;
        const bv = bm.effectiveValue();
        if (std.mem.eql(u8, bm.property_path, "m_Name") and !inspector.shouldEmitNameOverride(.removed, bv, null)) continue;
        try out.append(arena, try makeOverride(arena, bm.property_path, .removed, bv, null));
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

fn findMod(mods: []Mod, path: []const u8) ?Mod {
    for (mods) |m| if (std.mem.eql(u8, m.property_path, path)) return m;
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
    for (mods) |m| try map.put(arena, try m.key(arena), m);
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
        if (applied.contains(try m.key(arena))) continue;
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
            const v = Node.asScalar(m.value) orelse {
                all = false;
                break;
            };
            vals[i] = v;
        }
        if (!all) continue;
        consumed[pi] = true;
        const n = try inspector.joinedScalarNode(arena, vals[0..p.comps.len]);
        try out.append(arena, .{
            .group = "Transform",
            .label = p.label,
            .status = status,
            .before = if (status == .removed) n else null,
            .after = if (status == .added) n else null,
        });
    }

    for (mods) |m| {
        if (inspector.isHidden(m.property_path)) continue;
        const v = m.effectiveValue();
        if (std.mem.eql(u8, m.property_path, "m_Name") and !inspector.shouldEmitNameOverride(
            status,
            if (status == .removed) v else null,
            if (status == .added) v else null,
        )) continue;
        const in_consumed = blk: {
            for (placements, 0..) |p, pi| {
                if (consumed[pi] and std.mem.startsWith(u8, m.property_path, p.prefix) and
                    m.property_path.len > p.prefix.len and m.property_path[p.prefix.len] == '.') break :blk true;
            }
            break :blk false;
        };
        if (in_consumed) continue;
        try out.append(arena, try makeOverride(
            arena,
            m.property_path,
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
    const m = doc.body.get("m_Modification") orelse return 0;
    if (m.* != .map) return 0;
    const v = m.get(key) orelse return 0;
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
