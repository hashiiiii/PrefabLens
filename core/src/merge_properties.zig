const std = @import("std");
const model = @import("model.zig");
const source = @import("source.zig");
const planner = @import("merge_planner.zig");
const apply = @import("merge_apply.zig");
const Error = @import("merge_model.zig").Error;

test "merge properties: nested edits preserve comments quotes and CRLF" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const before = "--- !u!114 &2\r\nMonoBehaviour:\r\n  m_GameObject: {fileID: 1}\r\n  custom: {x: 0.25, y: 00} # keep\r\n  names: ['a:b', 'unchanged']\r\n  custom.value: 7\r\n";
    const expected = "--- !u!114 &2\r\nMonoBehaviour:\r\n  m_GameObject: {fileID: 1}\r\n  custom: {x: 0.6, y: 00} # keep\r\n  names: ['a:b', 'unchanged']\r\n  custom.value: 7\r\n";
    const updated = try edit(arena, try parse(arena, before), &.{ .{ .key = "custom" }, .{ .key = "x" } }, "0.6");
    try std.testing.expectEqualStrings(expected, updated);
    const renamed = try edit(arena, try parse(arena, updated), &.{ .{ .key = "names" }, .{ .index = 0 } }, "'new: value'");
    try std.testing.expect(std.mem.indexOf(u8, renamed, "names: ['new: value', 'unchanged']\r\n") != null);
    // Literal keys must never be interpreted as nested property paths.
    const dotted = try edit(arena, try parse(arena, renamed), &.{.{ .key = "custom.value" }}, "8");
    try std.testing.expect(std.mem.indexOf(u8, dotted, "custom.value: 8\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dotted, "custom: {x: 0.6, y: 00} # keep\r\n") != null);
}

test "merge properties: cell input cannot modify ownership or escape its field" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const document = try parse(arena, "--- !u!135 &2\nSphereCollider:\n  m_GameObject: {fileID: 1}\n  m_Radius: 0.25\n");
    try std.testing.expectError(error.InvalidResolution, edit(arena, document, &.{.{ .key = "m_GameObject" }}, "{fileID: 3}"));
    for ([_][]const u8{ "0.6 # discard", "0.6\n  extra: 1", "{fileID: 3}", "[1, 2]" }) |invalid| {
        try std.testing.expectError(error.InvalidResolution, edit(arena, document, &.{.{ .key = "m_Radius" }}, invalid));
    }
}

test "merge properties: empty fields preserve their source and remain editable" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const before = "--- !u!114 &2\r\nMonoBehaviour:\r\n  label: 'text' # keep\r\n  target: {fileID: 7}\r\n  settings: {label: text, speed: 2}\r\n";
    const path = &[_]Segment{.{ .key = "label" }};
    const cleared = try edit(arena, try parse(arena, before), path, "");
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, before, "'text'", ""), cleared);
    const document = try parse(arena, cleared);
    // YAML empty has no node span; its entry still identifies the editable token position.
    try std.testing.expect(document.editable(path));
    try std.testing.expectEqualStrings("", document.input(path).?);
    try std.testing.expectEqualStrings(before, try edit(arena, document, path, "'text'"));
    const empty_string = try edit(arena, document, path, "\"\"");
    try std.testing.expect(std.mem.indexOf(u8, empty_string, "label: \"\" # keep") != null);
    for ([_][]const Segment{ &.{.{ .key = "target" }}, &.{ .{ .key = "settings" }, .{ .key = "label" } } }) |field| {
        const original = try parse(arena, before);
        const empty = try parse(arena, try edit(arena, original, field, ""));
        try std.testing.expectEqualStrings("", empty.input(field).?);
        try std.testing.expectEqualStrings(before, try edit(arena, empty, field, original.input(field).?));
    }
}

pub const Segment = union(enum) { key: []const u8, index: usize };

pub const Document = struct {
    file: source.ParsedFile,

    pub fn node(self: Document, path: []const Segment) ?*const model.Node {
        var current: *const model.Node = self.file.documents[0].body;
        for (path) |part| {
            current = switch (part) {
                .key => |key| if (current.* == .map) current.get(key) orelse return null else return null,
                .index => |index| if (current.* == .seq and index < current.seq.len) current.seq[index] else return null,
            };
        }
        return current;
    }

    pub fn editable(self: Document, path: []const Segment) bool {
        if (path.len == 0) return false;
        // Component ownership is resolved together with its GameObject membership.
        if (path[0] == .key and std.mem.eql(u8, path[0].key, "m_GameObject")) return false;
        const value = self.node(path) orelse return false;
        const span = self.tokenSpan(value) orelse return false;
        return value.* == .scalar or value.* == .ref or span.start == span.end;
    }

    pub fn input(self: Document, path: []const Segment) ?[]const u8 {
        return (self.tokenSpan(self.node(path) orelse return null) orelse return null).bytes(self.file.bytes);
    }

    fn tokenSpan(self: Document, value: *const model.Node) ?source.Span {
        if (self.file.node_spans.get(value)) |span| return span;
        const entry = self.file.entry_spans.get(value) orelse return null;
        if (entry.value.start != entry.value.end) return null;
        // Blank block values parse as empty maps, but their entry retains the insertion point.
        var position = entry.value.start;
        if (position < self.file.bytes.len and self.file.bytes[position] == ' ') position += 1;
        return .{ .start = position, .end = position };
    }
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!Document {
    const file = try planner.parseMergeSide(arena, bytes);
    if (file.documents.len != 1) return error.InvalidResolution;
    return .{ .file = file };
}

pub fn edit(arena: std.mem.Allocator, document: Document, path: []const Segment, input: []const u8) Error![]const u8 {
    if (!document.editable(path)) return error.InvalidResolution;
    _ = try apply.parseCustomValue(arena, input);
    const before = document.node(path).?;
    const span = document.tokenSpan(before).?;
    const separator = if (span.start == span.end and input.len != 0 and span.start > 0 and document.file.bytes[span.start - 1] == ':') " " else "";
    const bytes = try std.mem.concat(arena, u8, &.{ document.file.bytes[0..span.start], separator, input, document.file.bytes[span.end..] });
    const after = try parse(arena, bytes);
    const value = after.node(path) orelse return error.InvalidResolution;
    if (input.len != 0 and span.start != span.end and std.meta.activeTag(before.*) != std.meta.activeTag(value.*)) return error.InvalidResolution;
    // Reparse the entire document so a value cannot escape its field through YAML syntax.
    if (!std.mem.eql(u8, after.input(path) orelse return error.InvalidResolution, input)) return error.InvalidResolution;
    return bytes;
}
