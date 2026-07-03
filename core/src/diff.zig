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
        if (std.mem.eql(u8, f.path, "Position.y")) {
            saw_y = true;
            try testing.expectEqual(model.Status.modified, f.status);
            try testing.expectEqualStrings("0", f.before.?.scalar);
            try testing.expectEqualStrings("5", f.after.?.scalar);
        }
        if (std.mem.startsWith(u8, f.path, "Scale")) {
            saw_added_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
        }
    }
    try testing.expect(saw_y and saw_added_scale);
}

test "diff: duplicate before fileIDs match the first occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Malformed anchors default file_id to 0 in the parser, so genuine
    // duplicates occur; the linear scan this index replaced matched the
    // FIRST document, and that semantics must be preserved.
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
    // First occurrence wins: before must be 100, not the duplicate's 999.
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
    // Both aaaa and bbbb are external guids referenced; both should appear.
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
    // 構造解決用に after 配列には残る。
    var found = false;
    for (fd.after) |d| if (d.file_id == 42) {
        found = true;
        try testing.expect(d.stripped);
    };
    try testing.expect(found);
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
    // m_GameObject の変更は非表示。m_LocalPosition.x は "Position.x" に。
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
    // m_GameObject は非表示。Position はベクトル 1 行、maxHp は Max Hp。
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
}

test "diff: added map field inside a modified document is flattened" {
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
    var saw_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Scale")) {
            saw_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
            try testing.expectEqualStrings("(1, 1, 1)", f.after.?.scalar);
        }
    }
    try testing.expect(saw_scale);
}

const parser = @import("parser.zig");
const classid = @import("classid.zig");
const inspector = @import("inspector.zig");
const Node = model.Node;
const Status = model.Status;
const FieldDiff = model.FieldDiff;

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
        // First occurrence wins on duplicate fileIDs, matching the linear
        // scan this index replaced (duplicates occur with malformed anchors).
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

/// "Assembly-CSharp::Cylinder1" -> "Cylinder1"(最後の ':' より後)。
fn editorClassName(doc: *const model.Document) ?[]const u8 {
    const v = model.findValue(doc.body.map, "m_EditorClassIdentifier") orelse return null;
    const s = switch (v.*) {
        .scalar => |s| s,
        else => return null,
    };
    const idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse (if (s.len != 0) return s else return null);
    const tail = s[idx + 1 ..];
    return if (tail.len != 0) tail else null;
}

/// 生の field diff から Inspector 非表示を落とし、path を表示名に置換する。
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

fn resolvedTypeName(doc: *const model.Document) ![]const u8 {
    if (classid.typeName(doc.class_id)) |n| return n;
    // Unknown classID: fall back to the document's own top key.
    return doc.type_name;
}

pub fn compute(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !FlatDiff {
    const before = try parser.parse(arena, before_src);
    const after = try parser.parse(arena, after_src);

    var docs: std.ArrayList(DocDiff) = .empty;
    var guids = GuidSet.init(arena);

    // fileID -> *Document indices so the union walk below is O(n) instead of
    // O(n^2) linear scans (matters at scene scale: tens of thousands of docs).
    var before_idx = try buildIndex(arena, before);
    var after_idx = try buildIndex(arena, after);

    // Walk the union of file_ids: iterate `after` first (preserves after order),
    // then `before`-only documents.
    for (after) |*ad| {
        if (ad.stripped) continue;
        try collectGuids(&guids, ad.body);
        const bd = before_idx.get(ad.file_id);
        if (bd) |b| {
            try collectGuids(&guids, b.body);
            var raw: std.ArrayList(FieldDiff) = .empty;
            try diffNode(arena, &raw, "", b.body, ad.body);
            const fields = try presentFields(arena, try raw.toOwnedSlice(arena));
            try docs.append(arena, .{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(ad),
                .script_guid = scriptGuid(ad),
                .class_name = editorClassName(ad),
                .status = if (fields.len == 0) .unchanged else .modified,
                .fields = fields,
            });
        } else {
            var raw: std.ArrayList(FieldDiff) = .empty;
            if (ad.class_id != 1001) {
                for (ad.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .added);
            }
            try docs.append(arena, .{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(ad),
                .script_guid = scriptGuid(ad),
                .class_name = editorClassName(ad),
                .status = .added,
                .fields = try presentFields(arena, try raw.toOwnedSlice(arena)),
            });
        }
    }
    for (before) |*bd| {
        if (bd.stripped) continue;
        if (after_idx.contains(bd.file_id)) continue;
        try collectGuids(&guids, bd.body);
        try docs.append(arena, .{
            .file_id = bd.file_id,
            .class_id = bd.class_id,
            .type_name = try resolvedTypeName(bd),
            .script_guid = scriptGuid(bd),
            .class_name = editorClassName(bd),
            .status = .removed,
            .fields = &[_]FieldDiff{},
        });
    }

    return .{
        .docs = try docs.toOwnedSlice(arena),
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
    // keys in a: modified/removed/recurse
    for (a) |ea| {
        const path = try joinKey(arena, prefix, ea.key);
        if (model.findValue(b, ea.key)) |bv| {
            try diffNode(arena, out, path, ea.value, bv);
        } else {
            try flattenSubtree(arena, out, path, ea.value, .removed);
        }
    }
    // keys only in b: added
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
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try diffNode(arena, out, path, a[i], b[i]);
    }
    while (i < a.len) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, a[i], .removed);
    }
    while (i < b.len) : (i += 1) {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, b[i], .added);
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

fn vectorNode(arena: std.mem.Allocator, entries: []model.Entry) !*Node {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '(');
    for (entries, 0..) |e, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, e.value.scalar);
    }
    try out.append(arena, ')');
    const n = try arena.create(Node);
    n.* = .{ .scalar = try out.toOwnedSlice(arena) };
    return n;
}

fn appendLeaf(arena: std.mem.Allocator, out: *std.ArrayList(FieldDiff), path: []const u8, status: Status, node: *const Node) !void {
    try out.append(arena, switch (status) {
        .added => .{ .path = path, .status = .added, .before = null, .after = node },
        .removed => .{ .path = path, .status = .removed, .before = node, .after = null },
        else => unreachable,
    });
}

/// added/removed サブツリーを leaf 単位に展開する。ベクトル風 map は 1 行に縮約。
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

const GuidSet = struct {
    arena: std.mem.Allocator,
    map: std.StringHashMap(void),
    order: std.ArrayList([]const u8),

    fn init(arena: std.mem.Allocator) GuidSet {
        return .{ .arena = arena, .map = std.StringHashMap(void).init(arena), .order = .empty };
    }
    fn add(self: *GuidSet, guid: []const u8) !void {
        if (self.map.contains(guid)) return;
        try self.map.put(guid, {});
        try self.order.append(self.arena, guid);
    }
    fn toSlice(self: *GuidSet) ![][]const u8 {
        return self.order.toOwnedSlice(self.arena);
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
