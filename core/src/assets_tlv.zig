// Decoder for the wasm asset buffer, a binary TLV (LE):
// [u32 count] repeat{ [u32 guid_len][guid][u32 data_len][data] }.
// Factored out of wasm.zig so the native test build can compile it:
// wasm.zig pins std.heap.wasm_allocator and only builds for wasm targets.
const std = @import("std");
const testing = std.testing;

const Assets = @import("instantiate.zig").Assets;

// A broken TLV returns error.TruncatedAssets; the wasm wrapper turns it
// into the error.v1 payload (no trap).
pub fn parseAssets(arena: std.mem.Allocator, bytes: []const u8) !Assets {
    var assets: Assets = .empty;
    if (bytes.len == 0) return assets;
    var off: usize = 0;
    const count = try readU32(bytes, &off);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const guid = try readChunk(bytes, &off);
        const data = try readChunk(bytes, &off);
        try assets.put(arena, guid, data);
    }
    return assets;
}

fn readU32(bytes: []const u8, off: *usize) !u32 {
    if (bytes.len - off.* < 4) return error.TruncatedAssets;
    const v = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn readChunk(bytes: []const u8, off: *usize) ![]const u8 {
    const len = try readU32(bytes, off);
    if (bytes.len - off.* < len) return error.TruncatedAssets;
    const s = bytes[off.*..][0..len];
    off.* += len;
    return s;
}

test "parseAssets: valid two-entry buffer round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Well-formed buffer: count=2 followed by two {guid, data} chunk pairs.
    // Every u32 is little-endian and every payload matches its length prefix,
    // so both entries must land in the map with their exact bytes.
    const bytes = [_]u8{
        2, 0, 0, 0, // count = 2
        2, 0, 0, 0, 'a', 'a', // guid "aa" (len 2 + payload)
        3, 0, 0, 0, 'A', 'A', 'A', // data "AAA" (len 3 + payload)
        2, 0, 0, 0, 'b', 'b', // guid "bb" (len 2 + payload)
        1, 0, 0, 0, 'B', // data "B" (len 1 + payload)
    };
    const assets = try parseAssets(arena, &bytes);
    try testing.expectEqual(2, assets.count());
    try testing.expectEqualStrings("AAA", assets.get("aa").?);
    try testing.expectEqualStrings("B", assets.get("bb").?);
}

test "parseAssets: empty buffer yields empty assets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A zero-length buffer is the "no assets supplied" fast path: it must
    // succeed with an empty map, not be rejected as a truncated count prefix.
    const assets = try parseAssets(arena, "");
    try testing.expectEqual(0, assets.count());
}

test "parseAssets: count-only buffer with zero entries yields empty assets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Well-formed 4-byte buffer holding count=0: the count prefix parses,
    // the entry loop runs zero times, and the result is an empty map.
    const bytes = [_]u8{ 0, 0, 0, 0 };
    const assets = try parseAssets(arena, &bytes);
    try testing.expectEqual(0, assets.count());
}

test "parseAssets: truncated count prefix fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Only 2 of the 4 bytes of the leading u32 count are present, so the
    // very first length-prefix read must fail with TruncatedAssets.
    const bytes = [_]u8{ 2, 0 };
    try testing.expectError(error.TruncatedAssets, parseAssets(arena, &bytes));
}

test "parseAssets: truncated chunk length prefix fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count=1 announces one {guid, data} pair, but the stream ends after
    // only 2 of the 4 bytes of the guid length prefix, so the mid-stream
    // length-prefix read must fail with TruncatedAssets.
    const bytes = [_]u8{ 1, 0, 0, 0, 4, 0 };
    try testing.expectError(error.TruncatedAssets, parseAssets(arena, &bytes));
}

test "parseAssets: truncated chunk payload fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // count=1 and the guid length prefix parses as 4, but only 2 payload
    // bytes follow, so the payload read must fail with TruncatedAssets.
    const bytes = [_]u8{ 1, 0, 0, 0, 4, 0, 0, 0, 'a', 'b' };
    try testing.expectError(error.TruncatedAssets, parseAssets(arena, &bytes));
}
