const std = @import("std");
const builtin = @import("builtin");
const integration = @import("git_merge_test_main.zig");

const conflict_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 1
++ "\n";
const conflict_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 2
++ "\n";
const conflict_theirs =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 3
++ "\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    if (builtin.os.tag == .windows) {
        try std.Io.File.stdout().writeStreamingAll(io, "pty smoke: skipped on Windows\n");
        return 0;
    }
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        try std.Io.File.stdout().writeStreamingAll(io, "pty smoke: skipped on unsupported OS\n");
        return 0;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    try integration.require(args.len == 2, "expected the prefablens executable path");
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const scratch = try integration.scratchDirectory(io, arena, "pty");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    try testCompletion(io, arena, scratch, prefablens);
    try testAbort(io, arena, scratch, prefablens);
    try testTimeout(io, arena, scratch, prefablens);
    try std.Io.File.stdout().writeStreamingAll(io, "pty mergetool smoke: passed\n");
    return 0;
}

fn testCompletion(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try prepareMergetoolRepository(io, arena, scratch, prefablens, "complete");
    const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try integration.expectNonzero(merge, "prepare mergetool completion conflict");
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);

    const result = runMergetoolInPty(io, arena, repo, "oa", 30) catch |err| {
        if (err == error.Timeout) {
            // A timed-out TUI must not silently change the driver's safe partial result.
            try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 0, "complete mergetool in PTY");
    inline for (.{ "Hierarchy", "Inspector", "Base", "Ours", "Theirs", "Result" }) |heading| {
        try integration.require(
            std.mem.indexOf(u8, result.stdout, heading) != null or
                std.mem.indexOf(u8, result.stderr, heading) != null,
            "PTY output omitted a merge screen heading",
        );
    }
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);

    const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
    try integration.expectCode(unmerged, 0, "list index after mergetool");
    try integration.require(unmerged.stdout.len == 0, "successful mergetool left unmerged entries");
    const continued = try integration.gitRun(
        io,
        arena,
        repo,
        &.{ "-c", "core.editor=true", "merge", "--continue" },
    );
    try integration.expectCode(continued, 0, "continue merge after mergetool");
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);

    const head = try integration.gitRun(io, arena, repo, &.{ "rev-list", "--parents", "-n", "1", "HEAD" });
    try integration.expectCode(head, 0, "inspect merge commit");
    var fields = std.mem.tokenizeAny(u8, head.stdout, " \t\r\n");
    var count: usize = 0;
    while (fields.next() != null) count += 1;
    try integration.require(count == 3, "merge --continue did not create a two-parent commit");
}

fn testAbort(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try prepareMergetoolRepository(io, arena, scratch, prefablens, "abort");
    const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try integration.expectNonzero(merge, "prepare mergetool abort conflict");
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);

    const result = runMergetoolInPty(io, arena, repo, "q", 30) catch |err| {
        if (err == error.Timeout) {
            // Timeout cleanup is verified against the exact driver partial before failing.
            try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 1, "abort mergetool in PTY");
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);
}

fn testTimeout(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try prepareMergetoolRepository(io, arena, scratch, prefablens, "timeout");
    const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try integration.expectNonzero(merge, "prepare mergetool timeout conflict");
    try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);

    _ = runMergetoolInPty(io, arena, repo, "", 3) catch |err| switch (err) {
        error.Timeout => {
            // A successful abort proves that the timed-out mergetool released Git's merge state.
            try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);
            try integration.gitOk(io, arena, repo, &.{ "merge", "--abort" });
            try integration.expectFile(io, arena, repo, "Assets/A.prefab", conflict_ours);
            return;
        },
        else => return err,
    };
    return error.ExpectedPtyTimeout;
}

fn prepareMergetoolRepository(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    name: []const u8,
) ![]const u8 {
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]integration.FileSides{.{
        .path = "Assets/A.prefab",
        .base = conflict_base,
        .ours = conflict_ours,
        .theirs = conflict_theirs,
    }};
    try integration.prepareRepository(io, arena, repo, prefablens, .local, &files);
    const tool = try std.fmt.allocPrint(
        arena,
        "{s} mergetool \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\"",
        .{try integration.shellQuote(arena, prefablens)},
    );
    try integration.gitOk(io, arena, repo, &.{ "config", "mergetool.prefablens.cmd", tool });
    try integration.gitOk(io, arena, repo, &.{ "config", "mergetool.prefablens.trustExitCode", "true" });
    return repo;
}

fn runMergetoolInPty(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    input_keys: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    const shell_command = switch (builtin.os.tag) {
        .linux => "script -qfec 'stty cols 100 rows 24; exec git mergetool --no-prompt --tool=prefablens -- Assets/A.prefab' /dev/null",
        .macos => "script -q /dev/null sh -c 'stty cols 100 rows 24; exec git mergetool --no-prompt --tool=prefablens -- Assets/A.prefab'",
        else => unreachable,
    };
    const command = try std.fmt.allocPrint(
        arena,
        // Keep the pipe open across raw-mode setup. The DA1 replies let libvaxis finish its
        // capability query without consuming the actual merge keys before the first draw.
        \\(
        \\i=0
        \\while [ "$i" -lt 10 ]; do
        \\  printf '\033[?1;2c'
        \\  sleep 0.1
        \\  i=$((i + 1))
        \\done
        \\sleep 1
        \\printf '%s' "$1"
        \\i=0
        \\while [ "$i" -lt 100 ]; do
        \\  sleep 0.1
        \\  printf '\033[?1;2c' || exit 0
        \\  i=$((i + 1))
        \\done
        \\) | TERM=xterm-256color {s} &
        \\pty_pid=$!
        \\trap 'kill "$pty_pid" 2>/dev/null; wait "$pty_pid" 2>/dev/null; exit 124' HUP INT TERM
        \\wait "$pty_pid"
        \\status=$?
        \\trap - HUP INT TERM
        \\exit "$status"
    ,
        .{shell_command},
    );
    return std.process.run(arena, io, .{
        .argv = &.{ "sh", "-c", command, "prefablens-keys", input_keys },
        .cwd = .{ .path = repository },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_seconds) } },
    });
}
