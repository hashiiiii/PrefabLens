const std = @import("std");
const merge_git = @import("merge_git.zig");
const version = @import("build_options").version;
const Command = enum { primary, helper, driver };

pub fn requireCompatible(git: merge_git.Git) !void {
    try checkedVersion(git, .primary);
    // Git searches exec-path before PATH for its companion command.
    try checkedVersion(git, .helper);
    // The driver inherits Git's PATH, which can differ from the terminal PATH during setup.
    try checkedVersion(git, .driver);

    // Git excludes unknown exec-path commands from the custom merge strategy list.
    var commands = std.mem.tokenizeAny(u8, try git.output(&.{"--list-cmds=others"}), "\r\n");
    while (commands.next()) |command| {
        if (std.mem.eql(u8, command, "merge-prefablens")) return;
    }
    return error.MergeStrategyUnavailable;
}

fn checkedVersion(git: merge_git.Git, command: Command) !void {
    const unavailable = switch (command) {
        .primary => error.PrefabLensUnavailable,
        .helper => error.MergeHelperUnavailable,
        .driver => error.MergeDriverUnavailable,
    };
    const result = std.process.run(git.arena, git.io, .{
        .argv = switch (command) {
            .primary => &.{ "prefablens", "--version" },
            .helper => &.{ "git", "merge-prefablens", "--version" },
            // Zig resolves argv[0] with the parent PATH. A command-local Git alias uses the real driver search without configuration writes.
            .driver => &.{ "git", "-c", "alias.prefablens-installation-version=!prefablens --version", "prefablens-installation-version" },
        },
        .cwd = .{ .path = git.cwd },
        .environ_map = git.env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    }) catch return unavailable;
    if (merge_git.exitCode(result) != 0) return unavailable;
    const expected = if (command == .helper) "git-merge-prefablens " ++ version ++ "\n" else "prefablens " ++ version ++ "\n";
    if (!std.mem.eql(u8, result.stdout, expected)) return switch (command) {
        .primary => error.PrefabLensVersionMismatch,
        .helper => error.MergeHelperVersionMismatch,
        .driver => error.MergeDriverVersionMismatch,
    };
}

pub fn writeError(stderr: *std.Io.Writer, err: anyerror) !bool {
    const message = switch (err) {
        error.PrefabLensUnavailable => "prefablens: Cannot run prefablens --version from PATH.\n",
        error.MergeHelperUnavailable => "prefablens: Git cannot run git-merge-prefablens --version.\n",
        error.MergeDriverUnavailable => "prefablens: Git cannot run prefablens --version from its driver PATH.\n",
        error.PrefabLensVersionMismatch => "prefablens: The PATH command must report 'prefablens " ++ version ++ "'.\n",
        error.MergeHelperVersionMismatch => "prefablens: The Git companion must report 'git-merge-prefablens " ++ version ++ "'.\n",
        error.MergeDriverVersionMismatch => "prefablens: The Git driver PATH must report 'prefablens " ++ version ++ "'.\n",
        error.MergeStrategyUnavailable => {
            try stderr.writeAll("prefablens: Git cannot select git-merge-prefablens as a merge strategy.\nInstall the helper on PATH outside the directory from git --exec-path.\n");
            return true;
        },
        else => return false,
    };
    try stderr.writeAll(message);
    try stderr.writeAll("Install both native commands from release " ++ version ++ ". Check PATH and git --exec-path.\n");
    return true;
}
