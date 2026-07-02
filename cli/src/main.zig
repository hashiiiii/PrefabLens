const std = @import("std");
const core = @import("core");
const testing = std.testing;

pub const resolve = @import("resolve.zig");
pub const input = @import("input.zig");
pub const render_tree = @import("render_tree.zig");
pub const render_html = @import("render_html.zig");

test {
    std.testing.refAllDecls(@This());
    _ = resolve;
    _ = input;
    _ = render_tree;
    _ = render_html;
}

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

test "parseArgs: --git captures refs and path" {
    const args = [_][]const u8{ "--json", "--git", "HEAD~1", "HEAD", "Foo.prefab" };
    const opt = try parseArgs(&args);
    try testing.expect(opt.git_mode);
    try testing.expectEqualStrings("HEAD~1", opt.git_ref_before);
    try testing.expectEqualStrings("HEAD", opt.git_ref_after);
    try testing.expectEqualStrings("Foo.prefab", opt.git_path);
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

test "run: hostile deeply-nested input reports a clean error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a before file whose value is nested far past any sane bound.
    const depth = 5000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "--- !u!114 &1\nMonoBehaviour:\n  m_Field: ");
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.appendSlice(arena, "{a: ");
    try src.appendSlice(arena, "1");
    i = 0;
    while (i < depth) : (i += 1) try src.append(arena, '}');

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hostile.asset", .data = src.items });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Field: 1
    });
    const hostile_path = try tmp.dir.realPathFileAlloc(testing.io, "hostile.asset", arena);
    const other_path = try tmp.dir.realPathFileAlloc(testing.io, "other.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ hostile_path, other_path }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: input nested too deeply\n", output.items);
}

test "run: unreadable --project directory reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--json", "--project", "/no/such/project", before_path, after_path }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", output.items);
}

test "run: unreadable --project directory reports error and exits 1 in tree mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    // No --json: the default tree format must honor the same error contract.
    const code = try run(testing.io, arena, &.{ "--project", "/no/such/project", before_path, after_path }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", output.items);
}

test "run: unreadable --project directory reports error and exits 1 in html mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--html", "--project", "/no/such/project", before_path, after_path }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", output.items);
}

test "run: --git with bad ref reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Whether the test cwd is a git repo (bad revision) or not (not a repo),
    // git show fails for a bogus ref -- both must surface as a clean error.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const code = try run(testing.io, arena, &.{ "--json", "--git", "bogus-ref", "HEAD", "Foo.prefab" }, &aw.writer);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: git show failed for 'bogus-ref:Foo.prefab'\n", output.items);
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
    git_mode: bool = false,
    git_ref_before: []const u8 = "",
    git_ref_after: []const u8 = "",
    git_path: []const u8 = "",
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
        } else if (std.mem.eql(u8, a, "--git")) {
            // Expect: --git <beforeRef> <afterRef> <path>
            if (i + 3 >= args.len) return ArgError.MissingOperands;
            return .{
                .before = "",
                .after = "",
                .format = format,
                .project_root = project_root,
                .git_mode = true,
                .git_ref_before = args[i + 1],
                .git_ref_after = args[i + 2],
                .git_path = args[i + 3],
            };
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
            ArgError.MissingOperands => try stdout.writeAll("usage: prefablens [--json|--html] [--project DIR] (<before> <after> | --git <beforeRef> <afterRef> <path>)\n"),
            ArgError.UnknownFlag => try stdout.writeAll("error: unknown flag\n"),
        }
        return 2;
    };

    const before = if (opt.git_mode)
        input.showAtRef(io, arena, ".", opt.git_ref_before, opt.git_path) catch {
            try stdout.print("error: git show failed for '{s}:{s}'\n", .{ opt.git_ref_before, opt.git_path });
            return 1;
        }
    else
        readFile(io, arena, opt.before) catch {
            try stdout.print("error: cannot read file '{s}'\n", .{opt.before});
            return 1;
        };
    const after = if (opt.git_mode)
        input.showAtRef(io, arena, ".", opt.git_ref_after, opt.git_path) catch {
            try stdout.print("error: git show failed for '{s}:{s}'\n", .{ opt.git_ref_after, opt.git_path });
            return 1;
        }
    else
        readFile(io, arena, opt.after) catch {
            try stdout.print("error: cannot read file '{s}'\n", .{opt.after});
            return 1;
        };

    switch (opt.format) {
        .json => {
            const res = core.diffBytes(arena, before, after) catch |err| {
                if (err == error.NestingTooDeep) {
                    try stdout.writeAll("error: input nested too deeply\n");
                    return 1;
                }
                return err;
            };
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                const built = resolve.buildIndex(io, arena, proj) catch {
                    try stdout.print("error: cannot read project directory '{s}'\n", .{proj});
                    return 1;
                };
                idx = built; // Index and Resolver are both StringHashMap([]const u8)
                resolver_ptr = &idx;
            }
            const out = try core.json.serialize(arena, res, resolver_ptr);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        .tree => {
            const res = core.diffBytes(arena, before, after) catch |err| {
                if (err == error.NestingTooDeep) {
                    try stdout.writeAll("error: input nested too deeply\n");
                    return 1;
                }
                return err;
            };
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                idx = resolve.buildIndex(io, arena, proj) catch {
                    try stdout.print("error: cannot read project directory '{s}'\n", .{proj});
                    return 1;
                };
                resolver_ptr = &idx;
            }
            // Color when stdout is a TTY is decided in main(); tests pass color=false.
            try render_tree.render(arena, stdout, res, resolver_ptr, false);
        },
        .html => {
            const res = core.diffBytes(arena, before, after) catch |err| {
                if (err == error.NestingTooDeep) {
                    try stdout.writeAll("error: input nested too deeply\n");
                    return 1;
                }
                return err;
            };
            var resolver_ptr: ?*const core.json.Resolver = null;
            var idx: core.json.Resolver = undefined;
            if (opt.project_root) |proj| {
                idx = resolve.buildIndex(io, arena, proj) catch {
                    try stdout.print("error: cannot read project directory '{s}'\n", .{proj});
                    return 1;
                };
                resolver_ptr = &idx;
            }
            try render_html.render(arena, stdout, res, resolver_ptr);
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
