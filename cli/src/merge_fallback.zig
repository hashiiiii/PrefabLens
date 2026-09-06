const std = @import("std");
const command = @import("command.zig");
const merge_io = @import("merge_io.zig");

pub const Result = struct {
    bytes: []const u8,
    conflicted: bool,
};

const Style = enum { merge, diff3, zdiff3 };
const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } };

/// Use the original three inputs, never the semantic planner's partial output.
pub fn build(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergeDriverArgs,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    force_conflict: bool,
) !Result {
    if (isBinary(base) or isBinary(ours) or isBinary(theirs)) {
        // Git's binary fallback can only select an unchanged side or keep Ours unresolved.
        if (std.mem.eql(u8, ours, theirs) or std.mem.eql(u8, base, theirs))
            return .{ .bytes = ours, .conflicted = false };
        if (std.mem.eql(u8, base, ours)) return .{ .bytes = theirs, .conflicted = false };
        return .{ .bytes = ours, .conflicted = true };
    }
    const style = try conflictStyle(io, arena);
    const size_option = try std.fmt.allocPrint(arena, "--marker-size={d}", .{args.marker_size});
    const native = try std.process.run(arena, io, .{
        .argv = &.{
            "git",     "merge-file", "-p", size_option,
            switch (style) {
                .merge => "--no-diff3",
                .diff3 => "--diff3",
                .zdiff3 => "--zdiff3",
            },
            "-L",      "ours",       "-L", "base",
            "-L",      "theirs",     "--", args.ours_output,
            args.base, args.theirs,
        },
        .stdout_limit = .limited(merge_io.max_output_bytes),
        .stderr_limit = .limited(64 * 1024),
        .timeout = timeout,
    });
    if (native.term != .exited or native.term.exited > 127) return error.TextMergeFailed;
    if (native.term.exited != 0) return .{ .bytes = native.stdout, .conflicted = true };
    if (!force_conflict) return .{ .bytes = native.stdout, .conflicted = false };

    // A clean text merge does not resolve a semantic or unsupported structural conflict.
    var output = std.Io.Writer.Allocating.init(arena);
    try marker(&output.writer, '<', args.marker_size, "ours");
    try side(&output.writer, ours);
    if (style != .merge) {
        try marker(&output.writer, '|', args.marker_size, "base");
        try side(&output.writer, base);
    }
    try marker(&output.writer, '=', args.marker_size, null);
    try side(&output.writer, theirs);
    try marker(&output.writer, '>', args.marker_size, "theirs");
    return .{ .bytes = try output.toOwnedSlice(), .conflicted = true };
}

pub fn isBinary(bytes: []const u8) bool {
    // This is the same prefix Git examines before selecting its binary merge driver.
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null;
}

fn conflictStyle(io: std.Io, arena: std.mem.Allocator) !Style {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "config", "--get", "merge.conflictStyle" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = timeout,
    });
    if (result.term != .exited) return error.GitConfigFailed;
    if (result.term.exited == 1) return .merge;
    if (result.term.exited != 0) return error.GitConfigFailed;
    const value = std.mem.trimEnd(u8, result.stdout, "\r\n");
    return std.meta.stringToEnum(Style, value) orelse error.InvalidConflictStyle;
}

fn marker(writer: *std.Io.Writer, byte: u8, size: u31, label: ?[]const u8) !void {
    try writer.splatByteAll(byte, size);
    if (label) |name| {
        try writer.writeByte(' ');
        try writer.writeAll(name);
    }
    try writer.writeByte('\n');
}

fn side(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
}
