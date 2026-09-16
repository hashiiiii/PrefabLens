const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("mergetool_terminal.zig");
const windows = @import("mergetool_terminal_windows.zig");
const integration = @import("testing/git.zig");
const pty = @import("testing/pty.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (builtin.os.tag == .windows and args.len > 2 and std.mem.eql(u8, args[1], "--console-probe")) {
        // Inspect real console handles in the child; inherited CI pipes must fail this check.
        if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) return 90;
        if (!std.mem.eql(u8, args[3], try std.process.currentPathAlloc(io, arena))) return 91;
        if (!std.mem.eql(u8, args[4], "日本語 space %PATH% ! & trailing\\")) return 92;
        if (std.mem.eql(u8, args[2], "closed")) std.os.windows.ntdll.RtlExitUserProcess(0xc000013a);
        return std.fmt.parseInt(u8, args[2], 10);
    }
    try integration.require(args.len == 2, "expected the prefablens executable path");
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    if (builtin.os.tag == .windows) {
        const executable = try std.process.executablePathAlloc(io, arena);
        const cwd = try std.process.currentPathAlloc(io, arena);
        for ([_][]const u8{ "0", "1", "2", "closed" }, [_]u8{ 0, 1, 2, 2 }) |code, expected| {
            const actual = try windows.run(arena, &.{ executable, "--console-probe", code, cwd, "日本語 space %PATH% ! & trailing\\" });
            try integration.require(actual == expected, "new console changed arguments, cwd, handles, or exit status");
        }
        try integration.require(try windows.run(arena, &.{ prefablens, "--version" }) == 0, "new console could not run the installed CLI");
    } else if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const scratch = try integration.scratchDirectory(io, arena, "terminal");
        defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
        try macCommand(io, arena, scratch, prefablens, init.environ_map);
        try macClose(io, arena, scratch, init.environ_map);
        try macEarlyClose(io, arena, scratch, init.environ_map);
    }
    try std.Io.File.stdout().writeStreamingAll(io, "terminal launcher integration: passed\n");
    return 0;
}

fn macCommand(io: std.Io, arena: std.mem.Allocator, scratch: []const u8, prefablens: []const u8, env: *std.process.Environ.Map) !void {
    const root = try std.fs.path.join(arena, &.{ scratch, "日本語 ' $(touch INJECTED)" });
    try std.Io.Dir.cwd().createDirPath(io, root);
    const executable = try std.fs.path.join(arena, &.{ root, "PrefabLens CLI" });
    try std.Io.Dir.cwd().copyFile(prefablens, .cwd(), executable, io, .{ .permissions = .executable_file });
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n";
    const original = "unresolved output stays unchanged on cancel\n";
    try integration.writeFile(io, arena, root, "base", base);
    try integration.writeFile(io, arena, root, "ours", ours);
    try integration.writeFile(io, arena, root, "theirs", theirs);
    for ([_]bool{ false, true }) |cancel| {
        try integration.writeFile(io, arena, root, "result.prefab", original);
        // Execute the same generated .command in a real PTY, without depending on a desktop login session.
        const session = try terminal.MacSession.create(io, arena, scratch, root, &.{ executable, "mergetool", "base", "ours", "theirs", "result.prefab" }, env);
        defer session.deinit(io);
        const result = try pty.runCommandInPtyBatches(io, arena, "/", try terminal.shellQuote(arena, session.command_path), if (cancel) "\x1b[27uy" else "\x1b[C\r\r", "", 20);
        const expected: u8 = if (cancel) 1 else 0;
        try integration.expectCode(result, expected, "terminal merge exit status");
        try integration.require(try session.wait(io, arena) == expected, "caller received the wrong merge result");
        try integration.expectFile(io, arena, root, "result.prefab", if (cancel) original else ours);
        try integration.require(std.mem.indexOf(u8, result.stdout, "PrefabLens exit:") != null, "terminal omitted its final result");
    }
    const injected = try std.fs.path.join(arena, &.{ root, "INJECTED" });
    std.Io.Dir.cwd().access(io, injected, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ShellExpandedFileName;
}

fn macClose(io: std.Io, arena: std.mem.Allocator, scratch: []const u8, env: *std.process.Environ.Map) !void {
    // Closing Terminal sends HUP. The shell must stop its child before telling Fork it was cancelled.
    const session = try terminal.MacSession.create(io, arena, scratch, scratch, &.{ "/bin/sleep", "60" }, env);
    defer session.deinit(io);
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", session.command_path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        std.Io.Dir.cwd().access(io, session.pid_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (start.durationTo(std.Io.Clock.awake.now(io)).toSeconds() > 5) return error.TerminalDidNotStart;
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        break;
    }
    try std.posix.kill(child.id.?, .HUP);
    try integration.require(try session.wait(io, arena) == 1, "window close did not report cancellation");
    _ = try child.wait(io);
}

fn macEarlyClose(io: std.Io, arena: std.mem.Allocator, scratch: []const u8, env: *std.process.Environ.Map) !void {
    const session = try terminal.MacSession.create(io, arena, scratch, scratch, &.{ "/bin/sleep", "60" }, env);
    defer session.deinit(io);
    const child_pid_path = try std.fs.path.join(arena, &.{ scratch, "early-child.pid" });
    const script = try std.Io.Dir.cwd().readFileAlloc(io, session.command_path, arena, .limited(64 * 1024));
    // Inject a real HUP between spawning the child and recording its PID, without relying on scheduler timing.
    const interruption = try std.fmt.allocPrint(arena, "printf '%s\\n' \"$!\" > {s}\nkill -HUP \"$$\"\nchild=$!\n", .{try terminal.shellQuote(arena, child_pid_path)});
    const interrupted = try std.mem.replaceOwned(u8, arena, script, "child=$!\n", interruption);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = session.command_path, .data = interrupted });
    const launch = try std.fmt.allocPrint(arena, "exec /bin/sh {s} >/dev/null 2>&1", .{try terminal.shellQuote(arena, session.command_path)});
    const result = try std.process.run(arena, io, .{ .argv = &.{ "/bin/sh", "-c", launch }, .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } } });
    const child_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(io, child_pid_path, arena, .limited(32)), "\r\n"), 10);
    defer std.posix.kill(child_pid, .KILL) catch {};
    try integration.expectCode(result, 1, "cancel during terminal startup");
    try integration.require(try session.wait(io, arena) == 1, "startup cancellation was not returned");
    std.posix.kill(child_pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
    return error.TerminalChildWasOrphaned;
}
