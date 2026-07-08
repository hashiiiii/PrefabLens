const std = @import("std");
const core = @import("core");
const testing = std.testing;

pub const resolve = @import("resolve.zig");
pub const input = @import("input.zig");
pub const display = @import("display.zig");
pub const render_tree = @import("render_tree.zig");
pub const render_html = @import("render_html.zig");
pub const mcp = @import("mcp.zig");

test {
    std.testing.refAllDecls(@This());
    _ = resolve;
    _ = input;
    _ = display;
    _ = render_tree;
    _ = render_html;
    _ = mcp;
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

test "parseArgs: --no-color sets no_color, off by default" {
    const default_args = [_][]const u8{ "a.prefab", "b.prefab" };
    try testing.expect(!(try parseArgs(&default_args)).no_color);

    const args = [_][]const u8{ "--no-color", "a.prefab", "b.prefab" };
    const opt = try parseArgs(&args);
    try testing.expect(opt.no_color);
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

test "parseArgs: flags after --git operands are honored, not dropped" {
    const args = [_][]const u8{ "--git", "HEAD~1", "HEAD", "Foo.prefab", "--json" };
    const opt = try parseArgs(&args);
    try testing.expect(opt.git_mode);
    try testing.expectEqualStrings("HEAD~1", opt.git_ref_before);
    try testing.expectEqualStrings("HEAD", opt.git_ref_after);
    try testing.expectEqualStrings("Foo.prefab", opt.git_path);
    try testing.expectEqual(Format.json, opt.format);
}

test "parseArgs: extra positional after --git operands is a parse error" {
    const args = [_][]const u8{ "--git", "HEAD~1", "HEAD", "Foo.prefab", "Extra.prefab" };
    try testing.expectError(ArgError.TooManyArguments, parseArgs(&args));
}

test "parseArgs: --git with two operands means ref vs working tree" {
    const args = [_][]const u8{ "--git", "HEAD", "Foo.prefab", "--json" };
    const opt = try parseArgs(&args);
    try testing.expect(opt.git_mode);
    try testing.expectEqualStrings("HEAD", opt.git_ref_before);
    try testing.expectEqualStrings("", opt.git_ref_after); // empty = working-tree side
    try testing.expectEqualStrings("Foo.prefab", opt.git_path);
    try testing.expectEqual(Format.json, opt.format);
}

test "parseArgs: --git with a single operand is missing operands" {
    const args = [_][]const u8{ "--git", "HEAD" };
    try testing.expectError(ArgError.MissingOperands, parseArgs(&args));
}

test "parseArgs: a third plain positional is too many arguments" {
    const args = [_][]const u8{ "a.prefab", "b.prefab", "c.prefab" };
    try testing.expectError(ArgError.TooManyArguments, parseArgs(&args));
}

test "run: extra positional after --git operands exits 2, not silently accepted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Previously the early return on --git ignored everything past its 3
    // operands, so a stray trailing operand was silently dropped instead of
    // rejected. With the loop continuing, it must hit the same unknown-flag
    // arg-error contract as any other unrecognized positional.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--git", "HEAD~1", "HEAD", "Foo.prefab", "Extra.prefab" }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, err_output.items, "too many arguments") != null);
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
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", before_path, after_path }, &aw.writer, &aw_err.writer, false);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"schema\":\"prefablens.diff.v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"0.8\"") != null);
}

test "run: unreadable input file reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "/no/such/file.asset", "/no/such/other.asset" }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read file '/no/such/file.asset'\n", err_output.items);
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
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ hostile_path, other_path }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: input nested too deeply\n", err_output.items);
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
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
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
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    // No --json: the default tree format must honor the same error contract.
    const code = try run(testing.io, arena, &.{ "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
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
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--html", "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
}

test "run: --git with bad ref reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Whether the test cwd is a git repo (bad revision) or not (not a repo),
    // git show fails for a bogus ref -- both must surface as a clean error.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--git", "bogus-ref", "HEAD", "Foo.prefab" }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: git show failed for 'bogus-ref:Foo.prefab'\n", err_output.items);
}

test "run: no operands prints usage and exits 2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{}, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, err_output.items, "usage:") != null);
}

test "run: unknown flag prints error and exits 2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--bogus", "a.prefab", "b.prefab" }, &aw.writer, &aw_err.writer, false);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, err_output.items, "unknown flag") != null);
}

test "run: color=true colors tree output, --no-color forces it back off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    // color=true (the TTY-detected default) paints the tree output.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ before_path, after_path }, &aw.writer, &aw_err.writer, true);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);

    // --no-color forces it off even though color=true was passed in.
    var out2: std.ArrayList(u8) = .empty;
    var aw2 = std.Io.Writer.Allocating.fromArrayList(arena, &out2);
    var errbuf2: std.ArrayList(u8) = .empty;
    var aw_err2 = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf2);
    const code2 = try run(testing.io, arena, &.{ "--no-color", before_path, after_path }, &aw2.writer, &aw_err2.writer, true);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "\x1b[") == null);
}

test "run: --project supplies source prefabs for merged instance diffs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Cylinder.prefab", .data =
        \\--- !u!1 &10
        \\GameObject:
        \\  m_Name: Cyl
        \\  m_Component:
        \\  - component: {fileID: 40}
        \\--- !u!4 &40
        \\Transform:
        \\  m_GameObject: {fileID: 10}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Cylinder.prefab.meta", .data =
        \\fileFormatVersion: 2
        \\guid: 0123456789abcdef0123456789abcdef
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Variant.prefab", .data =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: 0123456789abcdef0123456789abcdef, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: 0123456789abcdef0123456789abcdef, type: 3}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.prefab", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const variant_path = try tmp.dir.realPathFileAlloc(testing.io, "Variant.prefab", arena);
    const empty_path = try tmp.dir.realPathFileAlloc(testing.io, "empty.prefab", arena);

    // With --project: supply the source for a merged display (Scale (1, 2, 1)).
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--no-color", "--project", dir, empty_path, variant_path }, &aw.writer, &aw_err.writer, false);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "Scale: (1, 2, 1)") != null);

    // Without --project: stays a degraded display (enumeration of recorded overrides).
    var out2: std.ArrayList(u8) = .empty;
    var aw2 = std.Io.Writer.Allocating.fromArrayList(arena, &out2);
    var errbuf2: std.ArrayList(u8) = .empty;
    var aw_err2 = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf2);
    const code2 = try run(testing.io, arena, &.{ "--no-color", empty_path, variant_path }, &aw2.writer, &aw_err2.writer, false);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "Scale.y: 2") != null);
}

/// Lockstep with the release tag v<version>. The single source is build.zig.zon (release.yml bumps it).
pub const version = @import("build_options").version;

test "run: --project points git mode at a repo outside the cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Create a real git repository outside the cwd. If --project points at that repo,
    // git show succeeds (with the cwd fixed at "." it would fail).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const gitc = struct {
        fn call(io: std.Io, a: std.mem.Allocator, d: []const u8, argv: []const []const u8) !void {
            var full: std.ArrayList([]const u8) = .empty;
            try full.append(a, "git");
            try full.appendSlice(a, argv);
            const r = try std.process.run(a, io, .{ .argv = full.items, .cwd = .{ .path = d } });
            if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
        }
    }.call;
    try gitc(testing.io, arena, dir, &.{ "init", "-q" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try gitc(testing.io, arena, dir, &.{ "add", "Foo.asset" });
    try gitc(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--project", dir, "--git", "HEAD", "Foo.asset" }, &aw.writer, &aw_err.writer, false);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"2\"") != null);
}

pub const Format = enum { tree, json, html };

pub const Options = struct {
    before: []const u8,
    after: []const u8,
    format: Format = .tree,
    project_root: ?[]const u8 = null, // for .meta resolution
    git_mode: bool = false,
    git_ref_before: []const u8 = "",
    git_ref_after: []const u8 = "",
    git_path: []const u8 = "",
    no_color: bool = false,
};

pub const ArgError = error{ MissingOperands, UnknownFlag, TooManyArguments };

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var format: Format = .tree;
    var project_root: ?[]const u8 = null;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;
    var git_mode = false;
    var git_ref_before: []const u8 = "";
    var git_ref_after: []const u8 = "";
    var git_path: []const u8 = "";
    var no_color = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, a, "--html")) {
            format = .html;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return ArgError.MissingOperands;
            project_root = args[i];
        } else if (std.mem.eql(u8, a, "--git")) {
            // --git <beforeRef> [<afterRef>] <path>: consumes 2-3 non-flag operands;
            // with 2, the after side is the working tree (git_ref_after = ""). Trailing flags are still parsed.
            var ops: [3][]const u8 = undefined;
            var n: usize = 0;
            while (n < 3 and i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) : (n += 1) {
                i += 1;
                ops[n] = args[i];
            }
            if (n < 2) return ArgError.MissingOperands;
            git_mode = true;
            git_ref_before = ops[0];
            git_ref_after = if (n == 3) ops[1] else "";
            git_path = ops[n - 1];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return ArgError.UnknownFlag;
        } else if (git_mode) {
            // --git already consumed its three operands; a bare positional
            // afterward is an extra operand, not an unrecognized flag.
            return ArgError.TooManyArguments;
        } else {
            if (pos_count >= 2) return ArgError.TooManyArguments;
            positionals[pos_count] = a;
            pos_count += 1;
        }
    }
    if (git_mode) {
        return .{
            .before = "",
            .after = "",
            .format = format,
            .project_root = project_root,
            .git_mode = true,
            .git_ref_before = git_ref_before,
            .git_ref_after = git_ref_after,
            .git_path = git_path,
            .no_color = no_color,
        };
    }
    if (pos_count != 2) return ArgError.MissingOperands;
    return .{
        .before = positionals[0].?,
        .after = positionals[1].?,
        .format = format,
        .project_root = project_root,
        .no_color = no_color,
    };
}

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(input.max_input_bytes));
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, color: bool) !u8 {
    const opt = parseArgs(args) catch |err| {
        switch (err) {
            ArgError.MissingOperands => try stderr.writeAll("usage: prefablens [--json|--html] [--project DIR] [--no-color] (<before> <after> | --git <beforeRef> [<afterRef>] <path>)\n"),
            ArgError.UnknownFlag => try stderr.writeAll("error: unknown flag\n"),
            ArgError.TooManyArguments => try stderr.writeAll("error: too many arguments\n"),
        }
        return 2;
    };

    // --project doubles as the guid-resolution base and the git repo dir (unset falls back to cwd as before).
    const repo_dir = opt.project_root orelse ".";
    const before = if (opt.git_mode)
        input.showAtRef(io, arena, repo_dir, opt.git_ref_before, opt.git_path, input.default_git_timeout) catch |err| {
            if (err == error.GitTimeout)
                try stderr.print("error: git timed out for '{s}:{s}'\n", .{ opt.git_ref_before, opt.git_path })
            else
                try stderr.print("error: git show failed for '{s}:{s}'\n", .{ opt.git_ref_before, opt.git_path });
            return 1;
        }
    else
        readFile(io, arena, opt.before) catch {
            try stderr.print("error: cannot read file '{s}'\n", .{opt.before});
            return 1;
        };
    const after = if (opt.git_mode and opt.git_ref_after.len == 0)
        // one ref = comparison against the working tree (a missing file is deletion = empty side)
        input.readWorktree(io, arena, repo_dir, opt.git_path) catch {
            try stderr.print("error: cannot read file '{s}'\n", .{opt.git_path});
            return 1;
        }
    else if (opt.git_mode)
        input.showAtRef(io, arena, repo_dir, opt.git_ref_after, opt.git_path, input.default_git_timeout) catch |err| {
            if (err == error.GitTimeout)
                try stderr.print("error: git timed out for '{s}:{s}'\n", .{ opt.git_ref_after, opt.git_path })
            else
                try stderr.print("error: git show failed for '{s}:{s}'\n", .{ opt.git_ref_after, opt.git_path });
            return 1;
        }
    else
        readFile(io, arena, opt.after) catch {
            try stderr.print("error: cannot read file '{s}'\n", .{opt.after});
            return 1;
        };

    var assets: core.Assets = .empty;
    var res = core.diffBytesWithAssets(arena, before, after, &assets) catch |err| {
        if (err == error.NestingTooDeep) {
            try stderr.writeAll("error: input nested too deeply\n");
            return 1;
        }
        return err;
    };
    var resolver_ptr: ?*const core.json.Resolver = null;
    var idx: core.json.Resolver = undefined;
    if (opt.project_root) |proj| {
        idx = resolve.buildIndex(io, arena, proj) catch {
            try stderr.print("error: cannot read project directory '{s}'\n", .{proj});
            return 1;
        };
        resolver_ptr = &idx;
        // Satisfy needed_sources with local assets and re-diff (nested sources raise new
        // requests, so up to 3 rounds; stop if there's no progress). Unreadable assets are
        // skipped without failing the diff.
        var rounds: usize = 0;
        while (res.needed_sources.len != 0 and rounds < 3) : (rounds += 1) {
            var progressed = false;
            for (res.needed_sources) |ns| {
                if (assets.contains(ns.guid)) continue;
                const path = idx.get(ns.guid) orelse continue;
                const bytes = readFile(io, arena, path) catch continue;
                try assets.put(arena, ns.guid, bytes);
                progressed = true;
            }
            if (!progressed) break;
            res = try core.diffBytesWithAssets(arena, before, after, &assets);
        }
    }
    switch (opt.format) {
        .json => {
            const out = try core.json.serialize(arena, res, resolver_ptr);
            try stdout.writeAll(out);
            try stdout.writeByte('\n');
        },
        // Color when stdout is a TTY is decided in main(); --no-color forces it off.
        .tree => try render_tree.render(stdout, res, resolver_ptr, color and !opt.no_color),
        .html => try render_html.render(stdout, res, resolver_ptr),
    }
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const user_args = if (args.len > 1) args[1..] else args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (user_args.len >= 1 and std.mem.eql(u8, user_args[0], "mcp")) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
        // Client disconnect (broken pipe, etc.) is normal. Exit quietly without emitting a stack trace.
        mcp.serve(init.io, std.heap.page_allocator, &stdin_reader.interface, stdout) catch {
            stdout.flush() catch {};
            return 1;
        };
        stdout.flush() catch {};
        return 0;
    }

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const color = std.Io.File.stdout().isTty(init.io) catch false;

    const code = try run(init.io, arena, user_args, stdout, stderr, color);
    try stdout.flush();
    try stderr.flush();
    return code;
}
