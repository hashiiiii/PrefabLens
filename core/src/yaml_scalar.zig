const std = @import("std");
pub const Error = std.mem.Allocator.Error || error{InvalidValue};

pub fn quote(arena: std.mem.Allocator, value: []const u8) Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var iterator = (std.unicode.Utf8View.init(value) catch return error.InvalidValue).iterator();
    try output.append(arena, '"');
    while (iterator.nextCodepointSlice()) |bytes| {
        const point = std.unicode.utf8Decode(bytes) catch return error.InvalidValue;
        switch (point) {
            '"', '\\' => {
                try output.append(arena, '\\');
                try output.append(arena, @intCast(point));
            },
            '\n' => try output.appendSlice(arena, "\\n"),
            '\r' => try output.appendSlice(arena, "\\r"),
            '\t' => try output.appendSlice(arena, "\\t"),
            else => if (point < 0x20 or (point >= 0x7f and point <= 0x9f) or point == 0x2028 or point == 0x2029 or
                point == 0xfeff or point == 0xfffe or point == 0xffff)
            {
                try output.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{point}));
            } else try output.appendSlice(arena, bytes),
        }
    }
    try output.append(arena, '"');
    return output.toOwnedSlice(arena);
}

pub fn decode(arena: std.mem.Allocator, scalar: []const u8) Error![]const u8 {
    if (scalar.len == 0 or (scalar[0] != '"' and scalar[0] != '\'')) return scalar;
    if (scalar.len < 2 or scalar[scalar.len - 1] != scalar[0]) return error.InvalidValue;
    const single = scalar[0] == '\'';
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < scalar.len) : (i += 1) {
        const ch = scalar[i];
        if (single) {
            if (ch == '\'') {
                i += 1;
                if (i + 1 >= scalar.len or scalar[i] != '\'') return error.InvalidValue;
            }
            try output.append(arena, ch);
        } else if (ch == '\\') {
            i += 1;
            if (i + 1 >= scalar.len) return error.InvalidValue;
            switch (scalar[i]) {
                '0' => try output.append(arena, 0),
                'a' => try output.append(arena, 7),
                'b' => try output.append(arena, 8),
                't', '\t' => try output.append(arena, '\t'),
                'n' => try output.append(arena, '\n'),
                'v' => try output.append(arena, 11),
                'f' => try output.append(arena, 12),
                'r' => try output.append(arena, '\r'),
                'e' => try output.append(arena, 27),
                ' ', '"', '/', '\\' => try output.append(arena, scalar[i]),
                'N' => try output.appendSlice(arena, "\xc2\x85"),
                '_' => try output.appendSlice(arena, "\xc2\xa0"),
                'L' => try output.appendSlice(arena, "\xe2\x80\xa8"),
                'P' => try output.appendSlice(arena, "\xe2\x80\xa9"),
                'x', 'u', 'U' => |escape| {
                    const digits: usize = switch (escape) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (i + digits + 1 >= scalar.len) return error.InvalidValue;
                    for (scalar[i + 1 ..][0..digits]) |digit| if (!std.ascii.isHex(digit)) return error.InvalidValue;
                    var point = std.fmt.parseInt(u21, scalar[i + 1 ..][0..digits], 16) catch return error.InvalidValue;
                    i += digits;
                    if (point >= 0xd800 and point <= 0xdbff and escape == 'u') {
                        if (i + 7 >= scalar.len or !std.mem.eql(u8, scalar[i + 1 ..][0..2], "\\u")) return error.InvalidValue;
                        for (scalar[i + 3 ..][0..4]) |digit| if (!std.ascii.isHex(digit)) return error.InvalidValue;
                        const low = std.fmt.parseInt(u21, scalar[i + 3 ..][0..4], 16) catch return error.InvalidValue;
                        if (low < 0xdc00 or low > 0xdfff) return error.InvalidValue;
                        point = 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00;
                        i += 6;
                    }
                    var encoded: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(point, &encoded) catch return error.InvalidValue;
                    try output.appendSlice(arena, encoded[0..length]);
                },
                else => return error.InvalidValue,
            }
        } else {
            if (ch == '"' or ch == '\r' or ch == '\n') return error.InvalidValue;
            try output.append(arena, ch);
        }
    }
    return output.toOwnedSlice(arena);
}

test "yaml scalar quote and decode round-trip special characters" {
    const cases = [_][]const u8{
        "plain",
        "quote \" and slash \\",
        "line\nfeed",
        "\x01\x7f",
    };
    for (cases) |value| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const quoted = try quote(arena_state.allocator(), value);
        try std.testing.expect(quoted.len >= 2);
        try std.testing.expectEqual(@as(u8, '"'), quoted[0]);
        try std.testing.expectEqualStrings(value, try decode(arena_state.allocator(), quoted));
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidValue, decode(arena, "\"bad\\q\""));
    try std.testing.expectEqualStrings("it's", try decode(arena, "'it''s'"));
}
