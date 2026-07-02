const std = @import("std");
const core = @import("core");
const testing = std.testing;

test "parseArgs: two paths default to tree format" {
    const args = [_][]const u8{ "a.prefab", "b.prefab" };
    const opt = try parseArgs(&args);
    try testing.expectEqualStrings("a.prefab", opt.before);
    try testing.expectEqualStrings("b.prefab", opt.after);
    try testing.expectEqual(Format.tree, opt.format);
}

test "parseArgs: --json sets json format" {
    const args = [_][]const u8{ "--json", "a.prefab", "b.prefab" };
    const opt = try parseArgs(&args);
    try testing.expectEqual(Format.json, opt.format);
}

test "run: --json with two real files prints core JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Write fixtures into a temp dir.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--json", before_path, after_path }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"schema\":\"prefablens.diff.v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"0.8\"") != null);
}

test "run: unreadable input file reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--json", "/no/such/file.asset", "/no/such/other.asset" }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read file '/no/such/file.asset'\n", output.items);
}

test "run: no operands prints usage and exits 2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{}, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "usage:") != null);
}

test "run: unknown flag prints error and exits 2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--bogus", "a.prefab", "b.prefab" }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "unknown flag") != null);
}

pub const Format = enum { tree, json, html };

pub const Options = struct {
    before: []const u8,
    after: []const u8,
    format: Format = .tree,
    project_root: ?[]const u8 = null, // for .meta resolution (Task 9)
};

pub const ArgError = error{ MissingOperands, UnknownFlag };

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var format: Format = .tree;
    var project_root: ?[]const u8 = null;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, a, "--html")) {
            format = .html;
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return ArgError.MissingOperands;
            project_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return ArgError.UnknownFlag;
        } else {
            if (pos_count >= 2) return ArgError.UnknownFlag;
            positionals[pos_count] = a;
            pos_count += 1;
        }
    }
    if (pos_count != 2) return ArgError.MissingOperands;
    return .{
        .before = positionals[0].?,
        .after = positionals[1].?,
        .format = format,
        .project_root = project_root,
    };
}

const max_file_bytes = 64 * 1024 * 1024; // 64 MB guard

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes));
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer) !u8 {
    const opt = parseArgs(args) catch |err| {
        switch (err) {
            ArgError.MissingOperands => try stdout.writeAll("usage: prefablens [--json|--html] [--project DIR] <before> <after>\n"),
            ArgError.UnknownFlag => try stdout.writeAll("error: unknown flag\n"),
        }
        return 2;
    };

    const before = readFile(io, arena, opt.before) catch {
        try stdout.print("error: cannot read file '{s}'\n", .{opt.before});
        return 1;
    };
    const after = readFile(io, arena, opt.after) catch {
        try stdout.print("error: cannot read file '{s}'\n", .{opt.after});
        return 1;
    };

    switch (opt.format) {
        .json => {
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        .tree => {
            // Task 11 replaces this branch with the ANSI tree renderer.
            // Until then, fall back to JSON so the binary stays usable and tests stay green.
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        .html => {
            const out = try core.diffToJson(arena, before, after);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
    }
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const user_args = args[1..];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const code = try run(init.io, arena, user_args, stdout);
    try stdout.flush();
    return code;
}
