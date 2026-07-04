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
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "MonoBehaviour") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Volume") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "->") != null);
    // No ANSI escape when color is disabled.
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
}

test "render: prefab instance shows name, components label and grouped overrides" {
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
    try testing.expect(std.mem.indexOf(u8, text, "+ Cylinder Variant  <Prefab>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "components") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Transform") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Scale.y: 2") != null);
}

test "render: components label separates object and component dimensions" {
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
    // "  Player" → "    components" → "      ~ MonoBehaviour" の深度になる。
    try testing.expect(std.mem.indexOf(u8, text, "\n    components\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n      ~ MonoBehaviour\n") != null);
}

test "render: mixed-status override group gets a modified heading" {
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
    // 追加された mod が先頭に来る順にして、見出しが先頭行の status に
    // 引きずられないことを見る。
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
    try testing.expect(std.mem.indexOf(u8, text, "~ Transform\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Transform\n") == null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Scale.y: 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "~ Position.x: 0 -> 1") != null);
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
    // 件数はラベルに含まれるので、値なし行はラベルだけで終わる。
    try testing.expect(std.mem.indexOf(u8, text, "+ Added Components (1)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "∅") == null);
}

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

fn displayObjectName(o: model.ObjectDiff, resolved: ?*const core.json.Resolver) []const u8 {
    if (o.name.len != 0) return o.name;
    if (o.kind == .prefab_instance) {
        if (o.source_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
            return std.fs.path.stem(p);
        };
        return "Prefab Instance";
    }
    return "(GameObject)";
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
    try w.print(" {s}", .{displayObjectName(o, resolved)});
    if (o.kind == .prefab_instance) try w.writeAll("  <Prefab>");
    try w.writeByte('\n');
    // 表示次元の規則: コンポーネント/override は必ず components セクション配下。
    // ラベル行には sign+space の 2 文字分の前置がないため、子オブジェクトの
    // 名前列(depth+1 の indent + sign+space)に視覚的に揃うよう depth+2 を使う。
    if (o.overrides.len != 0 or o.components.len != 0) {
        try indent(w, depth + 2);
        try paint(w, color, Color.dim, "components");
        try w.writeByte('\n');
        try renderOverrides(w, o.overrides, color, depth + 3);
        for (o.components) |c| try renderComponent(arena, w, c, resolved, color, depth + 3);
    }
    for (o.children) |child| try renderObject(arena, w, child, resolved, color, depth + 1);
}

/// 見出しの status: グループ内で一様ならその status、混在なら modified。
fn groupHeadingStatus(overrides: []const model.OverrideDiff, start: usize) model.Status {
    const first = overrides[start];
    for (overrides[start + 1 ..]) |ov| {
        if (!std.mem.eql(u8, ov.group, first.group)) break;
        if (ov.status != first.status) return .modified;
    }
    return first.status;
}

fn renderOverrides(w: anytype, overrides: []const model.OverrideDiff, color: bool, depth: usize) !void {
    var current: []const u8 = "";
    for (overrides, 0..) |ov, i| {
        if (!std.mem.eql(u8, current, ov.group)) {
            current = ov.group;
            const hs = groupHeadingStatus(overrides, i);
            try indent(w, depth);
            try paint(w, color, statusColor(hs), statusSign(hs));
            try w.print(" {s}\n", .{ov.group});
        }
        try indent(w, depth + 1);
        try paint(w, color, statusColor(ov.status), statusSign(ov.status));
        // 構造サマリ行 (before=after=null) は件数がラベルに含まれ、値を持たない。
        if (ov.before == null and ov.after == null) {
            try w.print(" {s}\n", .{ov.label});
            continue;
        }
        try w.print(" {s}: ", .{ov.label});
        switch (ov.status) {
            .modified => {
                try writeValueText(w, ov.before);
                try w.writeAll(" -> ");
                try writeValueText(w, ov.after);
            },
            .added => try writeValueText(w, ov.after),
            .removed => try writeValueText(w, ov.before),
            .unchanged => {},
        }
        try w.writeByte('\n');
    }
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
    if (c.class_name) |n| display = n;
    if (c.script_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
        display = std.fs.path.stem(p);
    };
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
