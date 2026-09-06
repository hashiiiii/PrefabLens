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

pub const Command = union(enum) {
    diff: []const []const u8,
    merge_strategy: []const []const u8,
    merge_driver: MergeDriverArgs,
    mergetool: MergetoolArgs,
    setup_merge: []const []const u8,
};

pub const Error = error{
    InvalidArguments,
    ReservedSubcommand,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len == 0) return .{ .diff = args };
    if (std.mem.eql(u8, args[0], "setup-merge")) return .{ .setup_merge = args[1..] };
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
    if (std.mem.eql(u8, args[0], "diff-driver") or
        std.mem.eql(u8, args[0], "difftool")) return error.ReservedSubcommand;
    return .{ .diff = args };
}

test "command: parses both merge adapters without changing diff arguments" {
    const driver = try parse(&.{ "merge-driver", "base", "ours", "theirs", "Assets/A.prefab" });
    try testing.expectEqualStrings("ours", driver.merge_driver.ours_output);
    const tool = try parse(&.{ "mergetool", "base", "local", "remote", "merged" });
    try testing.expectEqualStrings("merged", tool.mergetool.merged);
    const diff = try parse(&.{ "HEAD", "Assets/A.prefab" });
    try testing.expectEqual(@as(usize, 2), diff.diff.len);
    try testing.expectError(error.ReservedSubcommand, parse(&.{"diff-driver"}));
    try testing.expectError(error.ReservedSubcommand, parse(&.{"difftool"}));
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
