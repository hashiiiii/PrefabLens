const std = @import("std");
const model = @import("model.zig");

pub const Shape = enum { pair_key_value, pair_first_second, parallel };
pub const Detected = union(enum) { none, malformed, shape: Shape };
pub const Entry = struct {
    key: *const model.Node,
    value: *const model.Node,
    item: *const model.Node,
};

pub const PairFields = struct { key: []const u8, value: []const u8 };

pub fn pairFields(shape: Shape) ?PairFields {
    return switch (shape) {
        .pair_key_value => .{ .key = "key", .value = "value" },
        .pair_first_second => .{ .key = "first", .value = "second" },
        .parallel => null,
    };
}

pub fn detect(base: ?*const model.Node, ours: ?*const model.Node, theirs: ?*const model.Node) Detected {
    var found: ?Shape = null;
    for ([_]?*const model.Node{ base, ours, theirs }) |optional| {
        const node = optional orelse continue;
        switch (nodeShape(node)) {
            .none => {
                if (node.* == .seq or node.* == .map) continue;
                if (found != null) return .malformed;
            },
            .malformed => return .malformed,
            .shape => |shape| {
                if (found) |previous| {
                    if (previous != shape) return .malformed;
                } else found = shape;
            },
        }
    }
    return if (found) |shape| .{ .shape = shape } else .none;
}

fn nodeShape(node: *const model.Node) Detected {
    if (node.* == .seq) return sequenceShape(node.seq);
    if (node.* == .map) return parallelShape(node);
    return .none;
}

fn sequenceShape(items: []const *model.Node) Detected {
    if (items.len == 0) return .none;
    var found: ?Shape = null;
    var non_pair = false;
    for (items, 0..) |item, index| {
        const shape = pairShape(item) orelse {
            non_pair = true;
            continue;
        };
        if (found) |previous| {
            if (previous != shape) return .malformed;
        } else found = shape;
        const key = pairKey(item, shape) orelse return .malformed;
        for (items[0..index]) |previous| {
            const previous_shape = pairShape(previous) orelse continue;
            const previous_key = pairKey(previous, previous_shape) orelse return .malformed;
            if (model.Node.eql(previous_key, key)) return .malformed;
        }
    }
    if (found == null) return .none;
    if (non_pair) return .malformed;
    return .{ .shape = found.? };
}

fn pairShape(item: *const model.Node) ?Shape {
    if (item.* != .map) return null;
    const has_key = model.findValue(item.map, "key") != null;
    const has_value = model.findValue(item.map, "value") != null;
    const has_first = model.findValue(item.map, "first") != null;
    const has_second = model.findValue(item.map, "second") != null;
    if (has_key and has_value and !has_first and !has_second) return .pair_key_value;
    if (has_first and has_second and !has_key and !has_value) return .pair_first_second;
    return null;
}

fn pairKey(item: *const model.Node, shape: Shape) ?*const model.Node {
    const fields = pairFields(shape) orelse return null;
    return model.findValue(item.map, fields.key);
}

pub fn pairValue(item: *const model.Node, shape: Shape) ?*const model.Node {
    const fields = pairFields(shape) orelse return null;
    return model.findValue(item.map, fields.value);
}

fn parallelShape(node: *const model.Node) Detected {
    const keys = node.get("m_Keys") orelse return .none;
    const values = node.get("m_Values") orelse return .none;
    if (keys.* != .seq or values.* != .seq) return .none;
    if (keys.seq.len != values.seq.len) return .malformed;
    return .{ .shape = .parallel };
}

pub fn entries(arena: std.mem.Allocator, node: ?*const model.Node, shape: Shape) std.mem.Allocator.Error!?[]Entry {
    const value = node orelse return &.{};
    return switch (shape) {
        .pair_key_value, .pair_first_second => pairEntries(arena, value, shape),
        .parallel => parallelEntries(arena, value),
    };
}

fn pairEntries(arena: std.mem.Allocator, node: *const model.Node, shape: Shape) std.mem.Allocator.Error!?[]Entry {
    if (node.* != .seq) return null;
    const fields = pairFields(shape).?;
    const result = try arena.alloc(Entry, node.seq.len);
    for (node.seq, result) |item, *entry| {
        if (item.* != .map) return null;
        entry.* = .{
            .key = model.findValue(item.map, fields.key) orelse return null,
            .value = model.findValue(item.map, fields.value) orelse return null,
            .item = item,
        };
    }
    return result;
}

fn parallelEntries(arena: std.mem.Allocator, node: *const model.Node) std.mem.Allocator.Error!?[]Entry {
    if (node.* != .map) return null;
    const keys = node.get("m_Keys") orelse return null;
    const values = node.get("m_Values") orelse return null;
    if (keys.* != .seq or values.* != .seq or keys.seq.len != values.seq.len) return null;
    const result = try arena.alloc(Entry, keys.seq.len);
    for (keys.seq, values.seq, result) |key, value, *entry| {
        entry.* = .{ .key = key, .value = value, .item = value };
    }
    return result;
}

pub fn find(list: []const Entry, key: *const model.Node) ?Entry {
    for (list) |entry| {
        if (model.Node.eql(entry.key, key)) return entry;
    }
    return null;
}

pub fn contains(list: []const Entry, key: *const model.Node) bool {
    return find(list, key) != null;
}

pub fn keyPath(arena: std.mem.Allocator, prefix: []const u8, key: *const model.Node) std.mem.Allocator.Error![]const u8 {
    const bracket = try keyBracket(arena, key);
    if (prefix.len == 0) return bracket;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, bracket });
}

pub fn keyBracket(arena: std.mem.Allocator, key: *const model.Node) std.mem.Allocator.Error![]const u8 {
    if (key.* == .scalar) {
        if (std.mem.indexOfAny(u8, key.scalar, "[]\"") == null)
            return std.fmt.allocPrint(arena, "[{s}]", .{key.scalar});
        return std.fmt.allocPrint(arena, "[\"{s}\"]", .{key.scalar});
    }
    return "[key]";
}

pub fn sharedOrderChanged(side: []const Entry, base: []const Entry) bool {
    var side_i: usize = 0;
    var base_i: usize = 0;
    while (true) {
        while (side_i < side.len and find(base, side[side_i].key) == null) side_i += 1;
        while (base_i < base.len and find(side, base[base_i].key) == null) base_i += 1;
        if (side_i == side.len or base_i == base.len) return side_i != side.len or base_i != base.len;
        if (!model.Node.eql(side[side_i].key, base[base_i].key)) return true;
        side_i += 1;
        base_i += 1;
    }
}
