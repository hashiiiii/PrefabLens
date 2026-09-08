const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");
const pty = @import("pty.zig");

const Session = @This();
const capture_allocator = std.heap.page_allocator;

io: std.Io,
arena: std.mem.Allocator,
child: std.process.Child,
capture_path: []const u8,
status_path: []const u8,
pid_path: []const u8,
tty_path: []const u8,
replies: [3]usize = .{ 0, 0, 0 },

pub fn start(io: std.Io, arena: std.mem.Allocator, directory: []const u8, env: *const std.process.Environ.Map, prefix: []const u8, command: []const u8) !Session {
    const capture_path = try std.fmt.allocPrint(arena, "{s}.ansi", .{prefix});
    const status_path = try std.fmt.allocPrint(arena, "{s}.status", .{prefix});
    const pid_path = try std.fmt.allocPrint(arena, "{s}.pid", .{prefix});
    const tty_path = try std.fmt.allocPrint(arena, "{s}.tty", .{prefix});
    const terminal_command = try std.fmt.allocPrint(
        arena,
        "stty cols 100 rows 24; printf '%s' \"$$\" > {s}; tty > {s}; {s}; printf '%s' \"$?\" > {s}",
        .{ try git.shellQuote(arena, pid_path), try git.shellQuote(arena, tty_path), command, try git.shellQuote(arena, status_path) },
    );
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ "script", "-qfec", terminal_command, capture_path },
        .macos => &.{ "script", "-qF", capture_path, "sh", "-c", terminal_command },
        else => return error.UnsupportedOperatingSystem,
    };
    return .{
        .io = io,
        .arena = arena,
        .child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = directory },
            .environ_map = env,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .inherit,
        }),
        .capture_path = capture_path,
        .status_path = status_path,
        .pid_path = pid_path,
        .tty_path = tty_path,
    };
}

pub fn deinit(self: *Session) void {
    if (self.child.id != null) {
        // The shell inside script owns the PTY process group, including Git and its tools.
        const pid_bytes = self.read(self.pid_path) catch "";
        defer capture_allocator.free(pid_bytes);
        const pid = std.fmt.parseInt(std.posix.pid_t, pid_bytes, 10) catch 0;
        if (pid > 1) std.posix.kill(-pid, .KILL) catch {};
        self.child.kill(self.io);
    }
    for ([_][]const u8{ self.capture_path, self.status_path, self.pid_path, self.tty_path }) |path| {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    }
}

pub fn send(self: *Session, keys: []const u8) !void {
    try self.child.stdin.?.writeStreamingAll(self.io, keys);
}

pub fn waitFor(self: *Session, needles: []const []const u8) !void {
    return self.waitForMatches(needles, null);
}

pub fn waitForLineCount(self: *Session, needle: []const u8, count: usize) !void {
    return self.waitForMatches(&.{needle}, count);
}

fn waitForMatches(self: *Session, needles: []const []const u8, expected_count: ?usize) !void {
    const started = std.Io.Clock.awake.now(self.io);
    while (started.durationTo(std.Io.Clock.awake.now(self.io)).toSeconds() < 10) {
        const captured = try self.capture();
        defer capture_allocator.free(captured);
        // Inspect the current screen so an earlier semantic view cannot satisfy a later toggle.
        const ready = for (needles) |needle| {
            const count = pty.terminalScreenLineCount(captured, needle);
            if (if (expected_count) |expected| count != expected else count == 0) break false;
        } else true;
        if (ready) return;
        if (try self.exitCode() != null) break;
        try std.Io.sleep(self.io, .fromMilliseconds(25), .awake);
    }
    const captured = try self.capture();
    defer capture_allocator.free(captured);
    for (needles) |needle| {
        if (!pty.terminalScreenContains(captured, needle)) std.debug.print("PTY missing: {s}\n", .{needle});
    }
    std.debug.print("PTY capture:\n{s}\n", .{captured});
    return error.TerminalExpectationFailed;
}

pub fn resize(self: *Session, columns: u16, rows: u16) !void {
    const tty_bytes = try self.read(self.tty_path);
    defer capture_allocator.free(tty_bytes);
    const tty_path = std.mem.trim(u8, tty_bytes, "\r\n");
    const result = try std.process.run(self.arena, self.io, .{
        .argv = &.{
            "stty",                                             if (builtin.os.tag == .macos) "-f" else "-F",          tty_path,
            "cols",                                             try std.fmt.allocPrint(self.arena, "{d}", .{columns}), "rows",
            try std.fmt.allocPrint(self.arena, "{d}", .{rows}),
        },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
    });
    try git.expectCode(result, 0, "resize difftool terminal");
}

pub fn finish(self: *Session) !void {
    try self.send("q");
    const started = std.Io.Clock.awake.now(self.io);
    while (started.durationTo(std.Io.Clock.awake.now(self.io)).toSeconds() < 5) {
        const captured = try self.capture();
        capture_allocator.free(captured);
        if (try self.exitCode()) |code| {
            try git.require(code == 0, "Git difftool did not exit cleanly");
            const term = try self.child.wait(self.io);
            try git.require(term == .exited and term.exited == 0, "PTY did not exit cleanly");
            return;
        }
        try std.Io.sleep(self.io, .fromMilliseconds(25), .awake);
    }
    return error.TerminalExitTimeout;
}

fn capture(self: *Session) ![]const u8 {
    const bytes = try self.read(self.capture_path);
    errdefer capture_allocator.free(bytes);
    const queries = [_][]const u8{ "\x1b[6n", "\x1b]10;?", "\x1b]11;?" };
    const responses = [_][]const u8{ "\x1b[1;1R", "\x1b]10;rgb:eeee/eeee/eeee\x1b\\", "\x1b]11;rgb:1111/1111/1111\x1b\\" };
    for (queries, responses, &self.replies) |query, response, *replies| {
        const count = std.mem.count(u8, bytes, query);
        while (replies.* < count) : (replies.* += 1) try self.send(response);
    }
    return bytes;
}

fn read(self: Session, path: []const u8) ![]const u8 {
    // Poll buffers must be released independently of the fixture's long-lived arena.
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, capture_allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
}

fn exitCode(self: Session) !?u8 {
    const bytes = try self.read(self.status_path);
    defer capture_allocator.free(bytes);
    return if (bytes.len == 0) null else try std.fmt.parseInt(u8, bytes, 10);
}
