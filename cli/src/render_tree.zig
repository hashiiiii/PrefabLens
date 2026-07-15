const std = @import("std");
const core = @import("core");
const testing = std.testing;

test "render: modified loose component under a counted components group" {
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
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "components (1)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "└─ ~ MonoBehaviour") != null);
    // Field status equals the card status, so the per-field sign is omitted.
    try testing.expect(std.mem.indexOf(u8, text, "Volume: 0.5 → 0.8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "~ Volume") == null);
    // No ANSI escape when color is disabled.
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
}

test "render: colored values follow the extension's before/after palette" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 100
        \\  m_OldFlag: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 250
        \\  m_NewFlag: 1
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, true);
    const text = aw.toArrayList().items;
    // Modified field: before value red, arrow dim, after value green — the
    // terminal reading of the extension's pl-before/pl-arrow/pl-after spans.
    try testing.expect(std.mem.indexOf(u8, text, "Hp: \x1b[31m100\x1b[0m\x1b[2m → \x1b[0m\x1b[32m250\x1b[0m") != null);
    // One-sided fields paint their single value in the side's color.
    try testing.expect(std.mem.indexOf(u8, text, "New Flag: \x1b[32m1\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Old Flag: \x1b[31m1\x1b[0m") != null);
}

test "render: resolved ref values read as asset paths, like the extension" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Material: {fileID: 2100000, guid: abc123, type: 2}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Material: {fileID: 0}
    ;
    const res = try core.diffBytes(arena, before, after);
    var resolver = core.json.Resolver.init(arena);
    try resolver.put("abc123", "Assets/Materials/Fixture.mat");
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, &resolver, false);
    const text = aw.toArrayList().items;
    // The external ref shows its resolved path instead of the raw guid tuple.
    try testing.expect(std.mem.indexOf(u8, text, "Material: Assets/Materials/Fixture.mat → None") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guid:abc123") == null);
}

test "render: null reference reads as None, local refs as #fileID" {
    // Same decision-table cases as the extension's render.test.ts ("shows the
    // null reference ({fileID: 0}) as None") and the editor's ValueFormatTests.cs.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!65 &5
        \\CapsuleCollider:
        \\  m_Material: {fileID: 0}
    ;
    const after =
        \\--- !u!65 &5
        \\CapsuleCollider:
        \\  m_Material: {fileID: 42}
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "Material: None → #42") != null);
}

test "render: unity built-in refs show object names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 0}
    ;
    const after =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 10202, guid: 0000000000000000e000000000000000, type: 0}
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    // No resolver: built-in names come from the checked-in table, not .meta files.
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "Cube (built-in)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guid:0000000000000000e000000000000000") == null);
}

test "render: built-in guid with unknown fileID keeps the raw guid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 0}
    ;
    // fileID 424242 is not in the table (e.g. an object added by a future Unity).
    const after =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 424242, guid: 0000000000000000e000000000000000, type: 0}
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "guid:0000000000000000e000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "built-in") == null);
}

test "render: prefab instance shows cube glyph, meta marker and overrides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try core.diffBytes(arena, "", after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "◆ + Cylinder Variant ‹Prefab›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "components (") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Transform") != null);
    // Row status (added) matches the group heading, so no per-row sign.
    try testing.expect(std.mem.indexOf(u8, text, "Scale.y: 2") != null);
}

test "render: spine glyphs connect object, components node and cards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 100
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 250
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    // Player has no children, so components is its last (only) spine node,
    // and the single card closes the inner spine.
    try testing.expect(std.mem.indexOf(u8, text, "◆ Player\n└─ components (1)\n   └─ ~ MonoBehaviour\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Hp: 100 → 250") != null);
}

test "render: child object hangs off the parent spine after components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
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
    const after =
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
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    // The child is the parent's last spine node.
    try testing.expect(std.mem.indexOf(u8, text, "└─ ◆ ~ ChildRenamed") != null);
}

test "render: component shows editor class name when script is unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    // No resolver -> the guid can't be resolved, but the class name is more
    // specific than MonoBehaviour. The unresolved script keeps a bare marker.
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "~ Cylinder1 ‹Script›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MonoBehaviour") == null);
}

test "render: mixed-status override group keeps signs only where they differ" {
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
        \\      value: 0
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    // Mixed group -> modified heading; the added row differs so it keeps +,
    // the modified row matches so its sign is dropped.
    try testing.expect(std.mem.indexOf(u8, text, "~ Transform") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Transform") == null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Scale.y: 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Position.x: 0 → 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "~ Position.x") == null);
}

test "render: structural summary row shows label only, no dangling value" {
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
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 4, guid: aaa, type: 3}
        \\      addedObject: {fileID: 5}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    // The count is included in the label, so a value-less row ends with just
    // the label.
    try testing.expect(std.mem.indexOf(u8, text, "Added Components (1)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "∅") == null);
}

const model = core.model;
const display = @import("display.zig");
const builtin_refs = @import("builtin_refs.zig");

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const green = "\x1b[32m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const dim = "\x1b[2m";
    pub const bold = "\x1b[1m";
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
        .unchanged => "",
    };
}

pub fn render(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    res: model.DiffResult,
    resolved: ?*const core.json.Resolver,
    color: bool,
) !void {
    var prefix: std.ArrayList(u8) = .empty;
    for (res.roots) |o| try renderObject(arena, w, o, resolved, color, &prefix, "");
    if (res.loose.len != 0) {
        // Loose components form a root-level components group, mirroring the
        // extension's diff.loose section.
        try paintLabel(w, color, res.loose.len);
        for (res.loose, 0..) |c, i| {
            try renderCard(arena, w, .{ .component = c }, resolved, color, &prefix, i + 1 == res.loose.len);
        }
    }
    if (resolved == null) {
        // Built-ins display by name (no .meta exists for them), so counting
        // them here would advertise a --project run that cannot help.
        const n = display.unresolvedCount(res);
        if (n != 0) try w.print("\n({d} unresolved guid reference(s); pass --project DIR to resolve)\n", .{n});
    }
}

fn paint(w: *std.Io.Writer, color: bool, code: []const u8, text: []const u8) !void {
    if (color) try w.writeAll(code);
    try w.writeAll(text);
    if (color) try w.writeAll(Color.reset);
}

fn paintLabel(w: *std.Io.Writer, color: bool, count: usize) !void {
    if (color) try w.writeAll(Color.dim);
    try w.print("components ({d})", .{count});
    if (color) try w.writeAll(Color.reset);
    try w.writeByte('\n');
}

fn signed(w: *std.Io.Writer, color: bool, status: model.Status) !void {
    if (status == .unchanged) return;
    try paint(w, color, statusColor(status), statusSign(status));
    try w.writeByte(' ');
}

fn renderObject(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    o: model.ObjectDiff,
    resolved: ?*const core.json.Resolver,
    color: bool,
    prefix: *std.ArrayList(u8),
    branch: []const u8,
) anyerror!void {
    try w.writeAll(prefix.items);
    try w.writeAll(branch);
    try w.writeAll("◆ ");
    try signed(w, color, o.status);
    try w.writeAll(display.objectName(o, resolved));
    if (o.kind == .prefab_instance) {
        if (color) try w.writeAll(Color.dim);
        try w.writeAll(" ‹Prefab");
        if (o.source_guid) |g| if (resolved) |r| if (r.get(g)) |p| try w.print(": {s}", .{p});
        try w.writeAll("›");
        if (color) try w.writeAll(Color.reset);
    }
    try w.writeByte('\n');

    // Below this row the spine continues for our own kids: components group
    // first (if any), then child objects.
    const mark = prefix.items.len;
    try prefix.appendSlice(arena, continuation(branch));
    defer prefix.shrinkRetainingCapacity(mark);

    const card_count = display.overrideGroupCount(o.overrides) + o.components.len;
    if (card_count != 0) {
        const label_last = o.children.len == 0;
        try w.writeAll(prefix.items);
        try w.writeAll(if (label_last) "└─ " else "├─ ");
        try paintLabel(w, color, card_count);

        const inner_mark = prefix.items.len;
        try prefix.appendSlice(arena, if (label_last) "   " else "│  ");
        defer prefix.shrinkRetainingCapacity(inner_mark);

        var idx: usize = 0;
        var current: []const u8 = "";
        var i: usize = 0;
        while (i < o.overrides.len) : (i += 1) {
            if (!std.mem.eql(u8, current, o.overrides[i].group)) {
                current = o.overrides[i].group;
                idx += 1;
                try renderCard(arena, w, .{ .group = .{ .overrides = o.overrides, .start = i } }, resolved, color, prefix, idx == card_count);
            }
        }
        for (o.components) |c| {
            idx += 1;
            try renderCard(arena, w, .{ .component = c }, resolved, color, prefix, idx == card_count);
        }
    }
    for (o.children, 0..) |child, i| {
        try renderObject(arena, w, child, resolved, color, prefix, if (i + 1 == o.children.len) "└─ " else "├─ ");
    }
}

fn continuation(branch: []const u8) []const u8 {
    if (branch.len == 0) return "";
    if (std.mem.eql(u8, branch, "├─ ")) return "│  ";
    return "   ";
}

const Card = union(enum) {
    component: model.ComponentDiff,
    group: struct { overrides: []const model.OverrideDiff, start: usize },
};

fn renderCard(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    card: Card,
    resolved: ?*const core.json.Resolver,
    color: bool,
    prefix: *std.ArrayList(u8),
    last: bool,
) !void {
    try w.writeAll(prefix.items);
    try w.writeAll(if (last) "└─ " else "├─ ");
    const status: model.Status = switch (card) {
        .component => |c| c.status,
        .group => |g| display.groupHeadingStatus(g.overrides, g.start),
    };
    try signed(w, color, status);
    switch (card) {
        .component => |c| {
            try w.writeAll(display.componentName(c, resolved));
            if (c.script_guid) |g| {
                if (color) try w.writeAll(Color.dim);
                try w.writeAll(" ‹Script");
                if (resolved) |r| if (r.get(g)) |p| try w.print(": {s}", .{p});
                try w.writeAll("›");
                if (color) try w.writeAll(Color.reset);
            }
        },
        .group => |g| try w.writeAll(g.overrides[g.start].group),
    }
    try w.writeByte('\n');

    // Field rows sit under the card without glyphs of their own.
    const mark = prefix.items.len;
    try prefix.appendSlice(arena, if (last) "     " else "│    ");
    defer prefix.shrinkRetainingCapacity(mark);

    switch (card) {
        .component => |c| for (c.fields) |f| {
            try renderFieldRow(w, f.path, f.status, status, f.before, f.after, resolved, color, prefix);
        },
        .group => |g| {
            const group_name = g.overrides[g.start].group;
            for (g.overrides[g.start..]) |ov| {
                if (!std.mem.eql(u8, ov.group, group_name)) break;
                try renderFieldRow(w, ov.label, ov.status, status, ov.before, ov.after, resolved, color, prefix);
            }
        },
    }
}

fn renderFieldRow(
    w: *std.Io.Writer,
    label: []const u8,
    status: model.Status,
    parent: model.Status,
    before: ?*const model.Node,
    after: ?*const model.Node,
    resolved: ?*const core.json.Resolver,
    color: bool,
    prefix: *std.ArrayList(u8),
) !void {
    try w.writeAll(prefix.items);
    // The sign repeats only when it adds information over the card's status.
    if (status != parent) try signed(w, color, status);
    try w.writeAll(label);
    // A structural summary row (before=after=null) has the count in the
    // label and no value.
    if (before == null and after == null) {
        try w.writeByte('\n');
        return;
    }
    try w.writeAll(": ");
    // Values carry the same red→green reading as the extension's
    // pl-before/pl-arrow/pl-after spans: before red, arrow dim, after green.
    switch (status) {
        .modified => {
            try paintValue(w, color, Color.red, before, resolved);
            try paint(w, color, Color.dim, " → ");
            try paintValue(w, color, Color.green, after, resolved);
        },
        .added => try paintValue(w, color, Color.green, after, resolved),
        .removed => try paintValue(w, color, Color.red, before, resolved),
        .unchanged => {},
    }
    try w.writeByte('\n');
}

fn paintValue(
    w: *std.Io.Writer,
    color: bool,
    code: []const u8,
    node: ?*const model.Node,
    resolved: ?*const core.json.Resolver,
) !void {
    if (color) try w.writeAll(code);
    try writeValueText(w, node, resolved);
    if (color) try w.writeAll(Color.reset);
}

fn writeValueText(w: *std.Io.Writer, node: ?*const model.Node, resolved: ?*const core.json.Resolver) !void {
    const n = node orelse {
        try w.writeAll("—");
        return;
    };
    switch (n.*) {
        .scalar => |s| try w.writeAll(s),
        .ref => |r| {
            if (r.guid) |g| {
                // Same rule as render_html's writeValue (and the extension's
                // formatValue): a resolved external ref reads as its asset path,
                // a Unity built-in ref as its object name.
                if (resolved) |rr| {
                    if (rr.get(g)) |p| {
                        try w.writeAll(p);
                        return;
                    }
                }
                if (builtin_refs.name(g, r.file_id)) |builtin| {
                    try w.print("{s} (built-in)", .{builtin});
                    return;
                }
                try w.print("guid:{s}", .{g});
            } else if (r.file_id == 0) {
                // Unity's null reference; the Inspector shows it as None.
                try w.writeAll("None");
            } else {
                try w.print("#{d}", .{r.file_id});
            }
        },
        .map => try w.writeAll("{...}"),
        .seq => try w.writeAll("[...]"),
    }
}
