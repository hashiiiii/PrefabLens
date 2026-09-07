const std = @import("std");
const merge_git = @import("merge_git.zig");
const atomic_file = @import("atomic_file.zig");
const unity_path = @import("unity_path.zig");
const installation = @import("installation.zig");

const Scope = enum { project, local, user };
pub const usage = "prefablens setup-merge [--project|--local|--user]";

fn parseScope(args: []const []const u8) !Scope {
    if (args.len == 0) return .local;
    if (args.len != 1) return error.InvalidSetupArguments;
    if (std.mem.eql(u8, args[0], "--project")) return .project;
    if (std.mem.eql(u8, args[0], "--local")) return .local;
    if (std.mem.eql(u8, args[0], "--user")) return .user;
    return error.InvalidSetupArguments;
}

const UserAttributes = struct {
    path: []const u8,
    default_path: ?[]const u8,
};

fn userAttributes(git: merge_git.Git) !UserAttributes {
    const xdg = git.env.get("XDG_CONFIG_HOME") orelse "";
    const default = if (xdg.len == 0) "~/.config/git/attributes" else try std.fs.path.join(git.arena, &.{ xdg, "git/attributes" });
    // Git expands home paths on every platform, including values in included user configuration.
    const configured = try git.run(&.{ "config", "--global", "--includes", "--path", "--null", "--get", "core.attributesFile" });
    const missing = merge_git.exitCode(configured) == 1;
    if (!missing and merge_git.exitCode(configured) != 0) {
        try std.Io.File.stderr().writeStreamingAll(git.io, configured.stderr);
        return error.GitFailed;
    }
    const output = if (missing)
        try git.output(&.{ "config", "--global", "--includes", "--path", "--null", "--get", "--default", default, "core.attributesFile" })
    else
        configured.stdout;
    const path = std.mem.trimEnd(u8, output, "\x00");
    // Relative global paths select a different file in each repository and cannot provide user-wide setup.
    if (!std.fs.path.isAbsolute(path)) return error.InvalidUserAttributesPath;
    // User attributes are often symlinked from dotfiles; update the target without replacing the link.
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(git.io, path, git.arena) catch |err| switch (err) {
        error.FileNotFound => path,
        else => return err,
    };
    return .{ .path = resolved, .default_path = if (missing) default else null };
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, env: *std.process.Environ.Map, stdout: *std.Io.Writer) !void {
    const scope = try parseScope(args);
    var git: merge_git.Git = .{ .io = io, .arena = arena, .env = env };
    if (!(try merge_git.version(git)).atLeast(2, 39)) return error.Git239Required;
    if (scope != .user) {
        const root = git.output(&.{ "rev-parse", "--show-toplevel" }) catch |err| {
            return if (err == error.GitFailed) error.SetupRequiresRepository else err;
        };
        git.cwd = merge_git.trim(root);
    }
    try installation.requireCompatible(git);
    var default_user_path: ?[]const u8 = null;
    const path = switch (scope) {
        .project => try git.path(".gitattributes"),
        .local => merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "info/attributes" })),
        .user => blk: {
            const attributes = try userAttributes(git);
            default_user_path = attributes.default_path;
            break :blk attributes.path;
        },
    };
    const absolute = if (std.fs.path.isAbsolute(path)) path else try git.path(path);
    const old = std.Io.Dir.cwd().readFileAlloc(io, absolute, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var attributes: std.ArrayList(u8) = .empty;
    try attributes.appendSlice(arena, old);
    if (old.len != 0 and old[old.len - 1] != '\n') try attributes.append(arena, '\n');
    for (unity_path.extensions) |extension| {
        const line = try std.fmt.allocPrint(arena, "*{s} merge=prefablens\n", .{extension});
        var lines = std.mem.splitScalar(u8, old, '\n');
        var found = false;
        while (lines.next()) |existing| {
            if (std.mem.eql(u8, std.mem.trim(u8, existing, " \t\r"), std.mem.trimEnd(u8, line, "\n"))) found = true;
        }
        if (!found) try attributes.appendSlice(arena, line);
    }
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(absolute).?);
    if (!std.mem.eql(u8, old, attributes.items)) try atomic_file.replace(io, arena, absolute, if (old.len == 0) null else old, attributes.items);
    // A system attributesFile setting would otherwise prevent Git from reading the fallback user file.
    if (default_user_path) |default| try git.ok(&.{ "config", "--global", "core.attributesFile", default });
    const config_scope = if (scope == .user) "--global" else "--local";
    try git.ok(&.{ "config", config_scope, "merge.prefablens.name", "PrefabLens semantic Unity YAML merge" });
    try git.ok(&.{ "config", config_scope, "merge.prefablens.driver", "prefablens merge-driver %O %A %B %P %L" });
    // Virtual merge bases must not ask for semantic decisions or contain a selected partial result.
    try git.ok(&.{ "config", config_scope, "merge.prefablens.recursive", "text" });
    try git.ok(&.{ "config", config_scope, "mergetool.prefablens.cmd", "prefablens mergetool \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\"" });
    try git.ok(&.{ "config", config_scope, "mergetool.prefablens.trustExitCode", "true" });
    try git.ok(&.{ "config", config_scope, "pull.twohead", "prefablens" });
    try stdout.print("PrefabLens merge is ready for {s}. Run git merge as usual.\n", .{if (scope == .user) "your repositories" else "this repository"});
    if (scope == .project) try stdout.writeAll("Commit .gitattributes to share the rules. Each clone needs setup unless your user configuration already provides it.\n");
}
