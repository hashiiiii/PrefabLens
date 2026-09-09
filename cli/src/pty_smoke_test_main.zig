const std = @import("std");
const builtin = @import("builtin");
const integration = @import("testing/git.zig");
const pty = @import("testing/pty.zig");

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
    try integration.require(args.len == 2 or (args.len == 3 and std.mem.eql(u8, args[2], "--readiness")), "expected the prefablens executable path and optional --readiness");
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const scratch = try integration.scratchDirectory(io, arena, "pty");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    try testVisibleLabelAssertion();
    try testDelayedTerminals(io, arena, scratch, prefablens);
    if (args.len == 3) return 0;
    try testCompletion(io, arena, scratch, prefablens);
    try testBackspaceBeforeEditing(io, arena, scratch, prefablens);
    try testResultEditing(io, arena, scratch, prefablens);
    try testDeletionChoices(io, arena, scratch, prefablens);
    try testCollectionChoices(io, arena, scratch, prefablens);
    try testQuit(io, arena, scratch, prefablens);
    try testTimeout(io, arena, scratch, prefablens);
    try std.Io.File.stdout().writeStreamingAll(io, "pty mergetool smoke: passed\n");
    return 0;
}

fn testCollectionChoices(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const cases = [_]struct {
        name: []const u8,
        base: []const u8,
        ours: []const u8,
        theirs: []const u8,
        keys: []const u8,
        expected: []const u8,
        toggle_keys: ?[]const u8 = null,
    }{
        // Both insertion orders must retain each block and the unrelated scalar edits.
        .{ .name = "collection-ours-first", .base = "[A]", .ours = "[A, O1, O2]", .theirs = "[A, T1, T2]", .toggle_keys = "\x1b[CT", .keys = "\r\r", .expected = "[A, O1, O2, T1, T2]" },
        .{ .name = "collection-theirs-first", .base = "[A]", .ours = "[A, O1, O2]", .theirs = "[A, T1, T2]", .toggle_keys = "\x1b[C\x1b[116;2u", .keys = "\x1b[C\r\r", .expected = "[A, T1, T2, O1, O2]" },
        // A second toggle restores the original side before Enter resolves it.
        .{ .name = "collection-toggle-off", .base = "[A]", .ours = "[A, Ours]", .theirs = "[A, Theirs]", .toggle_keys = "\x1b[CT", .keys = "T\r\r", .expected = "[A, Ours]" },
        // Retaining the edited C must not restore the independently removed B.
        .{ .name = "collection-delete-edit", .base = "[A, B, C]", .ours = "[A]", .theirs = "[A, B, Edited]", .keys = "\x1b[C\x1b[C\r\r", .expected = "[A, Edited]" },
        // A custom interval replaces only the unresolved append gap.
        .{ .name = "collection-custom", .base = "[A]", .ours = "[A, Ours]", .theirs = "[A, Theirs]", .keys = "\x1b[<0;83;5M[Custom]\r\r", .expected = "[A, Custom]" },
    };
    for (cases) |case| {
        const repo = try prepareMergetoolRepositoryWithSides(io, arena, scratch, prefablens, case.name, .{
            .path = "Assets/Conflict.prefab",
            .base = try collectionFile(arena, case.base, 1, 1),
            .ours = try collectionFile(arena, case.ours, 2, 1),
            .theirs = try collectionFile(arena, case.theirs, 1, 3),
        });
        const merged = try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
        try integration.expectNonzero(merged, "prepare collection conflict");
        _ = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");
        const result = if (case.toggle_keys) |toggle_keys|
            try pty.runCommandInPtyThreeBatches(io, arena, repo, "git mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab", "", toggle_keys, case.keys, 30)
        else
            try runMergetoolInPty(io, arena, repo, case.keys, 30);
        try integration.expectCode(result, 0, "resolve collection in PTY");
        if (case.toggle_keys != null) {
            inline for (.{ "Both sides", "Ours + Theirs", "Theirs + Ours" }) |label| {
                try integration.require(pty.terminalCaptureContains(result.stdout, label), "PTY omitted the combined collection mode");
            }
        }
        try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", try collectionFile(arena, case.expected, 2, 3));
        const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
        try integration.expectCode(unmerged, 0, "list index after collection choice");
        try integration.require(unmerged.stdout.len == 0, "collection choice left unmerged entries");
    }
}

fn collectionFile(arena: std.mem.Allocator, items: []const u8, left: u8, right: u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "--- !u!114 &1\nMonoBehaviour:\n  m_Items: {s}\n  m_Left: {d}\n  m_Right: {d}\n", .{ items, left, right });
}

fn testResultEditing(io: std.Io, arena: std.mem.Allocator, scratch: []const u8, prefablens: []const u8) !void {
    const scalar_prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: ";
    const cases = [_]struct { name: []const u8, base: []const u8, ours: []const u8, theirs: []const u8, keys: []const u8, expected: []const u8 }{
        // Ctrl+E retains the side preview; editing one digit must not replace the rest of the value.
        .{ .name = "result-cursor", .base = scalar_prefix ++ "5\n", .ours = scalar_prefix ++ "12\n", .theirs = scalar_prefix ++ "8\n", .keys = "\x1b[<0;52;5M\x05\x1b[D\x7f9\r\r", .expected = scalar_prefix ++ "92\n" },
        // CRLF inside bracketed paste must not accept a partial interval or trigger Complete.
        .{ .name = "result-paste", .base = try collectionFile(arena, "[A]", 1, 1), .ours = try collectionFile(arena, "[A, Ours]", 2, 1), .theirs = try collectionFile(arena, "[A, Theirs]", 1, 3), .keys = "\x1b[<0;83;5M\x1b[200~  - One\r\n  - Two\r\n\x1b[201~\r\r", .expected = try collectionFile(arena, "[A, One, Two]", 2, 3) },
        // A newline retains indentation, and Up edits the preceding line without applying it.
        .{ .name = "result-multiline", .base = try collectionFile(arena, "[A]", 1, 1), .ours = try collectionFile(arena, "[A, Ours]", 2, 1), .theirs = try collectionFile(arena, "[A, Theirs]", 1, 3), .keys = "\x1b[<0;83;5M  - One\x0a- Two\x1b[A\x1b[F\x7fX\r\r", .expected = try collectionFile(arena, "[A, OnX, Two]", 2, 3) },
        // Modified Enter reports must insert a newline without submitting through TextField focus.
        .{ .name = "result-shift-enter", .base = try collectionFile(arena, "[A]", 1, 1), .ours = try collectionFile(arena, "[A, Ours]", 2, 1), .theirs = try collectionFile(arena, "[A, Theirs]", 1, 3), .keys = "\x1b[<0;83;5M  - One\x1b[13;2u- Two\x1b[A\x1b[F\x7fX\r\r", .expected = try collectionFile(arena, "[A, OnX, Two]", 2, 3) },
    };
    for (cases) |case| {
        const repo = try prepareMergetoolRepositoryWithSides(io, arena, scratch, prefablens, case.name, .{
            .path = "Assets/Conflict.prefab",
            .base = case.base,
            .ours = case.ours,
            .theirs = case.theirs,
        });
        try integration.expectNonzero(try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" }), "prepare Result editing conflict");
        const result = try runMergetoolInPty(io, arena, repo, case.keys, 30);
        try integration.expectCode(result, 0, case.name);
        try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", case.expected);
        const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
        try integration.expectCode(unmerged, 0, "list index after Result editing");
        try integration.require(unmerged.stdout.len == 0, "Result editing left unmerged entries");
    }
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
        // Enter applies the focused deletion choice, then confirms Complete.
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
        _ = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");

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
        !pty.terminalCaptureContains(different_rows, "components (1)"),
        "PTY label assertion accepted separate rows",
    );

    const same_row = "\x1b[?1049hcomponents\x1b[1;12H(1)\x1b[?1049l";
    try integration.require(
        pty.terminalCaptureContains(same_row, "components (1)"),
        "PTY label assertion rejected one visible row",
    );

    const split_buffers =
        "components " ++
        "\x1b[?1049h\x1b[1;12H(1)\x1b[?1049l";
    try integration.require(
        !pty.terminalCaptureContains(split_buffers, "components (1)"),
        "PTY label assertion combined primary and alternate screens",
    );
}

fn testDelayedTerminals(io: std.Io, arena: std.mem.Allocator, scratch: []const u8, prefablens: []const u8) !void {
    const first = try prepareMergetoolRepository(io, arena, scratch, prefablens, "delayed-first");
    const second = try prepareMergetoolRepository(io, arena, scratch, prefablens, "delayed-second");
    for ([_][]const u8{ first, second }) |repo| {
        try integration.expectNonzero(try integration.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" }), "prepare delayed terminal conflict");
    }
    // Each real mergetool starts after the old fixed two-second key schedule.
    // The second batch must wait for the second UI, not a redraw of the first.
    const command = try std.fmt.allocPrint(
        arena,
        "sleep 3; git mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab && sleep 3 && git -C {s} mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab",
        .{try integration.shellQuote(arena, second)},
    );
    const result = try pty.runCommandInPtyBatches(io, arena, first, try std.fmt.allocPrint(arena, "sh -c {s}", .{try integration.shellQuote(arena, command)}), "\x1b[<0;83;5M4\r\r", "\x1b[<0;83;5M5\r\r", 15);
    try integration.expectCode(result, 0, "delayed terminal batches");
    const alternate_start = "\x1b[?1049h";
    var session_start = std.mem.indexOf(u8, result.stdout, alternate_start);
    var session_count: usize = 0;
    while (session_start) |start| {
        const next = std.mem.indexOfPos(u8, result.stdout, start + alternate_start.len, alternate_start);
        const output = result.stdout[start .. next orelse result.stdout.len];
        try integration.require(pty.terminalCaptureContains(output, "Assets/Conflict.prefab"), "delayed terminal omitted its file header");
        session_count += 1;
        session_start = next;
    }
    try integration.require(session_count == 2, "delayed test did not open two terminal sessions");
    try integration.expectFile(io, arena, first, "Assets/Conflict.prefab", conflict_resolved);
    try integration.expectFile(io, arena, second, "Assets/Conflict.prefab", try std.mem.replaceOwned(u8, arena, conflict_resolved, "m_Value: 4", "m_Value: 5"));
    for ([_][]const u8{ first, second }) |repo| {
        const unmerged = try integration.gitRun(io, arena, repo, &.{ "ls-files", "--unmerged" });
        try integration.expectCode(unmerged, 0, "delayed terminal index");
        try integration.require(unmerged.stdout.len == 0, "delayed terminal left conflict stages");
        try integration.gitOk(io, arena, repo, &.{ "merge", "--abort" });
        try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", conflict_ours);
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
    const markers = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");

    // Clicking the empty Result opens the editor so typing inserts a custom value.
    // The first Enter applies Result. The second Enter confirms Complete.
    const result = runMergetoolInPty(io, arena, repo, "\x1b[<0;83;5M4\r\r", 30) catch |err| {
        if (err == error.Timeout) {
            // A timed-out TUI must leave the original conflict markers available.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", markers);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 0, "complete mergetool in PTY");
    inline for (.{ "components (1)", "Result" }) |text| {
        try integration.require(
            pty.terminalCaptureContains(result.stdout, text),
            "PTY output omitted merge screen text",
        );
    }
    inline for (.{ "Hierarchy", "Inspector", "Apply result", "[ Quit ]" }) |text| {
        try integration.require(
            !pty.terminalCaptureContains(result.stdout, text),
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
    _ = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");

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
    const markers = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");

    // Quit must leave both the merge output and Git's conflict state untouched.
    const result = runMergetoolInPty(io, arena, repo, "\x1b[27uy", 30) catch |err| {
        if (err == error.Timeout) {
            // Timeout cleanup is verified against the exact markers before failing.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", markers);
            return error.PtyMergetoolTimeout;
        }
        return err;
    };
    try integration.expectCode(result, 1, "quit mergetool in PTY");
    try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", markers);
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
    const markers = try integration.expectMarkers(io, arena, repo, "Assets/Conflict.prefab");

    _ = runMergetoolInPty(io, arena, repo, "", 3) catch |err| switch (err) {
        error.Timeout => {
            // A successful abort proves that the timed-out mergetool released Git's merge state.
            try integration.expectFile(io, arena, repo, "Assets/Conflict.prefab", markers);
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
    return pty.runCommandInPty(io, arena, repository, "git mergetool --no-prompt --tool=prefablens -- Assets/Conflict.prefab", input_keys, timeout_seconds);
}
