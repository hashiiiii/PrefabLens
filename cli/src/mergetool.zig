const std = @import("std");
const core = @import("core");

const command = @import("command.zig");
const atomic_file = @import("atomic_file.zig");
const merge_io = @import("merge_io.zig");
const merge_tui = @import("merge_tui.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const merge_git = @import("merge_git.zig");
const session_context = @import("merge_session_context.zig");
const revision = @import("merge_revision.zig");
const testing = std.testing;

pub const Prepared = struct {
    args: command.MergetoolArgs,
    original_merged: []const u8,
    built: core.merge.BuildResult,
    source_index: ?session_context.Index = null,
    git: ?merge_git.Git = null,
};

pub fn prepare(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergetoolArgs,
) !Prepared {
    return prepareWithGit(io, arena, args, null);
}

pub fn prepareWithGit(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergetoolArgs,
    git: ?merge_git.Git,
) !Prepared {
    // The worktree can contain Git markers or manual edits, independent of the internal plan.
    const merged = try merge_io.readOutputLimited(io, arena, args.merged);
    const base = try merge_io.readLimited(io, arena, args.base);
    const local = try merge_io.readLimited(io, arena, args.local);
    const remote = try merge_io.readLimited(io, arena, args.remote);
    var context: core.merge_context.Context = .{};
    var source_index: ?session_context.Index = null;
    if (git) |repository| {
        const revisions = session_context.discover(repository) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (revisions) |sources| {
            if (try trackedPath(repository, args.merged)) |path| {
                var store = revision.Store.init(repository);
                defer store.deinit();
                const bound = session_context.bind(&store, sources, .{ .base = path, .ours = path, .theirs = path }, .{ .base = base, .ours = local, .theirs = remote }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                };
                if (bound) |known| {
                    context = known;
                    source_index = try session_context.readIndex(&store);
                    context.output = source_index.?.snapshot;
                }
            }
        }
    }
    const built = try core.merge.buildWithContext(arena, base, local, remote, context);
    return .{ .args = args, .original_merged = merged, .built = built, .source_index = source_index, .git = git };
}

fn trackedPath(git: merge_git.Git, path: []const u8) !?[]const u8 {
    const result = try git.run(&.{ "--literal-pathspecs", "ls-files", "--error-unmatch", "--full-name", "--deduplicate", "-z", "--", path });
    if (merge_git.exitCode(result) != 0 or result.stdout.len == 0 or std.mem.count(u8, result.stdout, "\x00") != 1) return null;
    if (result.stdout[result.stdout.len - 1] != 0) return null;
    return result.stdout[0 .. result.stdout.len - 1];
}

const SourceLock = struct {
    file: std.Io.File,
    path: []const u8,

    fn deinit(self: SourceLock, io: std.Io) void {
        self.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
    }
};

fn lockSources(io: std.Io, arena: std.mem.Allocator, prepared: *const Prepared) !?SourceLock {
    const source = prepared.source_index orelse return null;
    const path = try std.fmt.allocPrint(arena, "{s}.lock", .{source.path});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    const lock: SourceLock = .{ .file = file, .path = path };
    errdefer lock.deinit(io);
    // Hold the index lock through the output write, so no source decision can
    // change between this check and acceptance of the dependent result.
    try source.unchanged(prepared.git.?);
    return lock;
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
    const source_lock = lockSources(io, arena, prepared) catch
        return merge_io.reportFailure(stderr, prepared.args.merged);
    defer if (source_lock) |lock| lock.deinit(io);
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
    const git: merge_git.Git = .{ .io = io, .arena = arena, .env = env_map };
    if (@import("merge_unknown_context.zig").inMerge(git) catch false) {
        const before = try merge_io.readOutputLimited(io, arena, args.merged);
        const local = try merge_io.readLimited(io, arena, args.local);
        const remote = try merge_io.readLimited(io, arena, args.remote);
        var store = revision.Store.init(git);
        defer store.deinit();
        const captured = try session_context.readIndex(&store);
        const selected = (try @import("merge_unknown_context.zig").choose(git, env_map, args.merged, local, remote)) orelse return 1;
        const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{captured.path});
        const lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .exclusive = true });
        const lock: SourceLock = .{ .file = lock_file, .path = lock_path };
        defer lock.deinit(io);
        try captured.unchanged(git);
        try atomic_file.replace(io, arena, args.merged, before, selected);
        return 0;
    }
    var prepared = prepareWithGit(io, arena, args, .{ .io = io, .arena = arena, .env = env_map }) catch
        return merge_io.reportFailure(stderr, args.merged);
    var state = merge_ui_state.State.init(arena, &prepared.built.plan) catch
        return merge_io.reportFailure(stderr, args.merged);
    if (state.outcome != .ready) {
        merge_tui.run(io, arena, env_map, &state, args.merged, prepared.built.partial, prepared.original_merged) catch
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
        .data = try std.fmt.allocPrint(arena, "<<<<<<< ours\n{s}=======\n{s}>>>>>>> theirs\n", .{
            try readFixture(arena, "component-delete-edit/ours.prefab"),
            try readFixture(arena, "component-delete-edit/theirs.prefab"),
        }),
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

test "mergetool: snapshots worktree bytes independently from the semantic partial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const args = try fixtureArgs(&tmp, arena);
    try writeMerged(args, "manual edit\n");
    const prepared = try prepare(testing.io, arena, args);
    try testing.expectEqualStrings("manual edit\n", prepared.original_merged);
    try testing.expect(prepared.built.plan.unresolvedCount() != 0);
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
    const expected = try readFixture(arena, "component-delete-edit/expected.prefab");
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    const code = try finish(testing.io, arena, &prepared, &state, &stderr.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings(expected, try readMerged(arena, args));
}

test "mergetool: revision context and source index guard protect the result" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", "/usr/bin:/bin");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const git: merge_git.Git = .{ .io = testing.io, .arena = arena, .env = &env, .cwd = root };
    try git.ok(&.{ "init", "-q" });
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try git.ok(&.{ "config", "commit.gpgsign", "false" });
    const guid = "11111111111111111111111111111111";
    const script = "using UnityEngine; class Example : MonoBehaviour { public int[] values; }";
    try tmp.dir.createDir(testing.io, "Assets", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs", .data = script });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs.meta", .data = "guid: " ++ guid ++ "\n" });
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ guid ++ ", type: 3}\n  values: ";
    const inputs = [_][]const u8{ prefix ++ "01000000i\n", prefix ++ "0000000001000000i\n", prefix ++ "0100000002000000i\n" };
    var revisions: [3][]const u8 = undefined;
    for (inputs, 0..) |bytes, i| {
        if (i == 2) try git.ok(&.{ "checkout", "-q", "--detach", revisions[0] });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/A.prefab", .data = bytes });
        try git.ok(&.{ "add", "--all" });
        try git.ok(&.{ "commit", "-qm", "fixture" });
        revisions[i] = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    }
    try git.ok(&.{ "checkout", "-q", "--detach", revisions[1] });
    try testing.expectEqual(@as(u8, 1), merge_git.exitCode(try git.run(&.{ "merge", "--no-commit", revisions[2] })));
    for ([_][]const u8{ "base", "local", "remote" }, inputs) |path, bytes| try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
    const args: command.MergetoolArgs = .{ .base = try git.path("base"), .local = try git.path("local"), .remote = try git.path("remote"), .merged = try git.path("Assets/A.prefab") };
    var prepared = try prepareWithGit(testing.io, arena, args, git);
    try testing.expect(prepared.source_index != null);
    try testing.expectEqualStrings(prefix ++ "000000000100000002000000i\n", prepared.built.partial);
    const original = try readMerged(arena, args);
    var state = try merge_ui_state.State.init(arena, &prepared.built.plan);
    var stderr = std.Io.Writer.Allocating.init(arena);
    // A source choice made while the UI was open invalidates its historical assumptions.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs", .data = "using UnityEngine; class Example : MonoBehaviour { public string[] values; }" });
    try git.ok(&.{ "add", "--", "Assets/Example.cs" });
    try testing.expectEqual(@as(u8, 2), try finish(testing.io, arena, &prepared, &state, &stderr.writer));
    try testing.expectEqualStrings(original, try readMerged(arena, args));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs", .data = script });
    try git.ok(&.{ "add", "--", "Assets/Example.cs" });
    prepared = try prepareWithGit(testing.io, arena, args, git);
    state = try merge_ui_state.State.init(arena, &prepared.built.plan);
    // Another index writer must finish before this result can be accepted.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/index.lock", .data = "another process" });
    try testing.expectEqual(@as(u8, 2), try finish(testing.io, arena, &prepared, &state, &stderr.writer));
    try testing.expectEqualStrings(original, try readMerged(arena, args));
    try testing.expectEqualStrings("another process", try tmp.dir.readFileAlloc(testing.io, ".git/index.lock", arena, .limited(1024)));
    try tmp.dir.deleteFile(testing.io, ".git/index.lock");
    try testing.expectEqual(@as(u8, 0), try finish(testing.io, arena, &prepared, &state, &stderr.writer));
    try testing.expectEqualStrings(prefix ++ "000000000100000002000000i\n", try readMerged(arena, args));
    // Git's mergetool caller still owns staging the resolved file.
    try testing.expect((try git.output(&.{ "ls-files", "--unmerged", "-z" })).len != 0);
}
