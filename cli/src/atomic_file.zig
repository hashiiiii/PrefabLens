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
    const stat = dir.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |existing| if (existing.kind != .file) return error.NotRegularFile;
    var atomic = try dir.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(atomic.file, io, &buffer);
    try writer.interface.writeAll(replacement);
    try writer.interface.flush();
    // Atomic replacement creates a new inode, so preserve the original file permissions.
    if (stat) |existing| try atomic.file.setPermissions(io, existing.permissions);
    try atomic.file.sync(io);

    if (expected) |bytes| {
        const current = dir.readFileAlloc(
            io,
            basename,
            arena,
            .limited(bytes.len + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.SourceChanged,
            else => return err,
        };
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

test "atomic file: retains executable permission during resolution" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "asset", .data = "before\n" });
    try tmp.dir.setFilePermissions(testing.io, "asset", .executable_file, .{});
    const before = try tmp.dir.statFile(testing.io, "asset", .{});
    const path = try tmp.dir.realPathFileAlloc(testing.io, "asset", arena);
    try replace(testing.io, arena, path, "before\n", "after\n");
    const after = try tmp.dir.statFile(testing.io, "asset", .{});
    // A content decision must not also change Git's executable mode.
    try testing.expectEqual(before.permissions, after.permissions);
}

test "atomic file: resolves marker output larger than one source input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const markers = try arena.alloc(u8, merge_io.max_input_bytes + 1);
    @memset(markers, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "merged.prefab", .data = markers });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "merged.prefab", arena);
    // diff3 can include all three source files, so its snapshot needs a separate output limit.
    const snapshot = try merge_io.readOutputLimited(testing.io, arena, path);
    try replace(testing.io, arena, path, snapshot, "resolved\n");
    try testing.expectEqualStrings("resolved\n", try merge_io.readLimited(testing.io, arena, path));
}
