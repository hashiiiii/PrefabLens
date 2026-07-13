const std = @import("std");
const testing = std.testing;

/// Shared input-size ceiling for both file reads (main.zig) and `git show`
/// output (here), so the two acquisition paths reject oversized input the
/// same way instead of diverging on an arbitrary limit.
pub const max_input_bytes: usize = 64 * 1024 * 1024; // 64 MiB guard

/// Default timeout for running git. An upper bound so that not just the direct CLI
/// invocation but also the Unity Editor (which waits with WaitForExit) isn't
/// dragged down by a hung git.
pub const default_git_timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } };

/// Absolute path of the work-tree root of the repository containing `dir`.
/// git reports changed paths relative to this root, so anchoring reads here
/// keeps subdirectory invocations correct.
pub fn repoRoot(io: std.Io, arena: std.mem.Allocator, dir: []const u8, timeout: std.Io.Timeout) ![]const u8 {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(64 * 1024),
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => return error.GitTimeout,
        else => return err,
    };
    if (res.term != .exited or res.term.exited != 0) return error.GitRootFailed;
    const root = std.mem.trimEnd(u8, res.stdout, "\r\n");
    if (root.len == 0) return error.GitRootFailed;
    return root;
}

test "repoRoot resolves the work-tree root from a subdirectory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "Assets/Sub");
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try git(testing.io, arena, dir, &.{ "init", "-q" });

    const sub = try tmp.dir.realPathFileAlloc(testing.io, "Assets/Sub", arena);
    const root = try repoRoot(testing.io, arena, sub, .none);
    // macOS tmp dirs come back through /private symlinks: compare realpaths.
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, root, arena);
    try testing.expectEqualStrings(dir, canonical);

    // Outside any repository the failure is explicit, not a silent ".".
    try testing.expectError(error.GitRootFailed, repoRoot(testing.io, arena, "/", .none));
}

pub fn showAtRef(io: std.Io, arena: std.mem.Allocator, repo_dir: []const u8, ref: []const u8, path: []const u8, timeout: std.Io.Timeout) ![]u8 {
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, path });
    // Force the C locale so the stderr substrings matched below are always
    // English, regardless of the caller's own LC_ALL/LANG.
    var env = std.process.Environ.Map.init(arena);
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    const res = std.process.run(arena, io, .{
        .argv = &.{ "git", "show", "--end-of-options", spec },
        .cwd = .{ .path = repo_dir },
        .stdout_limit = .limited(max_input_bytes),
        .environ_map = &env,
        .timeout = timeout,
    }) catch |err| switch (err) {
        // std.process.run kills the child on deadline overrun and returns error.Timeout.
        error.Timeout => return error.GitTimeout,
        else => return err,
    };
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

/// Working-tree side (the after side when only one ref is given). A missing file is treated as "deleted" = empty side.
pub fn readWorktree(io: std.Io, arena: std.mem.Allocator, repo_dir: []const u8, path: []const u8) ![]u8 {
    const full = try std.fs.path.join(arena, &.{ repo_dir, path });
    return std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(max_input_bytes)) catch |err| switch (err) {
        error.FileNotFound => try arena.alloc(u8, 0),
        else => err,
    };
}

/// Paths changed between before_ref and after_ref (empty after_ref = the
/// working tree), one repo-relative path per git output NUL-separated entry.
/// Untracked files are not listed — same semantics as `git diff --name-only`.
/// The -z flag both NUL-separates the output and disables git's quotepath
/// C-quoting mangling, so non-ASCII filenames come through as literal UTF-8.
pub fn changedPaths(
    io: std.Io,
    arena: std.mem.Allocator,
    repo_dir: []const u8,
    before_ref: []const u8,
    after_ref: []const u8,
    timeout: std.Io.Timeout,
) ![][]const u8 {
    var env = std.process.Environ.Map.init(arena);
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "diff", "--name-only", "-z", "--end-of-options", before_ref });
    if (after_ref.len != 0) try argv.append(arena, after_ref);
    // No pathspec follows the refs, but the trailing "--" still matters: without it, a ref
    // operand that fails to resolve as a revision but happens to name a file in the working
    // tree (e.g. a caller passing a non-Unity path like "Note.txt" as if it were a ref) would
    // have git silently reinterpret it as a pathspec instead of failing. The explicit "--"
    // forces every operand before it to be resolved strictly as a revision.
    try argv.append(arena, "--");
    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo_dir },
        .stdout_limit = .limited(max_input_bytes),
        .environ_map = &env,
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => return error.GitTimeout,
        else => return err,
    };
    if (res.term != .exited or res.term.exited != 0) return error.GitDiffFailed;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |entry| {
        if (entry.len != 0) try out.append(arena, entry);
    }
    return out.items;
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
    // Deleted in the working tree = empty side (not an error)
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

    const content = try showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab", .none);
    try testing.expectEqualStrings("v1\n", content);

    // A path absent at the ref yields empty bytes, not an error.
    const missing = try showAtRef(testing.io, arena, dir, "HEAD", "Nope.prefab", .none);
    try testing.expectEqual(@as(usize, 0), missing.len);

    // A bad ref is a real failure, not an absent side.
    try testing.expectError(error.GitShowFailed, showAtRef(testing.io, arena, dir, "bogus-ref", "Foo.prefab", .none));
}

test "showAtRef kills git and errors when the timeout passes" {
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

    // Even real git can't finish in 1µs (spawn alone takes ms). Confirm that the cutoff
    // protecting a long-lived caller from a hung git returns as a clear error.
    const tiny: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMicroseconds(1) } };
    try testing.expectError(error.GitTimeout, showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab", tiny));
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
    try testing.expectError(error.GitShowFailed, showAtRef(testing.io, arena, dir, malicious_ref, "Foo.prefab", .none));

    // The PoC file must not have been created.
    tmp.dir.access(testing.io, "prefablens_pwn_test", .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    try testing.expect(false); // file was created -- injection succeeded
}

test "changedPaths lists worktree changes against a ref, including deletions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Note.txt", .data = "n1\n" });
    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try git(testing.io, arena, dir, &.{ "add", "." });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });

    // Modify one file, delete the other: both must be listed. Extension
    // filtering is the caller's job, so Note.txt appears here too.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v2\n" });
    try tmp.dir.deleteFile(testing.io, "Note.txt");

    const paths = try changedPaths(testing.io, arena, dir, "HEAD", "", default_git_timeout);
    try testing.expectEqual(@as(usize, 2), paths.len);
    // git emits paths sorted; rely on that for a stable assertion.
    try testing.expectEqualStrings("Foo.prefab", paths[0]);
    try testing.expectEqualStrings("Note.txt", paths[1]);
}

test "changedPaths lists changes between two refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try git(testing.io, arena, dir, &.{ "add", "." });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v2\n" });
    try git(testing.io, arena, dir, &.{ "add", "." });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "second" });

    const paths = try changedPaths(testing.io, arena, dir, "HEAD~1", "HEAD", default_git_timeout);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("Foo.prefab", paths[0]);
}

test "changedPaths surfaces a file-named operand as GitDiffFailed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "v1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Note.txt", .data = "n1\n" });
    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try git(testing.io, arena, dir, &.{ "add", "." });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });

    // Note.txt fails the CLI's Unity extension gate (main.zig's parseArgs), so it gets
    // classified as a second ref operand rather than a path. Without a trailing "--",
    // git would fail to resolve "Note.txt" as a revision and silently fall back to
    // binding it as a pathspec instead, succeeding at exit 0 (diff restricted to that
    // one file) rather than surfacing the unresolvable ref as an error.
    try testing.expectError(error.GitDiffFailed, changedPaths(testing.io, arena, dir, "HEAD", "Note.txt", default_git_timeout));
}

test "changedPaths surfaces a bad ref as GitDiffFailed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try git(testing.io, arena, dir, &.{ "init", "-q" });

    try testing.expectError(error.GitDiffFailed, changedPaths(testing.io, arena, dir, "bogus-ref", "", default_git_timeout));
}

test "changedPaths preserves non-ASCII filenames (quotepath protection)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "素材.prefab", .data = "v1\n" });
    try git(testing.io, arena, dir, &.{ "init", "-q" });
    try git(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try git(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try git(testing.io, arena, dir, &.{ "add", "." });
    try git(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });

    // Modify the non-ASCII file. Without -z flag, git would emit the C-quoted
    // form like "\347\264\240\346\235\220.prefab", breaking downstream git show
    // and file reads. With -z, we get the literal UTF-8 filename back.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "素材.prefab", .data = "v2\n" });

    const paths = try changedPaths(testing.io, arena, dir, "HEAD", "", default_git_timeout);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("素材.prefab", paths[0]);
}
