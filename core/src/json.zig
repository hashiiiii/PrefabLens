const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const Node = model.Node;
const Status = model.Status;

pub const Resolver = std.StringHashMap([]const u8);

pub fn serialize(arena: std.mem.Allocator, res: model.DiffResult, resolved: ?*const Resolver) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;

    try w.writeAll("{\"schema\":\"prefablens.diff.v1\"");

    try w.writeAll(",\"unresolvedGuids\":[");
    for (res.unresolved_guids, 0..) |g, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, g);
    }
    try w.writeByte(']');

    if (resolved) |r| {
        try w.writeAll(",\"resolved\":{");
        var it = r.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonString(w, e.key_ptr.*);
            try w.writeByte(':');
            try writeJsonString(w, e.value_ptr.*);
        }
        try w.writeByte('}');
    }

    try w.writeAll(",\"roots\":[");
    for (res.roots, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, o, resolved);
    }
    try w.writeAll("],\"loose\":[");
    for (res.loose, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("]}");

    var list = aw.toArrayList();
    return list.toOwnedSlice(arena);
}

fn writeObject(w: *std.Io.Writer, o: model.ObjectDiff, resolved: ?*const Resolver) !void {
    try w.writeAll("{\"kind\":\"gameObject\",\"fileId\":");
    try writeI64String(w, o.file_id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, o.name);
    try w.writeAll(",\"status\":");
    try writeStatus(w, o.status);
    try w.writeAll(",\"components\":[");
    for (o.components, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("],\"children\":[");
    for (o.children, 0..) |child, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, child, resolved);
    }
    try w.writeAll("]}");
}

fn writeComponent(w: anytype, c: model.ComponentDiff, resolved: ?*const Resolver) !void {
    try w.writeAll("{\"kind\":\"component\",\"fileId\":");
    try writeI64String(w, c.file_id);
    try w.print(",\"classId\":{d},\"typeName\":", .{c.class_id});
    try writeJsonString(w, c.type_name);
    try w.writeAll(",\"scriptGuid\":");
    if (c.script_guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
    if (resolved) |r| {
        if (c.script_guid) |g| {
            if (r.get(g)) |path| {
                try w.writeAll(",\"scriptName\":");
                try writeJsonString(w, path);
            }
        }
    }
    try w.writeAll(",\"status\":");
    try writeStatus(w, c.status);
    try w.writeAll(",\"fields\":[");
    for (c.fields, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try writeField(w, f);
    }
    try w.writeAll("]}");
}

fn writeField(w: anytype, f: model.FieldDiff) !void {
    try w.writeAll("{\"path\":");
    try writeJsonString(w, f.path);
    try w.writeAll(",\"status\":");
    try writeStatus(w, f.status);
    try w.writeAll(",\"before\":");
    try writeValue(w, f.before);
    try w.writeAll(",\"after\":");
    try writeValue(w, f.after);
    try w.writeByte('}');
}

fn writeValue(w: anytype, node: ?*const Node) !void {
    const n = node orelse {
        try w.writeAll("null");
        return;
    };
    switch (n.*) {
        .scalar => |s| try writeJsonString(w, s),
        .ref => |r| {
            try w.writeAll("{\"ref\":{\"fileId\":");
            try writeI64String(w, r.file_id);
            try w.writeAll(",\"guid\":");
            if (r.guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
            try w.writeAll(",\"type\":");
            if (r.type_id) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
            try w.writeAll("}}");
        },
        // Maps/seqs as field leaves are uncommon (they recurse), but render compactly.
        .map => try w.writeAll("\"<map>\""),
        .seq => try w.writeAll("\"<seq>\""),
    }
}

fn writeStatus(w: anytype, s: Status) !void {
    const text = switch (s) {
        .added => "\"added\"",
        .removed => "\"removed\"",
        .modified => "\"modified\"",
        .unchanged => "\"unchanged\"",
    };
    try w.writeAll(text);
}

fn writeI64String(w: anytype, v: i64) !void {
    try w.print("\"{d}\"", .{v});
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "json: modified loose component matches golden" {
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
    const out = try root.diffToJson(arena, before, after);
    const golden =
        \\{"schema":"prefablens.diff.v1","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","status":"modified","fields":[{"path":"volume","status":"modified","before":"0.5","after":"0.8"}]}]}
    ;
    try testing.expectEqualStrings(golden, out);
}

test "json: fileId is a string, ref value serialized as object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 100}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 200}
    ;
    const out = try root.diffToJson(arena, before, after);
    try testing.expect(std.mem.indexOf(u8, out, "\"fileId\":\"5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"after\":{\"ref\":{\"fileId\":\"200\",\"guid\":null,\"type\":null}}") != null);
}

test "json: string escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: a
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "a\"b"
    ;
    const out = try root.diffToJson(arena, before, after);
    // The quote inside the value must be escaped in JSON output.
    try testing.expect(std.mem.indexOf(u8, out, "a\\\"b") != null);
}
