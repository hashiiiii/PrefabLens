const std = @import("std");
const core = @import("core");
const properties = core.merge.properties;
const Node = core.model.Node;

pub fn at(root: ?*const Node, path: []const properties.Segment) ?*const Node {
    var node = root orelse return null;
    for (path) |segment| node = switch (segment) {
        .key => |key| if (node.* == .map) node.get(key) orelse return null else return null,
        .index => |index| if (node.* == .seq and index < node.seq.len) node.seq[index] else return null,
    };
    return node;
}

pub fn equal(a: ?*const Node, b: ?*const Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return Node.eql(a.?, b.?);
}

pub fn pathEqual(a: []const properties.Segment, b: []const properties.Segment) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        switch (left) {
            .key => |key| if (!std.mem.eql(u8, key, right.key)) return false,
            .index => |index| if (index != right.index) return false,
        }
    }
    return true;
}

pub fn replace(
    arena: std.mem.Allocator,
    root: *const Node,
    path: []const properties.Segment,
    value: ?*const Node,
) !*const Node {
    if (path.len == 0) return value orelse error.InvalidResolution;
    // Reordered ranges stay atomic. A Result index is not an item identity.
    if (path[0] != .key or root.* != .map) return error.InvalidResolution;
    const key = path[0].key;
    var entries: std.ArrayList(core.model.Entry) = .empty;
    var found = false;
    for (root.map) |entry| {
        if (!std.mem.eql(u8, entry.key, key)) {
            try entries.append(arena, entry);
            continue;
        }
        found = true;
        const changed = if (path.len == 1) value else try replace(arena, entry.value, path[1..], value);
        if (changed) |node| try entries.append(arena, .{ .key = entry.key, .value = @constCast(node) });
    }
    if (!found) {
        if (path.len != 1) return error.InvalidResolution;
        if (value) |node| try entries.append(arena, .{ .key = key, .value = @constCast(node) });
    }
    const result = try arena.create(Node);
    result.* = .{ .map = try entries.toOwnedSlice(arena) };
    return result;
}

pub fn edit(arena: std.mem.Allocator, root: *const Node, path: []const properties.Segment, template: *const Node, input: []const u8) ![]const u8 {
    const value = try properties.parseValue(arena, input);
    // A deleted preview field still inherits its serialized shape from a source.
    if (std.meta.activeTag(template.*) != std.meta.activeTag(value.*)) return error.InvalidResolution;
    return properties.valueText(arena, try replace(arena, root, path, value));
}

pub const Origin = enum {
    unchanged,
    both,
    ours,
    theirs,
    custom,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .unchanged => "Unchanged",
            .both => "Both",
            .ours => "Ours",
            .theirs => "Theirs",
            .custom => "Edited",
        };
    }
};

pub fn origin(values: [4]?*const Node) Origin {
    if (equal(values[3], values[0])) return .unchanged;
    const ours = equal(values[3], values[1]);
    const theirs = equal(values[3], values[2]);
    if (ours and theirs) return .both;
    if (ours) return .ours;
    if (theirs) return .theirs;
    return .custom;
}

pub fn omitted(values: [4]?*const Node, side: core.merge.Side) bool {
    const source = values[
        switch (side) {
            .base => return false,
            .ours => @as(usize, 1),
            .theirs => 2,
        }
    ];
    return !equal(source, values[0]) and !equal(source, values[3]);
}
