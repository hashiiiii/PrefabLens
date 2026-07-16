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
    try testing.expectEqualStrings("Max Hp", d.fields[0].path);
    try testing.expectEqual(model.Status.modified, d.fields[0].status);
    try testing.expectEqualStrings("100", d.fields[0].before.?.scalar);
    try testing.expectEqualStrings("150", d.fields[0].after.?.scalar);
}

test "diff: unknown classID falls back to the document top-level key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 999999 is an ID absent from ClassIDReference. A document that cannot be
    // resolved via the table is named by its top-level key.
    const before =
        \\--- !u!999999 &7
        \\MyCustomThing:
        \\  value: 1
    ;
    const after =
        \\--- !u!999999 &7
        \\MyCustomThing:
        \\  value: 2
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 7).?;
    try testing.expectEqualStrings("MyCustomThing", d.type_name);
    try testing.expectEqual(model.Status.modified, d.status);
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
    const removed = findDoc(fd2, 2).?;
    try testing.expectEqual(model.Status.removed, removed.status);
    // Removed side enumerates fully too: the Name visible in the hierarchy remains with its before value.
    try testing.expectEqual(@as(usize, 1), removed.fields.len);
    try testing.expectEqualStrings("Name", removed.fields[0].path);
    try testing.expectEqualStrings("B", removed.fields[0].before.?.scalar);
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
    // Expect: the modified leaf (m_LocalPosition.y) plus the added m_LocalScale
    // collapsed as a vector into a single "Scale" row.
    var saw_y = false;
    var saw_added_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Position.y")) {
            saw_y = true;
            try testing.expectEqual(model.Status.modified, f.status);
            try testing.expectEqualStrings("0", f.before.?.scalar);
            try testing.expectEqualStrings("5", f.after.?.scalar);
        }
        if (std.mem.eql(u8, f.path, "Scale")) {
            saw_added_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
            try testing.expectEqualStrings("(1, 1, 1)", f.after.?.scalar);
        }
    }
    try testing.expect(saw_y and saw_added_scale);
}

test "diff: duplicate before fileIDs match the first occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A malformed anchor makes the parser drop file_id to 0, so duplicates do
    // actually occur. The linear scan before the index was introduced matched the
    // "first" document, so that semantics must be preserved.
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 100
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 999
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 150
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 5).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    // First occurrence wins: before is 100, not the duplicate's 999.
    try testing.expectEqualStrings("100", d.fields[0].before.?.scalar);
    try testing.expectEqualStrings("150", d.fields[0].after.?.scalar);
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
    // Both aaaa and bbbb are referenced external guids, so both appear.
    var saw_a = false;
    var saw_b = false;
    for (fd.unresolved_guids) |g| {
        if (std.mem.eql(u8, g, "aaaa")) saw_a = true;
        if (std.mem.eql(u8, g, "bbbb")) saw_b = true;
    }
    try testing.expect(saw_a and saw_b);
}

test "diff: stripped documents are excluded from docs but kept in before/after" {
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
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 99}
    ;
    const fd = try compute(arena, before, after);
    try testing.expect(findDoc(fd, 42) == null);
    // Retained in the after array for structural resolution.
    var found = false;
    for (fd.after) |d| if (d.file_id == 42) {
        found = true;
        try testing.expect(d.stripped);
    };
    try testing.expect(found);
}

test "diff: removed stripped documents are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 99}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const fd = try compute(arena, before, after);
    // A stripped doc is a shadow of the instance's real object, so its removal is not a removed row.
    try testing.expect(findDoc(fd, 42) == null);
}

test "diff: hidden fields are dropped and paths humanized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_LocalPosition: {x: 1, y: 0, z: 0}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    // The m_GameObject change is hidden. m_LocalPosition.x becomes "Position.x".
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    try testing.expectEqualStrings("Position.x", d.fields[0].path);
}

test "diff: hidden-only changes leave the document unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 90, z: 0}
    ;
    const fd = try compute(arena, before, after);
    try testing.expectEqual(model.Status.unchanged, findDoc(fd, 4).?.status);
}

test "diff: editor class identifier tail is extracted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const src2 =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const fd = try compute(arena, src, src2);
    try testing.expectEqualStrings("Cylinder1", findDoc(fd, 5).?.class_name.?);
}

test "diff: editor class identifier without separator or with empty tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Cylinder1
        \\--- !u!114 &6
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::
    ;
    const fd = try compute(arena, src, src);
    // No separator uses the whole string as the class name; an empty tail means no class_name.
    try testing.expectEqualStrings("Cylinder1", findDoc(fd, 5).?.class_name.?);
    try testing.expect(findDoc(fd, 6).?.class_name == null);
}

test "diff: unresolved guids are deduplicated in first-reference order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbb, type: 3}
        \\--- !u!114 &6
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: aaa, type: 3}
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbb, type: 3}
    ;
    const fd = try compute(arena, "", after);
    // Duplicate bbb appears once, in first-reference order (bbb, aaa).
    // The deterministic order of JSON unresolvedGuids/resolved depends on this.
    try testing.expectEqual(@as(usize, 2), fd.unresolved_guids.len);
    try testing.expectEqualStrings("bbb", fd.unresolved_guids[0]);
    try testing.expectEqualStrings("aaa", fd.unresolved_guids[1]);
}

test "diff: added document enumerates fields with vector collapse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "";
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 4, y: 0, z: 0}
        \\  maxHp: 100
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.added, d.status);
    // m_GameObject is hidden. Position is a single vector row, maxHp is Max Hp.
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
}

test "diff: removed document enumerates fields with vector collapse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 4, y: 0, z: 0}
        \\  maxHp: 100
    ;
    const fd = try compute(arena, before, "");
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.removed, d.status);
    // Symmetric with the added side: m_GameObject hidden, Position a single vector row, values on before.
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqual(model.Status.removed, d.fields[0].status);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].before.?.scalar);
    try testing.expect(d.fields[0].after == null);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
    try testing.expectEqualStrings("100", d.fields[1].before.?.scalar);
}

const parser = @import("parser.zig");
const classid = @import("classid.zig");
const inspector = @import("inspector.zig");
const diff_overrides = @import("diff_overrides.zig");
const Node = model.Node;
const Status = model.Status;
const FieldDiff = model.FieldDiff;

// Re-exported for instantiate, which reaches the override helpers through this module.
pub const modKeyOf = diff_overrides.modKeyOf;
pub const soleInstanceOverridesSkipping = diff_overrides.soleInstanceOverridesSkipping;

pub const DocDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
    overrides: []model.OverrideDiff = &.{},
};

pub const FlatDiff = struct {
    docs: []DocDiff,
    unresolved_guids: [][]const u8,
    before: []model.Document,
    after: []model.Document,
};

fn buildIndex(arena: std.mem.Allocator, docs: []model.Document) !std.AutoHashMap(i64, *model.Document) {
    var idx = std.AutoHashMap(i64, *model.Document).init(arena);
    try idx.ensureTotalCapacity(@intCast(docs.len));
    for (docs) |*d| {
        // Duplicate fileIDs: first occurrence wins (happens with malformed anchors).
        // Same semantics as the linear scan before the index was introduced.
        const gop = idx.getOrPutAssumeCapacity(d.file_id);
        if (!gop.found_existing) gop.value_ptr.* = d;
    }
    return idx;
}

fn scriptGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_Script") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

// "Assembly-CSharp::Cylinder1" -> "Cylinder1" (after the last ':').
fn editorClassName(doc: *const model.Document) ?[]const u8 {
    const v = model.findValue(doc.body.map, "m_EditorClassIdentifier") orelse return null;
    const s = switch (v.*) {
        .scalar => |s| s,
        else => return null,
    };
    const tail = if (std.mem.lastIndexOfScalar(u8, s, ':')) |idx| s[idx + 1 ..] else s;
    return if (tail.len != 0) tail else null;
}

// Drop Inspector-hidden entries from the raw field diff and replace path with the display name.
fn presentFields(arena: std.mem.Allocator, raw: []FieldDiff) ![]FieldDiff {
    var kept: std.ArrayList(FieldDiff) = .empty;
    for (raw) |f| {
        if (inspector.isHidden(f.path)) continue;
        var out = f;
        out.path = try inspector.displayPath(arena, f.path);
        try kept.append(arena, out);
    }
    return kept.toOwnedSlice(arena);
}

fn resolvedTypeName(doc: *const model.Document) []const u8 {
    if (classid.typeName(doc.class_id)) |n| return n;
    // Unknown classID falls back to the document's own top-level key.
    return doc.type_name;
}

pub fn compute(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !FlatDiff {
    const before = try parser.parse(arena, before_src);
    const after = try parser.parse(arena, after_src);
    return computeParsed(arena, before, after);
}

// Diff an already-parsed document list (instantiate feeds in mutated docs).
pub fn computeParsed(arena: std.mem.Allocator, before: []model.Document, after: []model.Document) !FlatDiff {
    var docs: std.ArrayList(DocDiff) = .empty;
    // The array hash map preserves first-insertion order, so unresolvedGuids
    // serializes deterministically in reference order.
    var guids: std.StringArrayHashMapUnmanaged(void) = .empty;

    // fileID -> *Document index. Makes the subsequent union walk O(n) instead of
    // an O(n^2) linear scan (matters at scene scale of tens of thousands of docs).
    var before_idx = try buildIndex(arena, before);
    var after_idx = try buildIndex(arena, after);

    // Walk the union of file_ids: first `after` in order (preserving after's order),
    // then process documents that exist only in `before`.
    for (after) |*ad| {
        if (ad.stripped) continue;
        try collectGuids(arena, &guids, ad.body);
        const bd = before_idx.get(ad.file_id);
        if (bd) |b| {
            try collectGuids(arena, &guids, b.body);
            if (ad.class_id == 1001) {
                const overrides = try diff_overrides.diffOverrides(arena, b, ad);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = if (overrides.len == 0) .unchanged else .modified,
                    .fields = &.{},
                    .overrides = overrides,
                });
            } else {
                var raw: std.ArrayList(FieldDiff) = .empty;
                try diffNode(arena, &raw, "", b.body, ad.body);
                const fields = try presentFields(arena, raw.items);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .class_name = editorClassName(ad),
                    .status = if (fields.len == 0) .unchanged else .modified,
                    .fields = fields,
                });
            }
        } else {
            if (ad.class_id == 1001) {
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = .added,
                    .fields = &.{},
                    .overrides = try diff_overrides.soleInstanceOverrides(arena, ad, .added),
                });
            } else {
                var raw: std.ArrayList(FieldDiff) = .empty;
                for (ad.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .added);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .class_name = editorClassName(ad),
                    .status = .added,
                    .fields = try presentFields(arena, raw.items),
                });
            }
        }
    }
    for (before) |*bd| {
        if (bd.stripped) continue;
        if (after_idx.contains(bd.file_id)) continue;
        try collectGuids(arena, &guids, bd.body);
        if (bd.class_id == 1001) {
            try docs.append(arena, .{
                .file_id = bd.file_id,
                .class_id = bd.class_id,
                .type_name = resolvedTypeName(bd),
                .script_guid = scriptGuid(bd),
                .class_name = editorClassName(bd),
                .status = .removed,
                .fields = &.{},
                .overrides = try diff_overrides.soleInstanceOverrides(arena, bd, .removed),
            });
        } else {
            // Full enumeration symmetric with the added side (flattenSubtree ~ presentFields).
            var raw: std.ArrayList(FieldDiff) = .empty;
            for (bd.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .removed);
            try docs.append(arena, .{
                .file_id = bd.file_id,
                .class_id = bd.class_id,
                .type_name = resolvedTypeName(bd),
                .script_guid = scriptGuid(bd),
                .class_name = editorClassName(bd),
                .status = .removed,
                .fields = try presentFields(arena, raw.items),
            });
        }
    }

    return .{
        .docs = try docs.toOwnedSlice(arena),
        .unresolved_guids = guids.keys(),
        .before = before,
        .after = after,
    };
}

// Recursive field diff. `prefix` is the dot/index-separated path into `a`/`b`.
fn diffNode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: *const Node,
    b: *const Node,
) anyerror!void {
    // Recurse if the same kind.
    if (a.* == .map and b.* == .map) {
        try diffMap(arena, out, prefix, a.map, b.map);
        return;
    }
    if (a.* == .seq and b.* == .seq) {
        try diffSeq(arena, out, prefix, a.seq, b.seq);
        return;
    }
    // Leaf (scalar/ref) or a change of kind.
    if (!Node.eql(a, b)) {
        try out.append(arena, .{ .path = prefix, .status = .modified, .before = a, .after = b });
    }
}

fn diffMap(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: []model.Entry,
    b: []model.Entry,
) anyerror!void {
    // Keys in a: modified/removed or recurse
    for (a) |ea| {
        const path = try joinKey(arena, prefix, ea.key);
        if (model.findValue(b, ea.key)) |bv| {
            try diffNode(arena, out, path, ea.value, bv);
        } else {
            try flattenSubtree(arena, out, path, ea.value, .removed);
        }
    }
    // Keys only in b: added
    for (b) |eb| {
        if (model.findValue(a, eb.key) == null) {
            const path = try joinKey(arena, prefix, eb.key);
            try flattenSubtree(arena, out, path, eb.value, .added);
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
    for (a[0..n], b[0..n], 0..) |ea, eb, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try diffNode(arena, out, path, ea, eb);
    }
    for (a[n..], n..) |ea, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, ea, .removed);
    }
    for (b[n..], n..) |eb, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, eb, .added);
    }
}

fn joinKey(arena: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]const u8 {
    if (prefix.len == 0) return key;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
}

fn isVectorMap(entries: []model.Entry) bool {
    if (entries.len < 2 or entries.len > 4) return false;
    for (entries) |e| {
        if (e.value.* != .scalar) return false;
        if (e.key.len != 1) return false;
        if (std.mem.indexOfScalar(u8, "xyzwrgba", e.key[0]) == null) return false;
    }
    return true;
}

// Synthesized scalar Node of the form "(a, b, c)" (for single-row display like "Position: (2, 3, 1)").
// pub: diff_overrides synthesizes its placement summary rows with it too.
pub fn parenJoinNode(arena: std.mem.Allocator, vals: []const []const u8) !*Node {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '(');
    for (vals, 0..) |v, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, v);
    }
    try out.append(arena, ')');
    const n = try arena.create(Node);
    n.* = .{ .scalar = try out.toOwnedSlice(arena) };
    return n;
}

fn vectorNode(arena: std.mem.Allocator, entries: []model.Entry) !*Node {
    var vals: [4][]const u8 = undefined;
    for (entries, 0..) |e, i| vals[i] = e.value.scalar;
    return parenJoinNode(arena, vals[0..entries.len]);
}

fn appendLeaf(arena: std.mem.Allocator, out: *std.ArrayList(FieldDiff), path: []const u8, status: Status, node: *const Node) !void {
    try out.append(arena, switch (status) {
        .added => .{ .path = path, .status = .added, .before = null, .after = node },
        .removed => .{ .path = path, .status = .removed, .before = node, .after = null },
        else => unreachable,
    });
}

// Expand an added/removed subtree into leaves. A vector-like map collapses to one row.
fn flattenSubtree(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    node: *const Node,
    status: Status,
) anyerror!void {
    switch (node.*) {
        .map => |entries| {
            if (isVectorMap(entries)) {
                try appendLeaf(arena, out, prefix, status, try vectorNode(arena, entries));
                return;
            }
            for (entries) |e| try flattenSubtree(arena, out, try joinKey(arena, prefix, e.key), e.value, status);
        },
        .seq => |items| for (items, 0..) |it, i| {
            const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
            try flattenSubtree(arena, out, path, it, status);
        },
        else => try appendLeaf(arena, out, prefix, status, node),
    }
}

// ---- guid collection ----

fn collectGuids(arena: std.mem.Allocator, set: *std.StringArrayHashMapUnmanaged(void), node: *const Node) anyerror!void {
    switch (node.*) {
        .ref => |r| if (r.guid) |g| try set.put(arena, g, {}),
        .map => |entries| for (entries) |e| try collectGuids(arena, set, e.value),
        .seq => |items| for (items) |it| try collectGuids(arena, set, it),
        .scalar => {},
    }
}
