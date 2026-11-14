const std = @import("std");
const atomic_file = @import("atomic_file.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

pub const Revisions = struct {
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
};

const Stored = struct {
    revisions: Revisions,
    head: []const u8,
    message: []const u8,
};

const format = "prefablens-replay-context-v1";
const max_file_bytes = 16 * 1024 * 1024;
const max_record_bytes = 4096;
const operation_markers = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD" };

pub fn save(git: Git, revisions: Revisions) !bool {
    if (!validOid(revisions.base) or !validOid(revisions.ours) or !validOid(revisions.theirs)) return false;
    if (!try validSnapshot(git, revisions.base) or !try validSnapshot(git, revisions.ours) or !try validSnapshot(git, revisions.theirs)) return false;
    if (!try noOperationMarkers(git)) return false;
    const message = (try fileFingerprint(git, "MERGE_MSG")) orelse return false;
    const head = merge_git.trim(try git.output(&.{ "rev-parse", "--verify", "HEAD^{commit}" }));
    if (!validOid(head) or !try hasUnmergedPaths(git)) return false;
    const bytes = try encode(git.arena, revisions, head, message);
    if (bytes.len > max_record_bytes) return false;
    const path = try contextPath(git);
    const existing = std.Io.Dir.cwd().readFileAlloc(git.io, path, git.arena, .limited(max_record_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => return false,
        else => return err,
    };
    try atomic_file.replace(git.io, git.arena, path, existing, bytes);
    return true;
}

pub fn discover(git: Git) !?Revisions {
    const stored = (try load(git)) orelse return null;
    if (!try noOperationMarkers(git)) return null;
    const message = (try fileFingerprint(git, "MERGE_MSG")) orelse return null;
    if (!std.mem.eql(u8, stored.message, message)) return null;
    const head = merge_git.trim(try git.output(&.{ "rev-parse", "--verify", "HEAD^{commit}" }));
    if (!std.mem.eql(u8, stored.head, head) or !try hasUnmergedPaths(git)) return null;
    return stored.revisions;
}

fn load(git: Git) !?Stored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(git.io, try contextPath(git), git.arena, .limited(max_record_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    return parse(bytes) catch null;
}

fn noOperationMarkers(git: Git) !bool {
    for (operation_markers) |name| if (try fileFingerprint(git, name) != null) return false;
    return true;
}

fn hasUnmergedPaths(git: Git) !bool {
    const result = try git.run(&.{ "ls-files", "--unmerged", "--full-name", "-z" });
    if (merge_git.exitCode(result) != 0) return error.GitFailed;
    return result.stdout.len != 0;
}

fn fileFingerprint(git: Git, name: []const u8) !?[]const u8 {
    const path = try gitPath(git, name);
    const cwd = std.Io.Dir.cwd();
    const before = cwd.statFile(git.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (before.kind != .file) return error.InvalidReplayFile;
    const limit: usize = if (std.mem.eql(u8, name, "MERGE_MSG")) max_file_bytes else 4096;
    const bytes = try cwd.readFileAlloc(git.io, path, git.arena, .limited(limit));
    const after = try cwd.statFile(git.io, path, .{ .follow_symlinks = false });
    if (!sameFile(before, after) or bytes.len != after.size) return error.SourceChanged;
    const digest = try digestHex(git.arena, bytes);
    return try std.fmt.allocPrint(git.arena, "{d}:{d}:{d}:{d}:{s}", .{
        before.inode,
        before.size,
        before.mtime.nanoseconds,
        before.ctime.nanoseconds,
        digest,
    });
}

fn sameFile(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == .file and b.kind == .file and a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn validSnapshot(git: Git, revision: []const u8) !bool {
    const result = try git.run(&.{ "rev-parse", "--verify", "--end-of-options", try std.fmt.allocPrint(git.arena, "{s}^{{tree}}", .{revision}) });
    return merge_git.exitCode(result) == 0;
}

fn contextPath(git: Git) ![]const u8 {
    const directory = merge_git.trim(try git.output(&.{ "rev-parse", "--absolute-git-dir" }));
    return std.fs.path.join(git.arena, &.{ directory, "prefablens-replay-context" });
}

fn gitPath(git: Git, name: []const u8) ![]const u8 {
    const path = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", name }));
    if (std.fs.path.isAbsolute(path)) return path;
    return git.path(path);
}

fn encode(arena: std.mem.Allocator, revisions: Revisions, head: []const u8, message: []const u8) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(arena);
    try output.writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{ format, revisions.base, revisions.ours, revisions.theirs, head, message });
    return try output.toOwnedSlice();
}

fn parse(bytes: []const u8) !Stored {
    if (bytes.len > max_record_bytes or bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.InvalidReplayContext;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidReplayContext, format)) return error.InvalidReplayContext;
    const revisions: Revisions = .{
        .base = lines.next() orelse return error.InvalidReplayContext,
        .ours = lines.next() orelse return error.InvalidReplayContext,
        .theirs = lines.next() orelse return error.InvalidReplayContext,
    };
    const head = lines.next() orelse return error.InvalidReplayContext;
    const message = lines.next() orelse return error.InvalidReplayContext;
    const trailing = lines.next() orelse return error.InvalidReplayContext;
    if (!std.mem.eql(u8, trailing, "") or lines.next() != null) return error.InvalidReplayContext;
    if (!validOid(revisions.base) or !validOid(revisions.ours) or !validOid(revisions.theirs) or
        !validOid(head) or !validFingerprint(message)) return error.InvalidReplayContext;
    return .{ .revisions = revisions, .head = head, .message = message };
}

fn validFingerprint(value: []const u8) bool {
    const last = std.mem.lastIndexOfScalar(u8, value, ':') orelse return false;
    return value.len - last - 1 == 64 and validDigest(value[last + 1 ..]);
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn digestHex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const output = try arena.alloc(u8, digest.len * 2);
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0x0f];
    }
    return output;
}

fn testGit(tmp: *std.testing.TmpDir, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Git {
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("GIT_CONFIG_GLOBAL", if (@import("builtin").os.tag == .windows) "NUL" else "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const git: Git = .{ .io = std.testing.io, .arena = arena, .env = env, .cwd = root };
    try git.ok(&.{ "init", "-q", "-b", "local" });
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try git.ok(&.{ "config", "commit.gpgSign", "false" });
    try git.ok(&.{ "config", "core.autocrlf", "false" });
    try tmp.dir.createDir(std.testing.io, "Assets", .default_dir);
    return git;
}

fn write(git: Git, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = try git.path(path), .data = bytes });
}

fn commit(git: Git, message: []const u8) ![]const u8 {
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", message });
    return merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
}

test "replay context recovers no-commit conflicts across subdirectories and rejects new operations" {
    const testing = std.testing;
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    var git = try testGit(&tmp, arena, &env);
    try write(git, "Assets/A.prefab", "base A\n");
    try write(git, "Assets/B.prefab", "base B\n");
    const base = try commit(git, "base");
    try write(git, "Assets/A.prefab", "ours A\n");
    try write(git, "Assets/B.prefab", "ours B\n");
    const ours = try commit(git, "ours");
    try git.ok(&.{ "switch", "-qc", "picked", base });
    try write(git, "Assets/A.prefab", "theirs A\n");
    try write(git, "Assets/B.prefab", "theirs B\n");
    const theirs = try commit(git, "picked");
    try git.ok(&.{ "switch", "-q", "local" });

    // Git leaves no CHERRY_PICK_HEAD for --no-commit; the supplied revisions identify the merge.
    const result = try git.run(&.{ "cherry-pick", "--no-commit", theirs });
    try testing.expectEqual(@as(u8, 1), merge_git.exitCode(result));
    try testing.expect(merge_git.exitCode(try git.run(&.{ "rev-parse", "--verify", "CHERRY_PICK_HEAD" })) != 0);
    const revisions: Revisions = .{ .base = base, .ours = ours, .theirs = theirs };
    try testing.expect(try save(git, revisions));
    const original_message = try std.Io.Dir.cwd().readFileAlloc(git.io, try gitPath(git, "MERGE_MSG"), arena, .limited(max_file_bytes));
    const original_index = try std.Io.Dir.cwd().readFileAlloc(git.io, try gitPath(git, "index"), arena, .limited(max_file_bytes));

    try write(git, "Assets/A.prefab", "resolved A\n");
    try git.ok(&.{ "add", "--", "Assets/A.prefab" });
    git.cwd = try std.fs.path.join(arena, &.{ git.cwd, "Assets" });
    const resumed = (try discover(git)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(base, resumed.base);
    try testing.expectEqualStrings(ours, resumed.ours);
    try testing.expectEqualStrings(theirs, resumed.theirs);

    // The same replay can be started again with the same message and index contents.
    try git.ok(&.{ "reset", "--hard", "HEAD" });
    try testing.expect(merge_git.exitCode(try git.run(&.{ "rev-parse", "--verify", "CHERRY_PICK_HEAD" })) != 0);
    const retry = try git.run(&.{ "cherry-pick", "--no-commit", theirs });
    try testing.expectEqual(@as(u8, 1), merge_git.exitCode(retry));
    const retry_message = try std.Io.Dir.cwd().readFileAlloc(git.io, try gitPath(git, "MERGE_MSG"), arena, .limited(max_file_bytes));
    const retry_index = try std.Io.Dir.cwd().readFileAlloc(git.io, try gitPath(git, "index"), arena, .limited(max_file_bytes));
    try testing.expectEqualStrings(original_message, retry_message);
    try testing.expectEqualStrings(original_index, retry_index);
    // MERGE_MSG's new file identity prevents reusing the previous replay's context.
    try testing.expect((try discover(git)) == null);
}

test "replay context retains the selected no-commit merge mainline" {
    const testing = std.testing;
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try testGit(&tmp, arena, &env);
    try write(git, "Assets/A.prefab", "left: 1\nright: 1\n");
    const root = try commit(git, "root");
    try git.ok(&.{ "switch", "-qc", "first", root });
    try write(git, "Assets/A.prefab", "left: 2\nright: 1\n");
    const first = try commit(git, "first parent");
    try git.ok(&.{ "switch", "-qc", "second", root });
    try write(git, "Assets/A.prefab", "left: 1\nright: 2\n");
    const second = try commit(git, "selected mainline");
    try write(git, "Assets/A.prefab", "left: 2\nright: 2\n");
    try git.ok(&.{ "add", "--all" });
    const tree = merge_git.trim(try git.output(&.{"write-tree"}));
    const merge = merge_git.trim(try git.output(&.{ "commit-tree", tree, "-p", first, "-p", second, "-m", "combined" }));
    try git.ok(&.{ "reset", "--hard", second });
    try git.ok(&.{ "switch", "-qc", "feature", second });
    try write(git, "Assets/A.prefab", "left: 3\nright: 2\n");
    const actual_ours = try commit(git, "local change");

    try env.put("GIT_INDEX_FILE", "alternate-index");
    try git.ok(&.{ "read-tree", "HEAD" });

    const conflict = try git.run(&.{ "cherry-pick", "--no-commit", "-m", "2", merge });
    try testing.expectEqual(@as(u8, 1), merge_git.exitCode(conflict));
    const revisions: Revisions = .{ .base = second, .ours = actual_ours, .theirs = merge };
    try testing.expect(try save(git, revisions));
    // An alternate index must not put PrefabLens metadata in the user's worktree.
    const metadata = merge_git.trim(try git.output(&.{ "rev-parse", "--absolute-git-dir" }));
    try std.Io.Dir.cwd().access(std.testing.io, try std.fs.path.join(arena, &.{ metadata, "prefablens-replay-context" }), .{});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, try git.path("prefablens-replay-context"), .{}));
    const recovered = (try discover(git)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(second, recovered.base);
    try testing.expectEqualStrings(merge, recovered.theirs);
}
