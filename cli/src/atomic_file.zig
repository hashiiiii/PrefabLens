const std = @import("std");
const merge_io = @import("merge_io.zig");
const testing = std.testing;

pub fn replace(
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
    expected: ?[]const u8,
    replacement: []const u8,
) !void {
    const directory_path = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    const dir = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(atomic.file, io, &buffer);
    try writer.interface.writeAll(replacement);
    try writer.interface.flush();
    try atomic.file.sync(io);

    if (expected) |bytes| {
        const current = try dir.readFileAlloc(
            io,
            basename,
            arena,
            .limited(merge_io.max_input_bytes),
        );
        if (!std.mem.eql(u8, current, bytes)) return error.SourceChanged;
    }
    try atomic.replace(io);
}

test "atomic file: replaces only the expected target bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "merged.prefab", .data = "before\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ root, "merged.prefab" });

    try replace(testing.io, arena, path, "before\n", "after\n");
    try testing.expectEqualStrings(
        "after\n",
        try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64)),
    );
}

test "atomic file: preserves a target changed by another process" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Linux requires an iterable directory handle before the test can scan for leaked files.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "merged.prefab", .data = "external\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ root, "merged.prefab" });

    try testing.expectError(
        error.SourceChanged,
        replace(testing.io, arena, path, "before\n", "result\n"),
    );
    try testing.expectEqualStrings(
        "external\n",
        try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64)),
    );
    var iterator = tmp.dir.iterate();
    var entries: usize = 0;
    while (try iterator.next(testing.io)) |entry| {
        entries += 1;
        try testing.expectEqualStrings("merged.prefab", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), entries);
}
