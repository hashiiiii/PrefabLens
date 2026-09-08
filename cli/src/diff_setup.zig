const std = @import("std");
const merge_git = @import("merge_git.zig");

const Scope = enum { local, user };

pub const usage = "prefablens setup-diff [--local|--user]";
pub const help = usage ++
    "\n\nRegister PrefabLens as a Git difftool for this repository or your user configuration.\n" ++
    "Git, diffnav, delta, and prefablens must be on PATH when the difftool runs.\n";

const command = "diffnav --compare --renderer prefablens --renderer-arg=render-diff --renderer-arg=--color --renderer-arg=-- -- \"$LOCAL\" \"$REMOTE\" \"$MERGED\"";

fn parseScope(args: []const []const u8) !?Scope {
    if (args.len == 0) return .local;
    if (args.len != 1) return error.InvalidSetupArguments;
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return null;
    if (std.mem.eql(u8, args[0], "--local")) return .local;
    if (std.mem.eql(u8, args[0], "--user")) return .user;
    return error.InvalidSetupArguments;
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const []const u8,
    env: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
) !void {
    const scope = (try parseScope(args)) orelse {
        try stdout.writeAll(help);
        return;
    };
    var git: merge_git.Git = .{ .io = io, .arena = arena, .env = env };
    if (scope == .local) {
        const root_result = try git.run(&.{ "rev-parse", "--show-toplevel" });
        if (merge_git.exitCode(root_result) != 0) return error.SetupRequiresRepository;
        git.cwd = merge_git.trim(root_result.stdout);
    }
    const config_scope = if (scope == .user) "--global" else "--local";
    try git.ok(&.{ "config", config_scope, "--replace-all", "diff.tool", "prefablens" });
    try git.ok(&.{ "config", config_scope, "--replace-all", "difftool.prefablens.cmd", command });
    try stdout.print(
        "PrefabLens diff configuration was registered for {s}.\nGit, diffnav, delta, and prefablens must be on PATH when the difftool runs.\n",
        .{if (scope == .user) "your user account" else "this repository"},
    );
}
