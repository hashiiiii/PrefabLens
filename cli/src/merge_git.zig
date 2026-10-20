const std = @import("std");
const merge_io = @import("merge_io.zig");

pub const Git = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cwd: []const u8 = ".",

    pub fn run(self: Git, args: []const []const u8) !std.process.RunResult {
        const argv = try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args });
        return std.process.run(self.arena, self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.cwd },
            .environ_map = self.env,
            .stdout_limit = .limited(256 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    pub fn output(self: Git, args: []const []const u8) ![]const u8 {
        const result = try self.run(args);
        if (exitCode(result) != 0) {
            var buffer: [4096]u8 = undefined;
            var stderr = std.Io.File.Writer.init(std.Io.File.stderr(), self.io, &buffer);
            try merge_io.writeSafeTerminalText(&stderr.interface, result.stderr);
            try stderr.interface.flush();
            return error.GitFailed;
        }
        return result.stdout;
    }

    pub fn ok(self: Git, args: []const []const u8) !void {
        _ = try self.output(args);
    }

    pub fn input(self: Git, args: []const []const u8, bytes: []const u8) !void {
        const argv = try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args });
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.cwd },
            .environ_map = self.env,
            .stdin = .pipe,
            .stdout = .ignore,
            // Index records contain repository-controlled paths; Git's error messages could echo terminal controls from them.
            .stderr = .ignore,
        });
        defer child.kill(self.io);
        try child.stdin.?.writeStreamingAll(self.io, bytes);
        child.stdin.?.close(self.io);
        child.stdin = null;
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }

    pub fn path(self: Git, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena, &.{ self.cwd, relative });
    }
};

pub fn exitCode(result: std.process.RunResult) u8 {
    return if (result.term == .exited) result.term.exited else 255;
}

pub const Version = struct {
    major: u32,
    minor: u32,

    pub fn atLeast(self: Version, major: u32, minor: u32) bool {
        return self.major > major or (self.major == major and self.minor >= minor);
    }
};

pub fn version(git: Git) !Version {
    const result = try git.output(&.{"--version"});
    if (!std.mem.startsWith(u8, result, "git version ")) return error.InvalidGitVersion;
    var parts = std.mem.tokenizeAny(u8, result[12..], ". \r\n");
    return .{
        .major = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidGitVersion, 10),
        .minor = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidGitVersion, 10),
    };
}

pub fn trim(bytes: []const u8) []const u8 {
    return std.mem.trimEnd(u8, bytes, "\r\n");
}
