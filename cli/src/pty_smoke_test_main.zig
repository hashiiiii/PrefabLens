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
const conflict_resolved =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 4
++ "\n";
const conflict_empty =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value:
++ " \n";
const map_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Config:
    \\    value: 1
    \\  m_After: keep
++ "\n";
const map_deleted =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_After: keep
++ "\n";
const map_edited =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Config:
    \\    value: 2
    \\  m_After: keep
++ "\n";
const capture_width = 100;
const capture_height = 24;

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

    try testVisibleLabelAssertion();
    try testCompletion(io, arena, scratch, prefablens);
    try testBackspaceBeforeEditing(io, arena, scratch, prefablens);
    try testDeletionChoices(io, arena, scratch, prefablens);
    try testQuit(io, arena, scratch, prefablens);
    try testTimeout(io, arena, scratch, prefablens);
    try std.Io.File.stdout().writeStreamingAll(io, "pty mergetool smoke: passed\n");
    return 0;
}

fn testDeletionChoices(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const cases = [_]struct {
        name: []const u8,
        ours: []const u8,
        theirs: []const u8,
        keys: []const u8,
    }{
        // The side choice represents deletion, and the second Enter confirms Complete.
        .{ .name = "delete-ours", .ours = map_deleted, .theirs = map_edited, .keys = "\x1b[C\r\r" },
        .{ .name = "delete-theirs", .ours = map_edited, .theirs = map_deleted, .keys = "\x1b[C\x1b[C\r\r" },
    };
    for (cases) |case| {
        const repo = try prepareMergetoolRepositoryWithSides(
            io,
            arena,
            scratch,
            prefablens,
            case.name,
            .{
                .path = "Assets/Conflict.prefab",
                .base = map_base,
                .ours = case.ours,
                .theirs = case.theirs,
            },
        );
        const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
        try integration.expectNonzero(merge, "prepare deletion conflict");
        try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", case.ours);

        const result = try runMergetoolInPty(io, arena, repo, case.keys, 30);
        try integration.expectCode(result, 0, "choose deletion in PTY");
        try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", map_deleted);
        const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
        try integration.expectCode(unmerged, 0, "list index after deletion");
        try integration.require(unmerged.stdout.len == 0, "deletion choice left unmerged entries");
    }
}

fn testVisibleLabelAssertion() !void {
    const different_rows = "\x1b[?1049hcomponents\x1b[2;1H(1)\x1b[?1049l";
    try integration.require(
        !terminalCaptureContains(different_rows, "components (1)"),
        "PTY label assertion accepted separate rows",
    );

    const same_row = "\x1b[?1049hcomponents\x1b[1;12H(1)\x1b[?1049l";
    try integration.require(
        terminalCaptureContains(same_row, "components (1)"),
        "PTY label assertion rejected one visible row",
    );

    const split_buffers =
        "components " ++
        "\x1b[?1049h\x1b[1;12H(1)\x1b[?1049l";
    try integration.require(
        !terminalCaptureContains(split_buffers, "components (1)"),
        "PTY label assertion combined primary and alternate screens",
    );
}

fn terminalCaptureContains(capture: []const u8, needle: []const u8) bool {
    var cells: [capture_height][capture_width]u8 = undefined;
    for (&cells) |*screen_row| @memset(screen_row, ' ');
    var row: usize = 0;
    var col: usize = 0;
    var index: usize = 0;
    var alternate_active = false;

    while (index < capture.len) {
        const byte = capture[index];
        if (byte == 0x1b) {
            index = consumeEscape(capture, index, &row, &col, &cells, &alternate_active);
            continue;
        }
        index += 1;
        switch (byte) {
            '\r' => col = 0,
            '\n' => row = @min(row + 1, capture_height - 1),
            0x20...0x7e => {
                if (col < capture_width) {
                    cells[row][col] = byte;
                    col += 1;
                }
                if (alternate_active and std.mem.indexOf(u8, &cells[row], needle) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn consumeEscape(
    capture: []const u8,
    escape_index: usize,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) usize {
    if (escape_index + 1 >= capture.len) return capture.len;
    return switch (capture[escape_index + 1]) {
        '[' => consumeCsi(capture, escape_index + 2, row, col, cells, alternate_active),
        ']', 'P', '_', '^' => consumeControlString(capture, escape_index + 2),
        else => escape_index + 2,
    };
}

fn consumeControlString(capture: []const u8, start: usize) usize {
    var index = start;
    while (index < capture.len) : (index += 1) {
        if (capture[index] == 0x07) return index + 1;
        if (capture[index] == 0x1b and index + 1 < capture.len and capture[index + 1] == '\\') {
            return index + 2;
        }
    }
    return capture.len;
}

fn consumeCsi(
    capture: []const u8,
    start: usize,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) usize {
    var params = [_]usize{0} ** 4;
    var param_count: usize = 1;
    var index = start;
    var private_mode = false;
    while (index < capture.len) : (index += 1) {
        const byte = capture[index];
        switch (byte) {
            '0'...'9' => {
                const param = &params[param_count - 1];
                param.* = param.* * 10 + byte - '0';
            },
            ';' => {
                if (param_count < params.len) param_count += 1;
            },
            '?' => private_mode = true,
            0x40...0x7e => {
                applyCsi(byte, params, param_count, private_mode, row, col, cells, alternate_active);
                return index + 1;
            },
            else => {},
        }
    }
    return capture.len;
}

fn applyCsi(
    command: u8,
    params: [4]usize,
    param_count: usize,
    private_mode: bool,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) void {
    const first = if (params[0] == 0) 1 else params[0];
    const second = if (param_count < 2 or params[1] == 0) 1 else params[1];
    switch (command) {
        'H', 'f' => {
            row.* = @min(first - 1, capture_height - 1);
            col.* = @min(second - 1, capture_width - 1);
        },
        'G' => col.* = @min(first - 1, capture_width - 1),
        'd' => row.* = @min(first - 1, capture_height - 1),
        'A' => row.* -|= first,
        'B' => row.* = @min(row.* + first, capture_height - 1),
        'C' => col.* = @min(col.* + first, capture_width - 1),
        'D' => col.* -|= first,
        'J' => for (cells) |*screen_row| @memset(screen_row, ' '),
        'K' => @memset(&cells[row.*], ' '),
        'h' => if (private_mode and params[0] == 1049) {
            for (cells) |*screen_row| @memset(screen_row, ' ');
            row.* = 0;
            col.* = 0;
            alternate_active.* = true;
        },
        'l' => if (private_mode and params[0] == 1049) {
            alternate_active.* = false;
        },
        else => {},
    }
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
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);

    // The mouse click focuses Result. The first key starts editing and replaces the value.
    // The first Enter applies Result. The second Enter confirms Complete.
    const result = runMergetoolInPty(io, arena, repo, "\x1b[<0;83;5M4\r\r", 30) catch |err| {
        if (err == error.Timeout) {
            // A timed-out TUI must not silently change the driver's safe partial result.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 0, "complete mergetool in PTY");
    inline for (.{ "components (1)", "Result" }) |text| {
        try integration.require(
            terminalCaptureContains(result.stdout, text),
            "PTY output omitted merge screen text",
        );
    }
    inline for (.{ "Hierarchy", "Inspector", "Apply result", "[ Quit ]" }) |text| {
        try integration.require(
            !terminalCaptureContains(result.stdout, text),
            "PTY output included a removed pane title",
        );
    }
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_resolved);

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
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_resolved);

    const head = try integration.gitRun(io, arena, repo, &.{ "rev-list", "--parents", "-n", "1", "HEAD" });
    try integration.expectCode(head, 0, "inspect merge commit");
    var fields = std.mem.tokenizeAny(u8, head.stdout, " \t\r\n");
    var count: usize = 0;
    while (fields.next() != null) count += 1;
    try integration.require(count == 3, "merge --continue did not create a two-parent commit");
}

fn testBackspaceBeforeEditing(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try prepareMergetoolRepository(io, arena, scratch, prefablens, "backspace");
    const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try integration.expectNonzero(merge, "prepare mergetool Backspace conflict");
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);

    // A raw DEL byte is the macOS Delete key and must work before a Result click.
    // Enter opens the dialog. Right and Enter apply the empty value. The final Enter confirms Complete.
    const keys = "\x1b[C\r\x1b[A\x1b[C\x1b[C\x1b[C\x7f\r\x1b[C\r\r";
    const result = try runMergetoolInPty(io, arena, repo, keys, 30);
    try integration.expectCode(result, 0, "clear focused Result in PTY");
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_empty);

    const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
    try integration.expectCode(unmerged, 0, "list index after empty Result");
    try integration.require(unmerged.stdout.len == 0, "empty Result left unmerged entries");
}

fn testQuit(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try prepareMergetoolRepository(io, arena, scratch, prefablens, "quit");
    const merge = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try integration.expectNonzero(merge, "prepare mergetool quit conflict");
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);

    // Quit must leave both the merge output and Git's conflict state untouched.
    const result = runMergetoolInPty(io, arena, repo, "\x1b[27uy", 30) catch |err| {
        if (err == error.Timeout) {
            // Timeout cleanup is verified against the exact driver partial before failing.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 1, "quit mergetool in PTY");
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
    try integration.require(
        std.mem.indexOf(u8, result.stdout, "Abort") == null and
            std.mem.indexOf(u8, result.stderr, "Abort") == null,
        "PTY output included Abort",
    );

    const unmerged = try integration.gitRun(
        io,
        arena,
        repo,
        &.{ "ls-files", "-u", "--", "Assets/Conflict.prefab" },
    );
    try integration.expectCode(unmerged, 0, "list index after Quit");
    var entries = std.mem.tokenizeScalar(u8, unmerged.stdout, '\n');
    var count: usize = 0;
    while (entries.next() != null) count += 1;
    try integration.require(count == 3, "Quit changed Git's conflict stages");
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
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);

    _ = runMergetoolInPty(io, arena, repo, "", 3) catch |err| switch (err) {
        error.Timeout => {
            // A successful abort proves that the timed-out mergetool released Git's merge state.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
            try integration.gitOk(io, arena, repo, &.{ "merge", "--abort" });
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
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
    return prepareMergetoolRepositoryWithSides(io, arena, scratch, prefablens, name, .{
        .path = "Assets/Conflict.prefab",
        .base = conflict_base,
        .ours = conflict_ours,
        .theirs = conflict_theirs,
    });
}

fn prepareMergetoolRepositoryWithSides(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    name: []const u8,
    file: integration.FileSides,
) ![]const u8 {
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]integration.FileSides{file};
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
        .linux => "script -qfec 'stty cols 100 rows 24; exec git mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab' /dev/null",
        .macos => "script -q /dev/null sh -c 'stty cols 100 rows 24; exec git mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab'",
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
