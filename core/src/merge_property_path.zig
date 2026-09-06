const std = @import("std");
const testing = std.testing;

pub const Segment = union(enum) { field: []const u8, index: usize, size };
pub const Error = std.mem.Allocator.Error || error{InvalidPath};

pub fn parse(arena: std.mem.Allocator, input: []const u8) Error![]Segment {
    var result: std.ArrayList(Segment) = .empty;
    var parts: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, input, '.');
    while (iterator.next()) |part| {
        if (part.len == 0) return error.InvalidPath;
        for (part) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidPath;
        if (parts.items.len == 384) return error.InvalidPath;
        try parts.append(arena, part);
    }
    var i: usize = 0;
    while (i < parts.items.len) : (i += 1) {
        const part = parts.items[i];
        if (std.mem.eql(u8, part, "Array") and i + 1 < parts.items.len) {
            const next = parts.items[i + 1];
            if (std.mem.eql(u8, next, "size")) {
                if (result.items.len == 0 or i + 2 != parts.items.len) return error.InvalidPath;
                try result.append(arena, .size);
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, next, "data[")) {
                if (result.items.len == 0 or !std.mem.endsWith(u8, next, "]")) return error.InvalidPath;
                const number = next[5 .. next.len - 1];
                if (number.len == 0) return error.InvalidPath;
                for (number) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidPath;
                const index = std.fmt.parseInt(usize, number, 10) catch return error.InvalidPath;
                try result.append(arena, .{ .index = index });
                i += 1;
                continue;
            }
        }
        if (std.mem.indexOfAny(u8, part, "[]") != null) return error.InvalidPath;
        try result.append(arena, .{ .field = part });
    }
    return result.toOwnedSlice(arena);
}

pub fn format(arena: std.mem.Allocator, path: []const Segment) std.mem.Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (path, 0..) |segment, i| {
        if (i != 0) try result.append(arena, '.');
        switch (segment) {
            .field => |field| try result.appendSlice(arena, field),
            .index => |index| try result.appendSlice(arena, try std.fmt.allocPrint(arena, "Array.data[{d}]", .{index})),
            .size => try result.appendSlice(arena, "Array.size"),
        }
    }
    return result.toOwnedSlice(arena);
}

pub fn collectionRoot(arena: std.mem.Allocator, input: []const u8) Error!?[]const u8 {
    const path = try parse(arena, input);
    for (path, 0..) |segment, i| {
        if (segment == .index or segment == .size) return try format(arena, path[0..i]);
    }
    return null;
}

test "override paths distinguish collection indices from ordinary field names" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const path = try parse(arena, "items.Array.data[12].speed");
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqualStrings("items", path[0].field);
    try testing.expectEqual(@as(usize, 12), path[1].index);
    try testing.expectEqualStrings("speed", path[2].field);
    // Grouping by a string prefix would also include these unrelated fields.
    try testing.expectEqualStrings("ArrayLength", (try parse(arena, "items.ArrayLength"))[1].field);
    try testing.expectEqualStrings("Array", (try parse(arena, "items.Array.value"))[1].field);
    try testing.expectEqualStrings("items", (try collectionRoot(arena, "items.Array.data[12].speed")).?);
    try testing.expectEqual(@as(?[]const u8, null), try collectionRoot(arena, "items.ArrayLength"));
}

test "override paths preserve nested roots and rewrite chosen indices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const path = try parse(arena, "config.items.Array.data[01].values.Array.size");
    try testing.expectEqualStrings("config.items", (try collectionRoot(arena, "config.items.Array.data[01].values.Array.size")).?);
    path[2] = .{ .index = 4 };
    try testing.expectEqualStrings("config.items.Array.data[4].values.Array.size", try format(arena, path));
    try testing.expectEqualStrings("items.Array.data[0]", try format(arena, try parse(arena, "items.Array.data[0]")));
}

test "override paths reject malformed indices and nonterminal sizes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    // Invalid paths must not be ignored, since that would discard an explicit override.
    for ([_][]const u8{ "", ".items", "items.", "items..speed", "items.Array.data[-1]", "items.Array.data[]", "items.Array.data[1x]", "items.Array.data[1]tail", "items.Array.data[999999999999999999999999]", "items.Array.size.speed", "items.Array.data[1", "items.\x00name" }) |input| {
        try testing.expectError(error.InvalidPath, parse(arena, input));
    }
}
