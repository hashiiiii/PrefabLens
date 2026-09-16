const std = @import("std");
const builtin = @import("builtin");
const command = @import("command.zig");
const windows = @import("mergetool_terminal_windows.zig");

test {
    _ = windows;
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: command.MergetoolArgs, env: *std.process.Environ.Map) !u8 {
    const executable = try std.process.executablePathAlloc(io, arena);
    const argv = [_][]const u8{ executable, "mergetool", args.base, args.local, args.remote, args.merged };
    return switch (builtin.os.tag) {
        .macos => blk: {
            const cwd = try std.process.currentPathAlloc(io, arena);
            const session = try MacSession.create(io, arena, env.get("TMPDIR") orelse "/tmp", cwd, &argv, env);
            defer session.deinit(io);
            const result = try std.process.run(arena, io, .{
                .argv = &.{ "/usr/bin/open", "-b", "com.apple.Terminal", session.command_path },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
                .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
            });
            if (result.term != .exited or result.term.exited != 0) return error.TerminalLaunchFailed;
            break :blk try session.wait(io, arena);
        },
        .windows => windows.run(arena, &argv),
        else => error.TerminalLaunchUnsupported,
    };
}

pub const MacSession = struct {
    directory: []const u8,
    command_path: []const u8,
    status_path: []const u8,
    pid_path: []const u8,

    pub fn create(
        io: std.Io,
        arena: std.mem.Allocator,
        temp_root: []const u8,
        cwd: []const u8,
        argv: []const []const u8,
        env: *std.process.Environ.Map,
    ) !MacSession {
        var random: [16]u8 = undefined;
        io.random(&random);
        const directory = try std.fs.path.resolve(arena, &.{ temp_root, try std.fmt.allocPrint(arena, "prefablens-merge-{x}", .{random}) });
        // The command contains Git environment values and must remain private to this user.
        try std.Io.Dir.cwd().createDir(io, directory, .fromMode(0o700));
        const session: MacSession = .{
            .directory = directory,
            .command_path = try std.fs.path.join(arena, &.{ directory, "PrefabLens.command" }),
            .status_path = try std.fs.path.join(arena, &.{ directory, "status" }),
            .pid_path = try std.fs.path.join(arena, &.{ directory, "pid" }),
        };
        errdefer session.deinit(io);
        var script: std.Io.Writer.Allocating = .init(arena);
        const out = &script.writer;
        try out.writeAll("#!/bin/sh\n");
        try out.print("status={s}\n", .{try shellQuote(arena, session.status_path)});
        try out.writeAll(
            \\finish() {
            \\    result=$?
            \\    trap - EXIT HUP INT TERM
            \\    if [ -n "$child" ]; then
            \\        kill -TERM "$child" 2>/dev/null
            \\        wait "$child" 2>/dev/null
            \\    fi
            \\    [ "$result" -lt 128 ] || result=1
            \\    printf '%s\n' "$result" > "$status.tmp" && /bin/mv -f "$status.tmp" "$status"
            \\    printf '\nPrefabLens exit: %s\n' "$result"
            \\}
            \\trap finish EXIT
            \\child=
            \\cancelled=
            \\trap 'cancelled=1; if [ -n "$child" ]; then exit 1; fi' HUP INT TERM
            \\exec 3<&0
            \\
        );
        try out.print("cd {s} || exit 2\n", .{try shellQuote(arena, cwd)});
        // Terminal starts a login shell, so restore the invoking Git client's repository context.
        var entries = env.iterator();
        while (entries.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.eql(u8, key, "PATH") and !std.mem.startsWith(u8, key, "GIT_")) continue;
            for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEnvironmentName;
            try out.print("export {s}={s}\n", .{ key, try shellQuote(arena, entry.value_ptr.*) });
        }
        for (argv, 0..) |arg, index| {
            if (index > 0) try out.writeByte(' ');
            try out.writeAll(try shellQuote(arena, arg));
        }
        // Explicit stdin keeps the asynchronous child attached to the terminal while wait handles window-close signals.
        try out.writeAll(" <&3 &\nchild=$!\n");
        try out.writeAll("[ -z \"$cancelled\" ] || exit 1\n");
        try out.print("pid_file={s}\nprintf '%s\\n' \"$$\" > \"$pid_file.tmp\" && /bin/mv -f \"$pid_file.tmp\" \"$pid_file\"\n", .{try shellQuote(arena, session.pid_path)});
        try out.writeAll("wait \"$child\"\nresult=$?\nchild=\nexit \"$result\"\n");
        const file = try std.Io.Dir.cwd().createFile(io, session.command_path, .{ .exclusive = true, .permissions = .fromMode(0o700) });
        defer file.close(io);
        try file.writeStreamingAll(io, script.written());
        return session;
    }

    pub fn deinit(session: MacSession, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, session.directory) catch {};
    }

    pub fn wait(session: MacSession, io: std.Io, arena: std.mem.Allocator) !u8 {
        const start = std.Io.Clock.awake.now(io);
        var pid: ?std.posix.pid_t = null;
        while (true) {
            if (try session.status(io, arena)) |code| return code;
            if (pid) |running| {
                std.posix.kill(running, @enumFromInt(0)) catch {
                    // A signal can stop the shell before its EXIT trap writes the result.
                    return (try session.status(io, arena)) orelse 2;
                };
            } else {
                const bytes = std.Io.Dir.cwd().readFileAlloc(io, session.pid_path, arena, .limited(32)) catch |err| switch (err) {
                    error.FileNotFound => "",
                    else => return err,
                };
                pid = try readPid(bytes);
                if (pid == null and start.durationTo(std.Io.Clock.awake.now(io)).toSeconds() >= 60)
                    return error.TerminalStartupTimeout;
            }
            try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        }
    }

    fn status(session: MacSession, io: std.Io, arena: std.mem.Allocator) !?u8 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, session.status_path, arena, .limited(32)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const code = std.fmt.parseInt(u8, std.mem.trim(u8, bytes, "\r\n"), 10) catch return error.InvalidTerminalStatus;
        return if (code <= 2) code else 2;
    }
};

fn readPid(bytes: []const u8) !?std.posix.pid_t {
    if (!std.mem.endsWith(u8, bytes, "\n")) return null;
    const number = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, "\r\n"), 10) catch return null;
    if (number <= 0) return error.InvalidTerminalProcess;
    return number;
}

test "terminal: a partially published PID cannot identify another process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), try readPid("123"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, 123), try readPid("123\n"));
}

pub fn shellQuote(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(arena, "'\\''");
        } else {
            try quoted.append(arena, byte);
        }
    }
    try quoted.append(arena, '\'');
    return quoted.toOwnedSlice(arena);
}

test "terminal: macOS command preserves Git environment and reports process failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "prefablens.launch-test");
    try env.put("GIT_CONFIG_VALUE_0", "日本語 ' $value `uname`\nsecond line");
    // Terminal's login shell must not replace the invoking Git client's literal configuration.
    const session = try MacSession.create(std.testing.io, arena, root, root, &.{ "git", "config", "--get", "prefablens.launch-test" }, &env);
    defer session.deinit(std.testing.io);
    const result = try std.process.run(arena, std.testing.io, .{ .argv = &.{ "/bin/sh", session.command_path }, .cwd = .{ .path = "/" } });
    try std.testing.expectEqual(@as(u8, 0), try session.wait(std.testing.io, arena));
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "日本語 ' $value `uname`\nsecond line\n"));
    const failure = try MacSession.create(std.testing.io, arena, root, root, &.{ "git", "config", "--get", "prefablens.missing" }, &env);
    defer failure.deinit(std.testing.io);
    _ = try std.process.run(arena, std.testing.io, .{ .argv = &.{ "/bin/sh", failure.command_path } });
    try std.testing.expectEqual(@as(u8, 1), try failure.wait(std.testing.io, arena));
}
