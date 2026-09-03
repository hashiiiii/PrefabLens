const std = @import("std");
const core = @import("core");

const command = @import("command.zig");
const atomic_file = @import("atomic_file.zig");
const merge_io = @import("merge_io.zig");
const merge_tui = @import("merge_tui.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const testing = std.testing;

pub const Prepared = struct {
    args: command.MergetoolArgs,
    original_merged: []const u8,
    built: core.merge.BuildResult,
};

pub fn prepare(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergetoolArgs,
) !Prepared {
    const base = try merge_io.readLimited(io, arena, args.base);
    const local = try merge_io.readLimited(io, arena, args.local);
    const remote = try merge_io.readLimited(io, arena, args.remote);
    const built = try core.merge.build(arena, base, local, remote);
    const merged = try merge_io.readLimited(io, arena, args.merged);
    if (!std.mem.eql(u8, built.partial, merged)) return error.PartialMismatch;
    return .{ .args = args, .original_merged = merged, .built = built };
}

pub fn finish(
    io: std.Io,
    arena: std.mem.Allocator,
    prepared: *Prepared,
    state: *merge_ui_state.State,
    stderr: *std.Io.Writer,
) !u8 {
    if (state.outcome == .aborted) return 1;
    if (state.outcome != .ready) return merge_io.reportFailure(stderr, prepared.args.merged);
    const result = core.merge.finish(arena, &prepared.built.plan) catch
        return merge_io.reportFailure(stderr, prepared.args.merged);
    atomic_file.replace(
        io,
        arena,
        prepared.args.merged,
        prepared.original_merged,
        result,
    ) catch return merge_io.reportFailure(stderr, prepared.args.merged);
    return 0;
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergetoolArgs,
    env_map: *std.process.Environ.Map,
    stdin_tty: bool,
    stdout_tty: bool,
    stderr: *std.Io.Writer,
) !u8 {
    if (!stdin_tty or !stdout_tty) return merge_io.reportFailure(stderr, args.merged);
    var prepared = prepare(io, arena, args) catch
        return merge_io.reportFailure(stderr, args.merged);
    var state = merge_ui_state.State.init(arena, &prepared.built.plan) catch
        return merge_io.reportFailure(stderr, args.merged);
    if (state.outcome != .ready) {
        merge_tui.run(io, arena, env_map, &state, args.merged) catch
            return merge_io.reportFailure(stderr, args.merged);
    }
    return finish(io, arena, &prepared, &state, stderr);
}

fn fixturePath(arena: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    const fixture_root = @import("test_options").fixture_root;
    return std.fs.path.join(arena, &.{ fixture_root, sub_path });
}

fn readFixture(arena: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return merge_io.readLimited(testing.io, arena, try fixturePath(arena, sub_path));
}

fn fixtureArgs(
    tmp: *testing.TmpDir,
    arena: std.mem.Allocator,
) !command.MergetoolArgs {
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "base.prefab",
        .data = try readFixture(arena, "component-delete-edit/base.prefab"),
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "local.prefab",
        .data = try readFixture(arena, "component-delete-edit/ours.prefab"),
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "remote.prefab",
        .data = try readFixture(arena, "component-delete-edit/theirs.prefab"),
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "merged.prefab",
        .data = try readFixture(arena, "component-delete-edit/partial.prefab"),
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    return .{
        .base = try std.fs.path.join(arena, &.{ root, "base.prefab" }),
        .local = try std.fs.path.join(arena, &.{ root, "local.prefab" }),
        .remote = try std.fs.path.join(arena, &.{ root, "remote.prefab" }),
        .merged = try std.fs.path.join(arena, &.{ root, "merged.prefab" }),
    };
}

fn readMerged(arena: std.mem.Allocator, args: command.MergetoolArgs) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        args.merged,
        arena,
        .limited(merge_io.max_input_bytes),
    );
}

fn writeMerged(args: command.MergetoolArgs, bytes: []const u8) !void {
    return std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = args.merged,
        .data = bytes,
    });
}

test "mergetool: rejects non-TTY input before reading or writing merged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    const original = try readMerged(arena, args);
    var env = std.process.Environ.Map.init(arena);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try run(testing.io, arena, args, &env, false, true, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqualStrings(original, try readMerged(arena, args));
}

test "mergetool: rejects a merged file that differs from the driver partial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    try writeMerged(args, "manual edit\n");
    var env = std.process.Environ.Map.init(arena);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try run(testing.io, arena, args, &env, true, true, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqualStrings("manual edit\n", try readMerged(arena, args));
}

test "mergetool: abort keeps merged byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    var prepared = try prepare(testing.io, arena, args);
    var state = try merge_ui_state.State.init(arena, &prepared.built.plan);
    const original = try arena.dupe(u8, prepared.original_merged);
    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    try testing.expectEqualStrings(original, try readMerged(arena, args));
    try state.handle(.abort);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try finish(testing.io, arena, &prepared, &state, &stderr.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqualStrings(original, try readMerged(arena, args));
}

test "mergetool: detects a change before atomic replace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    var prepared = try prepare(testing.io, arena, args);
    var state = try merge_ui_state.State.init(arena, &prepared.built.plan);
    var steps: usize = 0;
    while (state.unresolvedCount() != 0) : (steps += 1) {
        // A broken state transition must fail this test instead of hanging the whole test runner.
        try testing.expect(steps < 16);
        // Ours deletes this component, so Theirs is the side with a valid value for this fixture.
        try state.handle(.choose_theirs);
        try state.handle(.apply_result);
    }
    try writeMerged(args, "other process\n");
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try finish(testing.io, arena, &prepared, &state, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqualStrings("other process\n", try readMerged(arena, args));
}

test "mergetool: finish writes a validated resolution" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    var prepared = try prepare(testing.io, arena, args);
    var state = try merge_ui_state.State.init(arena, &prepared.built.plan);
    var steps: usize = 0;
    while (state.unresolvedCount() != 0) : (steps += 1) {
        // A broken state transition must fail this test instead of hanging the whole test runner.
        try testing.expect(steps < 16);
        // Ours deletes this component, so Theirs is the side with a valid value for this fixture.
        try state.handle(.choose_theirs);
        try state.handle(.apply_result);
    }
    const expected = try core.merge.finish(arena, &prepared.built.plan);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try finish(testing.io, arena, &prepared, &state, &stderr.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings(expected, try readMerged(arena, args));
}
