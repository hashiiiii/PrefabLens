const std = @import("std");
const testing = std.testing;

/// Shared input-size ceiling for both file reads (main.zig) and `git show`
/// output (here), so the two acquisition paths reject oversized input the
/// same way instead of diverging on an arbitrary limit.
pub const max_input_bytes: usize = 64 * 1024 * 1024; // 64 MiB guard

pub fn showAtRef(io: std.Io, arena: std.mem.Allocator, repo_dir: []const u8, ref: []const u8, path: []const u8) ![]u8 {
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, path });
    // Force the C locale so the stderr substrings matched below are always
    // English, regardless of the caller's own LC_ALL/LANG.
    var env = std.process.Environ.Map.init(arena);
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    const res = try std.process.run(arena, io, .{
        .argv = &.{ "git", "show", "--end-of-options", spec },
        .cwd = .{ .path = repo_dir },
        .stdout_limit = .limited(max_input_bytes),
        .environ_map = &env,
    });
    switch (res.term) {
        .exited => |c| {
            if (c == 0) return res.stdout;
            // Path absent at a valid ref (added/deleted side) -> empty.
            if (std.mem.indexOf(u8, res.stderr, "does not exist in") != null or
                std.mem.indexOf(u8, res.stderr, "exists on disk, but not in") != null)
                return &[_]u8{};
            // Anything else (bad revision, not a git repository, ...) is a real failure.
            return error.GitShowFailed;
        },
        else => return error.GitShowFailed,
    }
}

/// 作業ツリー側(--git REF PATH の after)。ファイル不在は「削除済み」= 空側として扱う。
pub fn readWorktree(io: std.Io, arena: std.mem.Allocator, repo_dir: []const u8, path: []const u8) ![]u8 {
    const full = try std.fs.path.join(arena, &.{ repo_dir, path });
    return std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(max_input_bytes)) catch |err| switch (err) {
        error.FileNotFound => try arena.alloc(u8, 0),
        else => err,
    };
}

fn git(io: std.Io, arena: std.mem.Allocator, dir: []const u8, argv: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(arena, "git");
    try full.appendSlice(arena, argv);
    const res = try std.process.run(arena, io, .{ .argv = full.items, .cwd = .{ .path = dir } });
    if (res.term != .exited or res.term.exited != 0) return error.GitFailed;
}

test "readWorktree reads the file and treats absence as an empty side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v2\n" });

    try testing.expectEqualStrings("v2\n", try readWorktree(testing.io, arena, dir, "Foo.prefab"));
    // 作業ツリーで削除済み = 空側(エラーにしない)
    try testing.expectEqual(@as(usize, 0), (try readWorktree(testing.io, arena, dir, "Gone.prefab")).len);
}

test "showAtRef returns file contents at a commit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try git(testing.io, arena, dir, &.{ "add", "Foo.prefab" });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });

    const content = try showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab");
    try testing.expectEqualStrings("v1\n", content);

    // A path absent at the ref yields empty bytes, not an error.
    const missing = try showAtRef(testing.io, arena, dir, "HEAD", "Nope.prefab");
    try testing.expectEqual(@as(usize, 0), missing.len);

    // A bad ref is a real failure, not an absent side.
    try testing.expectError(error.GitShowFailed, showAtRef(testing.io, arena, dir, "bogus-ref", "Foo.prefab"));
}

test "showAtRef does not let a dash-prefixed ref be parsed as a git option" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try git(testing.io, arena, dir, &.{ "add", "Foo.prefab" });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });

    // A PoC ref that would let `git show` parse "--output=..." as an option
    // if the spec were passed as a bare positional (arg injection). With
    // --end-of-options in argv, git must treat it as a bad revision instead
    // of writing the target file.
    const poc_path = try std.fs.path.join(arena, &.{ dir, "prefablens_pwn_test" });
    const malicious_ref = try std.fmt.allocPrint(arena, "--output={s}", .{poc_path});
    try testing.expectError(error.GitShowFailed, showAtRef(testing.io, arena, dir, malicious_ref, "Foo.prefab"));

    // The PoC file must not have been created.
    tmp.dir.access(testing.io, "prefablens_pwn_test", .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    try testing.expect(false); // file was created -- injection succeeded
}
