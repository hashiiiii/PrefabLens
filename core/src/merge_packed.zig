const std = @import("std");
const testing = std.testing;

pub const Layout = enum { legacy, typed };
pub const Decoded = struct { values: []const i32, layout: Layout };
pub const Error = std.mem.Allocator.Error || error{InvalidEncoding};

// Callers must establish the declared int[] type before decoding a scalar token.
pub fn decodeInt32(arena: std.mem.Allocator, token: []const u8) Error!Decoded {
    const layout: Layout = if (std.mem.endsWith(u8, token, "i")) .typed else .legacy;
    const hex = if (layout == .typed) token[0 .. token.len - 1] else token;
    if (hex.len % 8 != 0) return error.InvalidEncoding;
    const values = try arena.alloc(i32, hex.len / 8);
    for (values, 0..) |*value, index| {
        var bytes: [4]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex[index * 8 ..][0..8]) catch return error.InvalidEncoding;
        value.* = std.mem.readInt(i32, &bytes, .little);
    }
    return .{ .values = values, .layout = layout };
}

pub fn encodeInt32(arena: std.mem.Allocator, values: []const i32, layout: Layout) std.mem.Allocator.Error![]const u8 {
    const token = try arena.alloc(u8, values.len * 8 + @intFromBool(layout == .typed));
    for (values, 0..) |value, index| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        @memcpy(token[index * 8 ..][0..8], &hex);
    }
    if (layout == .typed) token[token.len - 1] = 'i';
    return token;
}

test "packed int arrays retain signed values and their Unity suffix" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    // Signed limits detect byte-order and signedness errors that small values hide.
    const values = [_]i32{ 0, 1, -1, -2147483648, 2147483647 };
    const token = "0000000001000000ffffffff00000080ffffff7fi";
    const decoded = try decodeInt32(arena, token);
    try testing.expectEqualSlices(i32, &values, decoded.values);
    try testing.expectEqual(Layout.typed, decoded.layout);
    try testing.expectEqualStrings(token, try encodeInt32(arena, decoded.values, decoded.layout));
}

test "packed int arrays accept legacy encoding and empty values" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const decoded = try decodeInt32(arena, "0100000002000000");
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, decoded.values);
    try testing.expectEqual(Layout.legacy, decoded.layout);
    try testing.expectEqualStrings("0100000002000000", try encodeInt32(arena, decoded.values, .legacy));
    try testing.expectEqual(@as(usize, 0), (try decodeInt32(arena, "")).values.len);
    try testing.expectEqual(@as(usize, 0), (try decodeInt32(arena, "i")).values.len);
    try testing.expectEqualStrings("i", try encodeInt32(arena, &.{}, .typed));
    try testing.expectEqualStrings("", try encodeInt32(arena, &.{}, .legacy));
}

test "packed int arrays reject partial elements and other element types" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    // The caller proves int[] from schema. The codec must still reject another encoding.
    for ([_][]const u8{ "00", "0100000i", "01000000f", "0100000xi", " 01000000i", "01000000ii" }) |token| {
        try testing.expectError(error.InvalidEncoding, decodeInt32(arena, token));
    }
}
