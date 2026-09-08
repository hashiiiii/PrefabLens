const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Shared input-size ceiling for both file reads (diff.zig) and `git show`
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
    const res = runGit(arena, io, .{
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
    const res = runGit(arena, io, .{
        .argv = &.{ "git", "show", "--end-of-options", spec },
        .cwd = .{ .path = repo_dir },
        .stdout_limit = .limited(max_input_bytes),
        .environ_map = &env,
        .timeout = timeout,
    }) catch |err| switch (err) {
        // runGit kills the child on deadline overrun and returns error.Timeout.
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
            if (builtin.is_test) std.debug.print("git show failed: {s}\n", .{res.stderr});
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
    const res = runGit(arena, io, .{
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

const windows_job = struct {
    const windows = std.os.windows;

    extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
};

// Zig 0.16 cancels the output readers before killing the child. On Windows,
// reader cancellation can wait for output first, so a hung Git also hangs its
// timeout cleanup. Keep the same collection behavior but reverse that order.
fn runGit(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    if (builtin.os.tag != .windows) return std.process.run(gpa, io, options);
    const windows = std.os.windows;
    const job = windows_job.CreateJobObjectW(null, null) orelse return windows.unexpectedError(windows.GetLastError());
    defer windows.CloseHandle(job);
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .progress_node = options.progress_node,
        .create_no_window = options.create_no_window,
        .disable_aslr = options.disable_aslr,
        // Git for Windows launches the real Git as a child. Assign the launcher
        // to a job before it runs so timeout cleanup includes its descendants.
        .start_suspended = true,

        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);
    if (!windows_job.AssignProcessToJobObject(job, child.id.?).toBool())
        return windows.unexpectedError(windows.GetLastError());

    // Child.kill and Child.wait normally close these handles. The readers own
    // them here so cancellation never operates on already-closed handles.
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout.close(io);
    defer stderr.close(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ stdout, stderr });
    defer multi_reader.deinit();
    // A silent child must exit before Windows waits for pending pipe reads.
    defer if (child.id != null) {
        std.debug.assert(windows_job.TerminateJobObject(job, 1).toBool());
        child.kill(io);
    };
    const resumed = windows.ntdll.NtResumeThread(child.thread_handle, null);
    if (resumed != .SUCCESS) return windows.unexpectedStatus(resumed);

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(options.reserve_amount, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
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

    const include_name = "prefablens-show-timeout";
    const include_path = try std.fs.path.join(arena, &.{ dir, include_name });

    // Git reads included configuration before resolving the requested object. Keep
    // this real Git read pending so timeout coverage does not depend on process startup.
    if (builtin.os.tag == .windows) {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = include_name, .data = "" });
    } else {
        const result = try std.process.run(arena, testing.io, .{ .argv = &.{ "mkfifo", include_path } });
        if (result.term != .exited or result.term.exited != 0) return error.MkfifoFailed;
    }
    try git(testing.io, arena, dir, &.{ "config", "--local", "include.path", include_path });

    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1) } };
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        // Git's access check rejects named pipes. An exclusive oplock on a regular
        // file lets that check succeed, but blocks Git's open until we release it.
        // Disabling symlink following gives this fixture an asynchronous handle,
        // which Windows requires for an oplock request.
        const include_file = try std.Io.Dir.openFileAbsolute(testing.io, include_path, .{
            .mode = .read_write,
            .follow_symlinks = false,
        });
        defer include_file.close(testing.io);
        var oplock: windows.IO_STATUS_BLOCK = undefined;
        const request_level_one: windows.CTL_CODE = @bitCast(@as(u32, 0x00090000));
        std.debug.print("timeout fixture: requesting oplock\n", .{});
        try testing.expectEqual(windows.NTSTATUS.PENDING, windows.ntdll.NtFsControlFile(
            include_file.handle,
            null,
            null,
            null,
            &oplock,
            request_level_one,
            null,
            0,
            null,
            0,
        ));
        std.debug.print("timeout fixture: oplock granted\n", .{});
        defer {
            // Even a spawn failure must finish the asynchronous request before
            // its status block goes out of scope.
            var cancelled: windows.IO_STATUS_BLOCK = undefined;
            const status = windows.ntdll.NtCancelIoFileEx(include_file.handle, &oplock, &cancelled);
            std.debug.print("timeout fixture: cancellation {t}\n", .{status});
            std.debug.assert(status == .SUCCESS or status == .NOT_FOUND);
            std.debug.assert(windows.ntdll.NtWaitForSingleObject(include_file.handle, .FALSE, null) == .SUCCESS);
            std.debug.print("timeout fixture: cleanup complete\n", .{});
        }
        std.debug.print("timeout fixture: running Git\n", .{});
        try testing.expectError(error.GitTimeout, showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab", timeout));
        std.debug.print("timeout fixture: Git timed out\n", .{});
    } else {
        const include_file = try std.Io.Dir.openFileAbsolute(testing.io, include_path, .{ .mode = .read_write });
        defer include_file.close(testing.io);
        try testing.expectError(error.GitTimeout, showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab", timeout));
    }

    // Releasing the blocked read must leave the same repository usable.
    if (builtin.os.tag != .windows) {
        try tmp.dir.deleteFile(testing.io, include_name);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = include_name, .data = "" });
    }
    try testing.expectEqualStrings("v1\n", try showAtRef(testing.io, arena, dir, "HEAD", "Foo.prefab", default_git_timeout));
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

    // Note.txt fails the CLI's Unity extension gate (diff_options.zig's parseArgs), so it gets
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
