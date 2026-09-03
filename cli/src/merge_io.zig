const std = @import("std");
const input = @import("input.zig");
const testing = std.testing;

pub const max_input_bytes = input.max_input_bytes;

pub fn readLimited(
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_input_bytes));
}

pub fn reportFailure(stderr: *std.Io.Writer, path: []const u8) !u8 {
    try stderr.writeAll("prefablens: Merge failed for ");
    try writeSafePath(stderr, path);
    try stderr.writeAll(". PrefabLens did not write the output.\n");
    return 2;
}

fn writeSafePath(stderr: *std.Io.Writer, path: []const u8) !void {
    var index: usize = 0;
    while (index < path.len) {
        const byte = path[index];
        if (byte < 0x80) {
            if (byte == '\n') {
                try stderr.writeAll("\\n");
            } else if (byte == '\r') {
                try stderr.writeAll("\\r");
            } else if (byte == '\t') {
                try stderr.writeAll("\\t");
            } else if (byte < 0x20 or byte == 0x7f) {
                try writeUnicodeEscape(stderr, byte);
            } else {
                try stderr.writeByte(byte);
            }
            index += 1;
            continue;
        }

        const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writeByteEscape(stderr, byte);
            index += 1;
            continue;
        };
        const end = index + @as(usize, sequence_length);
        if (end > path.len) {
            try writeByteEscape(stderr, byte);
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(path[index..end]) catch {
            try writeByteEscape(stderr, byte);
            index += 1;
            continue;
        };
        if (isUnsafeCodepoint(codepoint)) {
            try writeUnicodeEscape(stderr, codepoint);
        } else {
            try stderr.writeAll(path[index..end]);
        }
        index = end;
    }
}

fn isUnsafeCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x80 and codepoint <= 0x9f) or
        codepoint == 0x2028 or codepoint == 0x2029 or
        // These format controls can change how a terminal displays the path.
        codepoint == 0x061c or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2060 and codepoint <= 0x2064) or
        (codepoint >= 0x2066 and codepoint <= 0x206f) or
        codepoint == 0xfeff;
}

fn writeUnicodeEscape(stderr: *std.Io.Writer, codepoint: u21) !void {
    const hex = "0123456789abcdef";
    var digits: [4]u8 = undefined;
    digits[0] = hex[@as(usize, @intCast((codepoint >> 12) & 0xf))];
    digits[1] = hex[@as(usize, @intCast((codepoint >> 8) & 0xf))];
    digits[2] = hex[@as(usize, @intCast((codepoint >> 4) & 0xf))];
    digits[3] = hex[@as(usize, @intCast(codepoint & 0xf))];
    try stderr.writeAll("\\u");
    try stderr.writeAll(&digits);
}

fn writeByteEscape(stderr: *std.Io.Writer, byte: u8) !void {
    const hex = "0123456789abcdef";
    try stderr.writeAll("\\x");
    try stderr.writeByte(hex[byte >> 4]);
    try stderr.writeByte(hex[byte & 0xf]);
}

test "merge I/O: reports one stable failure line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    try testing.expectEqual(@as(u8, 2), try reportFailure(&stderr.writer, "Assets/A.prefab"));
    try testing.expectEqualStrings(
        "prefablens: Merge failed for Assets/A.prefab. PrefabLens did not write the output.\n",
        stderr.toArrayList().items,
    );
}

test "merge I/O: escapes path separators and controls in one line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);
    const path = "Assets/merged\r\nname\u{0085}\u{2028}\u{2029}\x00\x01\t.prefab";

    try testing.expectEqual(@as(u8, 2), try reportFailure(&stderr.writer, path));
    try testing.expectEqualStrings(
        "prefablens: Merge failed for Assets/merged\\r\\nname\\u0085\\u2028\\u2029\\u0000\\u0001\\t.prefab. PrefabLens did not write the output.\n",
        stderr.toArrayList().items,
    );
}
