const std = @import("std");
const core = @import("core");
const display = @import("display.zig");
const properties = core.merge.properties;
const Node = core.model.Node;

test "merge TUI: property comparisons expose changed children when value shapes differ" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &2\nMonoBehaviour:\n  custom: old\n";
    const theirs = "--- !u!114 &2\nMonoBehaviour:\n  custom: {speed: 2, enabled: 1}\n";
    const b = try properties.parse(arena, base);
    const t = try properties.parse(arena, theirs);
    const operation = core.merge.Operation{
        .id = 0,
        .atomic_id = 0,
        .kind = .document,
        .identity = .{ .document = .{ .class_id = 114, .file_id = 2 }, .property_path = "" },
        .property_path = "",
        .hierarchy_path = "MonoBehaviour",
        .values = .{
            .base = .{ .bytes = base, .node = b.node(&.{}), .span = null },
            .ours = null,
            .theirs = .{ .bytes = theirs, .node = t.node(&.{}), .span = null },
        },
        .resolution = .unresolved,
    };
    const model = try build(arena, &operation, .{ .take = .theirs });
    // A type change must not hide the fields the retained component will contain.
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("Custom.Speed", model.rows[1].label);
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[3]));
}

test "merge TUI: literal property keys remain distinct from nested paths and array indices" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &2\nMonoBehaviour:\n  custom.value: 1\n  custom: {value: 2}\n  items[0]: 3\n  items: [4]\n";
    const theirs = "--- !u!114 &2\nMonoBehaviour:\n  custom.value: 5\n  custom: {value: 6}\n  items[0]: 7\n  items: [8]\n";
    const fixture = try core.merge.build(arena, base, "", theirs);
    const model = try build(arena, &fixture.plan.operations[0], .{ .take = .theirs });
    // Display paths must identify the same fields as the source-preserving edit paths.
    try std.testing.expectEqual(@as(usize, 4), model.rows.len);
    for ([_][]const u8{ "[\"custom.value\"]", "Custom.Value", "[\"items[0]\"]", "Items[0]" }, model.rows) |expected, row| {
        try std.testing.expectEqualStrings(expected, row.label);
    }
}

pub const Row = struct {
    path: []const properties.Segment,
    label: []const u8,
    values: [4]?*const Node,
    changed: bool,
};

pub const Model = struct {
    documents: [4]?properties.Document,
    rows: []const Row,

    pub fn editable(self: Model, index: usize) bool {
        if (index >= self.rows.len) return false;
        const result = self.documents[3] orelse return false;
        return result.editable(self.rows[index].path);
    }

    pub fn text(self: Model, arena: std.mem.Allocator, index: usize, column: usize) ![]const u8 {
        if (self.documents[column]) |document| {
            if (document.input(self.rows[index].path)) |input| if (input.len == 0) return "<empty>";
        }
        return valueText(arena, self.rows[index].values[column]);
    }
};

pub fn supports(operation: *const core.merge.Operation) bool {
    if (operation.kind != .component and operation.kind != .document) return false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| if (value) |present| {
        const node = present.node orelse return false;
        if (node.* != .map) return false;
    };
    return true;
}

pub fn build(arena: std.mem.Allocator, operation: *const core.merge.Operation, resolution: core.merge.Resolution) !Model {
    const result_bytes: ?[]const u8 = switch (resolution) {
        .take => |side| if (operation.values.get(side)) |value| value.bytes else null,
        .custom => |value| value,
        .unresolved, .remove => null,
    };
    var documents: [4]?properties.Document = @splat(null);
    for ([_]?[]const u8{
        if (operation.values.base) |v| v.bytes else null,
        if (operation.values.ours) |v| v.bytes else null,
        if (operation.values.theirs) |v| v.bytes else null,
        result_bytes,
    }, 0..) |bytes, i| {
        if (bytes) |present| documents[i] = properties.parse(arena, present) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }
    var builder: Builder = .{ .arena = arena, .documents = documents };
    var roots: [4]?*const Node = @splat(null);
    for (documents, 0..) |document, i| if (document) |present| {
        roots[i] = present.node(&.{});
    };
    try builder.walk(&.{}, "", roots);
    return .{ .documents = documents, .rows = try builder.rows.toOwnedSlice(arena) };
}

const Builder = struct {
    arena: std.mem.Allocator,
    documents: [4]?properties.Document,
    rows: std.ArrayList(Row) = .empty,

    fn walk(self: *Builder, path: []const properties.Segment, label: []const u8, nodes: [4]?*const Node) std.mem.Allocator.Error!void {
        var map_only = true;
        var seq_only = true;
        var has_map = false;
        var has_seq = false;
        for (nodes) |node| if (node) |value| {
            map_only = map_only and value.* == .map;
            seq_only = seq_only and value.* == .seq;
            has_map = has_map or value.* == .map;
            has_seq = has_seq or value.* == .seq;
        };
        const mixed = !map_only and !seq_only and (has_map or has_seq);
        if (mixed) try self.append(path, label, nodes);
        var descendants = false;
        if (has_map) {
            var keys: std.StringHashMapUnmanaged(void) = .empty;
            for (nodes) |node| if (node) |value| {
                if (value.* != .map) continue;
                for (value.map) |entry| {
                    const found = try keys.getOrPut(self.arena, entry.key);
                    if (found.found_existing) continue;
                    var children: [4]?*const Node = @splat(null);
                    for (nodes, 0..) |parent, i| if (parent) |present| {
                        if (present.* == .map) children[i] = present.get(entry.key);
                    };
                    const child_path = try std.mem.concat(self.arena, properties.Segment, &.{ path, &.{.{ .key = entry.key }} });
                    const child_label = if (std.mem.indexOfAny(u8, entry.key, ".[]\"") != null)
                        try std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ label, try std.json.Stringify.valueAlloc(self.arena, entry.key, .{}) })
                    else
                        try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ label, if (label.len == 0) "" else ".", try core.displayPropertyPath(self.arena, entry.key) });
                    try self.walk(child_path, child_label, children);
                }
            };
            descendants = keys.count() != 0;
        }
        if (has_seq) {
            var count: usize = 0;
            for (nodes) |node| if (node) |value| {
                if (value.* == .seq) count = @max(count, value.seq.len);
            };
            for (0..count) |index| {
                var children: [4]?*const Node = @splat(null);
                for (nodes, 0..) |parent, i| if (parent) |value| {
                    if (value.* == .seq and index < value.seq.len) children[i] = value.seq[index];
                };
                const child_path = try std.mem.concat(self.arena, properties.Segment, &.{ path, &.{.{ .index = index }} });
                try self.walk(child_path, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ label, index }), children);
            }
            descendants = descendants or count != 0;
        }
        if (!mixed and !descendants) try self.append(path, label, nodes);
    }

    fn append(self: *Builder, path: []const properties.Segment, label: []const u8, nodes: [4]?*const Node) !void {
        if (path.len == 0) return;
        var compared = false;
        var first: ?*const Node = null;
        var changed = self.documents[0] == null;
        for (nodes, self.documents) |node, document| {
            // A removed component is one existence change, not a change to every unchanged property.
            if (document == null) continue;
            if (compared) {
                changed = changed or !equal(first, node);
            } else {
                first = node;
                compared = true;
            }
        }
        try self.rows.append(self.arena, .{ .path = path, .label = label, .values = nodes, .changed = changed });
    }
};

fn equal(a: ?*const Node, b: ?*const Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return Node.eql(a.?, b.?);
}

pub fn valueText(arena: std.mem.Allocator, node: ?*const Node) ![]const u8 {
    const value = node orelse return "—";
    return switch (value.*) {
        .scalar => |text| if (text.len == 0) "<empty>" else text,
        .ref => |ref| switch (display.refDisplay(ref, null)) {
            .none => "None",
            .path, .builtin => |name| name,
            .guid => |guid| try std.fmt.allocPrint(arena, "guid:{s} #{d}", .{ guid, ref.file_id }),
            .file_id => |id| try std.fmt.allocPrint(arena, "#{d}", .{id}),
        },
        .map => |entries| try std.fmt.allocPrint(arena, "{d} fields", .{entries.len}),
        .seq => |items| try std.fmt.allocPrint(arena, "{d} items", .{items.len}),
    };
}
