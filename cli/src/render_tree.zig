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
    try testing.expect(std.mem.indexOf(u8, text, "volume") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0.8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "->") != null);
    // No ANSI escape when color is disabled.
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
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
