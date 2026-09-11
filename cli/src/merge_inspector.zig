const std = @import("std");
const core = @import("core");
const display = @import("display.zig");
const properties = core.merge.properties;
const Node = core.model.Node;

test "merge TUI: semantic rows hide inspector-hidden ownership fields" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const rigidbody =
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n";
    const document = try properties.parse(arena, rigidbody);
    const operation = core.merge.Operation{
        .id = 0,
        .atomic_id = 0,
        .kind = .document,
        .identity = .{ .document = .{ .class_id = 54, .file_id = 54 }, .property_path = "" },
        .property_path = "",
        .hierarchy_path = "Rigidbody",
        .values = .{
            .base = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .ours = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .theirs = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
        },
        .resolution = .unresolved,
    };
    const model = try build(arena, &operation, .unresolved);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expectEqualStrings("Mass", model.rows[0].label);
}

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

test "merge TUI: dictionary field conflicts expose key and value rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &2\nMonoBehaviour:\n  m_Stats:\n";
    var fixture = try core.merge.build(
        arena,
        prefix ++ "  - key: Goblin\n    value: 1\n",
        prefix ++ "  - key: Goblin\n    value: 2\n",
        prefix ++ "  - key: Goblin\n    value: 3\n",
    );
    const operation = &fixture.plan.operations[0];
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved);
    // SphereCollider already walks maps into named rows. A pair conflict must do the same
    // so Key stays visible next to the disagreed Value.
    try std.testing.expectEqual(@as(usize, 2), model.rows.len);
    try std.testing.expectEqualStrings("Key", model.rows[0].label);
    try std.testing.expectEqualStrings("Value", model.rows[1].label);
    try std.testing.expectEqualStrings("Goblin", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("3", try valueText(arena, model.rows[1].values[2]));
}

test "merge TUI: prefab override conflicts expose path and value rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n" ++
        "    - target: {fileID: 40, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: items.Array.data[0].speed\n" ++
        "      value: ";
    const suffix = "\n      objectReference: {fileID: 0}\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ "1" ++ suffix,
        prefix ++ "2" ++ suffix,
        prefix ++ "3" ++ suffix,
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved);
    // Variant overrides are a path plus a scalar. The tree label is not enough once ⇧R is available.
    try std.testing.expectEqual(@as(usize, 2), model.rows.len);
    try std.testing.expectEqualStrings("Path", model.rows[0].label);
    try std.testing.expectEqualStrings("Value", model.rows[1].label);
    try std.testing.expectEqualStrings("Items[0].Speed", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("3", try valueText(arena, model.rows[1].values[2]));
}

test "merge TUI: sequence order rows follow each side's item order" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n";
    const suffix =
        "  m_SourcePrefab: {fileID: 100100000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n";
    const name =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Name\n" ++
        "      value: Root\n" ++
        "      objectReference: {fileID: 0}\n";
    const tag =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_TagString\n" ++
        "      value: Untagged\n" ++
        "      objectReference: {fileID: 0}\n";
    const layer =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Layer\n" ++
        "      value: 0\n" ++
        "      objectReference: {fileID: 0}\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ name ++ tag ++ layer ++ suffix,
        prefix ++ tag ++ name ++ layer ++ suffix,
        prefix ++ name ++ layer ++ tag ++ suffix,
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.kind == .sequence_order and op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved);
    // A reorder is one list. Rows keep each side's YAML order instead of aligning by property.
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("[0]", model.rows[0].label);
    try std.testing.expectEqualStrings("[1]", model.rows[1].label);
    try std.testing.expectEqualStrings("[2]", model.rows[2].label);
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[0].values[0]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[0].values[2]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[1].values[0]));
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[1].values[2]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[2].values[0]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[2].values[1]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[2].values[2]));
    try std.testing.expect(!model.editable(0));
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
        const row = self.rows[index];
        if (self.documents[3]) |result| {
            return result.editable(row.path);
        }
        // A missing Result document is not editable. Synthetic Path/Value tables have no documents.
        for (self.documents) |document| {
            if (document != null) return false;
        }
        if (std.mem.eql(u8, row.label, "Path") or std.mem.eql(u8, row.label, "Key")) return false;
        // Sequence order is one list choice. An index row is not a cell you can edit.
        if (row.path.len == 1 and row.path[0] == .index) return false;
        for (row.values) |node| {
            if (node) |value| {
                if (value.* != .scalar and value.* != .ref) return false;
            }
        }
        return true;
    }

    pub fn text(self: Model, arena: std.mem.Allocator, index: usize, column: usize) ![]const u8 {
        if (self.documents[column]) |document| {
            if (document.input(self.rows[index].path)) |input| if (input.len == 0) return "<empty>";
        }
        return valueText(arena, self.rows[index].values[column]);
    }
};

pub fn supports(operation: *const core.merge.Operation) bool {
    if (operation.kind == .prefab_override) return true;
    if (operation.kind == .sequence_order) return sequenceOrderSupported(operation);
    if (operation.kind == .field) {
        var saw_map = false;
        for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
            const present = value orelse continue;
            const node = present.node orelse return false;
            if (node.* != .map) return false;
            saw_map = true;
        }
        return saw_map;
    }
    if (operation.kind != .component and operation.kind != .document) return false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| if (value) |present| {
        const node = present.node orelse return false;
        if (node.* != .map) return false;
    };
    return true;
}

pub fn build(arena: std.mem.Allocator, operation: *const core.merge.Operation, resolution: core.merge.Resolution) !Model {
    if (operation.kind == .prefab_override) return buildPrefabOverride(arena, operation, resolution);
    if (operation.kind == .sequence_order) return buildSequenceOrder(arena, operation, resolution);
    if (operation.kind == .field) {
        const roots: [4]?*const Node = .{
            if (operation.values.base) |value| value.node else null,
            if (operation.values.ours) |value| value.node else null,
            if (operation.values.theirs) |value| value.node else null,
            switch (resolution) {
                .take => |side| if (operation.values.get(side)) |value| value.node else null,
                .custom => |text| try customFieldRoot(arena, operation, text),
                else => null,
            },
        };
        var builder: Builder = .{ .arena = arena, .documents = @splat(null) };
        try builder.walk(&.{}, "", roots);
        return .{ .documents = @splat(null), .rows = try builder.rows.toOwnedSlice(arena) };
    }
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

fn buildPrefabOverride(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !Model {
    const path_text = try core.displayPropertyPath(arena, operation.identity.property_path);
    const path_node = try scalarNode(arena, path_text);
    const rows = try arena.alloc(Row, 2);
    rows[0] = .{
        .path = try arena.dupe(properties.Segment, &.{.{ .key = "propertyPath" }}),
        .label = "Path",
        .values = .{ path_node, path_node, path_node, path_node },
        .changed = false,
    };
    rows[1] = .{
        .path = try arena.dupe(properties.Segment, &.{.{ .key = "value" }}),
        .label = "Value",
        .values = .{
            if (operation.values.base) |value| value.node else null,
            if (operation.values.ours) |value| value.node else null,
            if (operation.values.theirs) |value| value.node else null,
            switch (resolution) {
                .take => |side| if (operation.values.get(side)) |value| value.node else null,
                .custom => |text| if (std.mem.indexOfAny(u8, text, "\r\n") == null) try scalarNode(arena, text) else null,
                else => null,
            },
        },
        .changed = true,
    };
    return .{ .documents = @splat(null), .rows = rows };
}

fn sequenceOrderSupported(operation: *const core.merge.Operation) bool {
    var saw_seq = false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
        const present = value orelse continue;
        const node = present.node orelse return false;
        if (node.* != .seq) return false;
        saw_seq = true;
    }
    return saw_seq;
}

fn buildSequenceOrder(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !Model {
    const sides: [3]?*const Node = .{
        if (operation.values.base) |value| value.node else null,
        if (operation.values.ours) |value| value.node else null,
        if (operation.values.theirs) |value| value.node else null,
    };
    const result = try sequenceResultNode(arena, operation, resolution);
    var count: usize = 0;
    for (sides) |node| if (node) |seq| {
        if (seq.* == .seq) count = @max(count, seq.seq.len);
    };
    if (result) |seq| {
        if (seq.* == .seq) count = @max(count, seq.seq.len);
    }
    const rows = try arena.alloc(Row, count);
    for (rows, 0..) |*row, index| {
        var values: [4]?*const Node = .{
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[0], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[1], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[2], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(result, index)),
        };
        var changed = false;
        var first: ?*const Node = null;
        for (values[0..3]) |node| {
            if (first == null) {
                first = node;
            } else {
                changed = changed or !equal(first, node);
            }
        }
        row.* = .{
            .path = try arena.dupe(properties.Segment, &.{.{ .index = index }}),
            .label = try std.fmt.allocPrint(arena, "[{d}]", .{index}),
            .values = values,
            .changed = changed,
        };
    }
    return .{ .documents = @splat(null), .rows = rows };
}

fn sequenceResultNode(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !?*const Node {
    return switch (resolution) {
        .take => |side| if (operation.values.get(side)) |value| value.node else null,
        .custom => |text| parseSequenceResult(arena, text),
        .unresolved, .remove => null,
    };
}

fn parseSequenceResult(arena: std.mem.Allocator, text: []const u8) ?*const Node {
    const wrapped = std.fmt.allocPrint(arena, "items: {s}\n", .{text}) catch return null;
    const document = properties.parse(arena, wrapped) catch return null;
    const node = document.node(&.{.{ .key = "items" }}) orelse return null;
    return if (node.* == .seq) node else null;
}

fn sequenceItemAt(node: ?*const Node, index: usize) ?*const Node {
    const seq = node orelse return null;
    if (seq.* != .seq or index >= seq.seq.len) return null;
    return seq.seq[index];
}

fn sequenceItemLabelNode(arena: std.mem.Allocator, node: ?*const Node) !?*const Node {
    const item = node orelse return null;
    return try scalarNode(arena, try sequenceItemLabel(arena, item));
}

fn sequenceItemLabel(arena: std.mem.Allocator, node: *const Node) ![]const u8 {
    if (node.* == .map) {
        if (Node.asScalar(node.get("propertyPath"))) |path| return core.displayPropertyPath(arena, path);
    }
    return valueText(arena, node);
}

fn customFieldRoot(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    text: []const u8,
) !?*const Node {
    const template = operation.values.theirs orelse operation.values.ours orelse operation.values.base orelse return null;
    const node = template.node orelse return null;
    if (node.* != .map) return null;
    const scalar = customFieldScalar(text) orelse return null;
    const entries = try arena.dupe(core.model.Entry, node.map);
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.key, "value") or std.mem.eql(u8, entry.key, "second")) {
            const value_node = try arena.create(Node);
            value_node.* = .{ .scalar = scalar };
            entry.value = value_node;
        }
    }
    const copy = try arena.create(Node);
    copy.* = .{ .map = entries };
    return copy;
}

fn customFieldScalar(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") == null) return trimmed;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const content = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw, "\r"), " ");
        if (std.mem.startsWith(u8, content, "value:")) {
            found = std.mem.trim(u8, content["value:".len..], " ");
        }
    }
    return found;
}

fn scalarNode(arena: std.mem.Allocator, text: []const u8) !*const Node {
    const node = try arena.create(Node);
    node.* = .{ .scalar = text };
    return node;
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
                    if (path.len == 0 and core.isHiddenPropertyPath(entry.key)) continue;
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
        var any_document = false;
        for (self.documents) |document| if (document != null) {
            any_document = true;
        };
        var changed = if (any_document) self.documents[0] == null else false;
        if (any_document) {
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
        } else {
            for (nodes) |node| {
                if (compared) {
                    changed = changed or !equal(first, node);
                } else {
                    first = node;
                    compared = true;
                }
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
