const std = @import("std");
const testing = std.testing;

pub const MergeDriverArgs = struct {
    base: []const u8,
    ours_output: []const u8,
    theirs: []const u8,
    path: []const u8,
    marker_size: u31 = 7,
};

pub const MergetoolArgs = struct {
    base: []const u8,
    local: []const u8,
    remote: []const u8,
    merged: []const u8,
};

pub const DiffDriverCompare = struct {
    path: []const u8,
    old_file: []const u8,
    new_file: []const u8,
};

pub const DiffDriverArgs = union(enum) {
    help,
    skip,
    compare: DiffDriverCompare,
};

pub const Command = union(enum) {
    diff: []const []const u8,
    diff_driver: DiffDriverArgs,
    merge_strategy: []const []const u8,
    merge_driver: MergeDriverArgs,
    mergetool: MergetoolArgs,
    setup_merge: []const []const u8,
    setup_diff: []const []const u8,
};

pub const Error = error{
    InvalidArguments,
    ReservedSubcommand,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len == 0) return .{ .diff = args };
    if (std.mem.eql(u8, args[0], "setup-diff")) return .{ .setup_diff = args[1..] };
    if (std.mem.eql(u8, args[0], "setup-merge")) return .{ .setup_merge = args[1..] };
    if (std.mem.eql(u8, args[0], "diff-driver")) return .{ .diff_driver = try parseDiffDriver(args[1..]) };
    if (std.mem.eql(u8, args[0], "merge-strategy")) return .{ .merge_strategy = args[1..] };
    if (std.mem.eql(u8, args[0], "merge-driver")) {
        if (args.len != 5 and args.len != 6) return error.InvalidArguments;
        const marker_size = if (args.len == 6)
            std.fmt.parseInt(u31, args[5], 10) catch return error.InvalidArguments
        else
            7;
        if (marker_size == 0) return error.InvalidArguments;
        return .{ .merge_driver = .{
            .base = args[1],
            .ours_output = args[2],
            .theirs = args[3],
            .path = args[4],
            .marker_size = marker_size,
        } };
    }
    if (std.mem.eql(u8, args[0], "mergetool")) {
        if (args.len != 5) return error.InvalidArguments;
        return .{ .mergetool = .{
            .base = args[1],
            .local = args[2],
            .remote = args[3],
            .merged = args[4],
        } };
    }
    if (std.mem.eql(u8, args[0], "difftool")) return error.ReservedSubcommand;
    return .{ .diff = args };
}

fn parseDiffDriver(args: []const []const u8) Error!DiffDriverArgs {
    if (args.len == 0) return .help;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    // Unmerged paths reach GIT_EXTERNAL_DIFF with only the repository path.
    if (args.len == 1) return .skip;
    if (args.len < 7) return error.InvalidArguments;
    return .{ .compare = .{
        .path = args[0],
        .old_file = args[1],
        .new_file = args[4],
    } };
}

test "command: parses both merge adapters without changing diff arguments" {
    const driver = try parse(&.{ "merge-driver", "base", "ours", "theirs", "Assets/A.prefab" });
    try testing.expectEqualStrings("ours", driver.merge_driver.ours_output);
    const tool = try parse(&.{ "mergetool", "base", "local", "remote", "merged" });
    try testing.expectEqualStrings("merged", tool.mergetool.merged);
    const diff = try parse(&.{ "HEAD", "Assets/A.prefab" });
    try testing.expectEqual(@as(usize, 2), diff.diff.len);
    try testing.expectError(error.ReservedSubcommand, parse(&.{"difftool"}));
}

test "command: maps git external diff operands onto two file paths" {
    const seven = try parse(&.{
        "diff-driver",
        "Assets/A.prefab",
        "/tmp/old",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "100644",
        "/tmp/new",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "100644",
    });
    try testing.expectEqualStrings("Assets/A.prefab", seven.diff_driver.compare.path);
    try testing.expectEqualStrings("/tmp/old", seven.diff_driver.compare.old_file);
    try testing.expectEqualStrings("/tmp/new", seven.diff_driver.compare.new_file);

    const renamed = try parse(&.{
        "diff-driver",
        "Assets/B.prefab",
        "/tmp/old",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "100644",
        "/tmp/new",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "100644",
        "Assets/A.prefab",
        "similarity index 95%",
    });
    try testing.expectEqualStrings("Assets/B.prefab", renamed.diff_driver.compare.path);
    try testing.expectEqualStrings("/tmp/new", renamed.diff_driver.compare.new_file);

    try testing.expect((try parse(&.{ "diff-driver", "Assets/Conflict.prefab" })).diff_driver == .skip);
    try testing.expect((try parse(&.{"diff-driver"})).diff_driver == .help);
    try testing.expectError(error.InvalidArguments, parse(&.{ "diff-driver", "path", "old" }));
    const setup = try parse(&.{ "setup-diff", "--user" });
    try testing.expectEqualStrings("--user", setup.setup_diff[0]);
}

test "command: merge adapters reject missing or invalid operands" {
    // Git invokes adapters mechanically, so accepting a shifted operand could overwrite the wrong file.
    try testing.expectError(error.InvalidArguments, parse(&.{ "merge-driver", "base", "ours", "theirs" }));
    try testing.expectError(error.InvalidArguments, parse(&.{ "merge-driver", "base", "ours", "theirs", "path", "extra" }));
    try testing.expectError(error.InvalidArguments, parse(&.{ "mergetool", "base", "local", "remote" }));
    try testing.expectError(error.InvalidArguments, parse(&.{ "mergetool", "base", "local", "remote", "merged", "extra" }));
}

test "command: merge driver accepts a positive marker size operand" {
    const driver = try parse(&.{ "merge-driver", "base", "ours", "theirs", "path", "11" });
    try testing.expectEqualStrings("ours", driver.merge_driver.ours_output);
    try testing.expectError(error.InvalidArguments, parse(&.{ "merge-driver", "base", "ours", "theirs", "path", "0" }));
    try testing.expectError(error.InvalidArguments, parse(&.{ "merge-driver", "base", "ours", "theirs", "path", "-1" }));
    try testing.expectError(error.InvalidArguments, parse(&.{ "merge-driver", "base", "ours", "theirs", "path", "11", "extra" }));
}

test "command: only the first argument selects a reserved subcommand" {
    // A ref can share a reserved spelling, and existing diff operands must reach parseArgs unchanged.
    const diff = try parse(&.{ "HEAD", "merge-driver" });
    try testing.expectEqual(@as(usize, 2), diff.diff.len);
    try testing.expectEqualStrings("merge-driver", diff.diff[1]);
}
