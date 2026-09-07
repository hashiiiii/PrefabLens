const std = @import("std");
const core = @import("core");
const merge_git = @import("merge_git.zig");
const revisions = @import("merge_strategy_revisions.zig");
const file_choice = @import("merge_file_choice.zig");
const merge_io = @import("merge_io.zig");
const Git = merge_git.Git;

// No virtual ancestor is reconstructed. A resumed tool discovers the same
// unknown ancestry from Git, even when stage 1 could not be represented.
pub fn inMerge(git: Git) !bool {
    const relative = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "MERGE_HEAD" }));
    const path = if (std.fs.path.isAbsolute(relative)) relative else try git.path(relative);
    const bytes = std.Io.Dir.cwd().readFileAlloc(git.io, path, git.arena, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    const remote = merge_git.trim(bytes);
    if ((remote.len != 40 and remote.len != 64) or std.mem.indexOfScalar(u8, remote, '\n') != null) return false;
    return (try revisions.read(git, "HEAD", remote)).known == null;
}

// This fallback makes one explicit whole-file decision. It has no automatic
// branch and does not pretend that an absent merge base means an added file.
pub fn choose(git: Git, env: *std.process.Environ.Map, path: []const u8, ours: []const u8, theirs: []const u8) !?[]const u8 {
    const decision = try file_choice.run(git.io, git.arena, env, .{ .base = "unavailable (multiple or absent ancestors)", .ours = path, .theirs = path, .paired_meta = false, .unknown_context = true });
    const bytes = switch (decision) {
        .ours => ours,
        .theirs => theirs,
        .custom => try edit(git, ours),
        .quit => return null,
        else => return error.InvalidResolution,
    };
    // Explicit whole sides still need syntax and structure validation. No
    // individual ancestor can establish schema evidence when history is unknown.
    _ = try core.merge.build(git.arena, bytes, bytes, bytes);
    return bytes;
}

fn edit(git: Git, initial: []const u8) ![]const u8 {
    const relative = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "index" }));
    const index = if (std.fs.path.isAbsolute(relative)) relative else try git.path(relative);
    var random: [16]u8 = undefined;
    git.io.random(&random);
    const path = try std.fmt.allocPrint(git.arena, "{s}.prefablens-custom-{x}.prefab", .{ index, random });
    const file = try std.Io.Dir.cwd().createFile(git.io, path, .{ .exclusive = true });
    defer std.Io.Dir.cwd().deleteFile(git.io, path) catch {};
    {
        defer file.close(git.io);
        try file.writeStreamingAll(git.io, initial);
    }
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(git.io, path, git.arena);
    const editor = merge_git.trim(try git.output(&.{ "var", "GIT_EDITOR" }));
    // The configured editor is a shell command; the private filename remains a
    // positional argument so its bytes never become executable shell syntax.
    const command = try std.fmt.allocPrint(git.arena, "{s} \"$1\"", .{editor});
    var child = try std.process.spawn(git.io, .{ .argv = &.{ "sh", "-c", command, "prefablens-editor", absolute }, .cwd = .{ .path = git.cwd }, .environ_map = git.env, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit });
    defer child.kill(git.io);
    const term = try child.wait(git.io);
    if (term != .exited or term.exited != 0) return error.EditorFailed;
    return merge_io.readLimited(git.io, git.arena, absolute);
}
