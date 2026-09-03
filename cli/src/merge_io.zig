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
    try stderr.print("prefablens: Merge failed for {s}. PrefabLens did not write the output.\n", .{path});
    return 2;
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
