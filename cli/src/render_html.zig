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
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null);
    const html = aw.toArrayList().items;
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    // HTML special chars escaped: "A<x>" -> "A&lt;x&gt;"
    try testing.expect(std.mem.indexOf(u8, html, "A&lt;x&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hp") != null);
}

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
