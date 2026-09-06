const std = @import("std");
const merge_git = @import("merge_git.zig");
const atomic_file = @import("atomic_file.zig");
const unity_path = @import("unity_path.zig");
const installation = @import("installation.zig");

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, env: *std.process.Environ.Map, stdout: *std.Io.Writer) !void {
    const team = args.len == 1 and std.mem.eql(u8, args[0], "--team");
    if (args.len != 0 and !team) return error.InvalidSetupArguments;
    var git: merge_git.Git = .{ .io = io, .arena = arena, .env = env };
    if (!(try merge_git.version(git)).atLeast(2, 39)) return error.Git239Required;
    git.cwd = merge_git.trim(try git.output(&.{ "rev-parse", "--show-toplevel" }));
    try installation.requireCompatible(git);
    const path = if (team) try git.path(".gitattributes") else merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "info/attributes" }));
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
    try git.ok(&.{ "config", "--local", "merge.prefablens.name", "PrefabLens semantic Unity YAML merge" });
    try git.ok(&.{ "config", "--local", "merge.prefablens.driver", "prefablens merge-driver %O %A %B %P %L" });
    // Virtual merge bases must not ask for semantic decisions or contain a selected partial result.
    try git.ok(&.{ "config", "--local", "merge.prefablens.recursive", "text" });
    try git.ok(&.{ "config", "--local", "mergetool.prefablens.cmd", "prefablens mergetool \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\"" });
    try git.ok(&.{ "config", "--local", "mergetool.prefablens.trustExitCode", "true" });
    try git.ok(&.{ "config", "--local", "pull.twohead", "prefablens" });
    try stdout.writeAll("PrefabLens merge is ready for this repository. Run git merge as usual.\n");
    if (team) try stdout.writeAll("Share .gitattributes with your team. Each clone must run prefablens setup-merge --team once.\n");
}
