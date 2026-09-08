const std = @import("std");
const core = @import("core");
const testing = std.testing;

const input = @import("input.zig");
const render_tree = @import("render_tree.zig");
const unity_path = @import("unity_path.zig");

pub const usage = "prefablens render-diff [--color|--no-color] [--] BEFORE AFTER DISPLAY_PATH";

pub const help = usage ++ "\n\nRender a semantic diff from two literal file paths.\nEmpty paths and /dev/null mean that side is absent.\n";

const Args = struct {
    before: []const u8,
    after: []const u8,
    display_path: []const u8,
    force_color: bool = false,
    no_color: bool = false,
};

const ArgError = error{InvalidArguments};

fn parseArgs(args: []const []const u8) ArgError!Args {
    var operands: [3][]const u8 = undefined;
    var operand_count: usize = 0;
    var force_color = false;
    var no_color = false;
    var parse_options = true;
    for (args) |arg| {
        if (parse_options and std.mem.eql(u8, arg, "--")) {
            parse_options = false;
        } else if (parse_options and std.mem.eql(u8, arg, "--color")) {
            force_color = true;
        } else if (parse_options and std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (parse_options and std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidArguments;
        } else {
            if (operand_count == operands.len) return error.InvalidArguments;
            operands[operand_count] = arg;
            operand_count += 1;
        }
    }
    if (operand_count != operands.len) return error.InvalidArguments;
    return .{
        .before = operands[0],
        .after = operands[1],
        .display_path = operands[2],
        .force_color = force_color,
        .no_color = no_color,
    };
}

test "render-diff option sentinel preserves dash-prefixed literal operands" {
    const parsed = try parseArgs(&.{ "--color", "--", "--before", "--after", "--display.prefab" });
    try testing.expect(parsed.force_color);
    try testing.expectEqualStrings("--before", parsed.before);
    try testing.expectEqualStrings("--after", parsed.after);
    try testing.expectEqualStrings("--display.prefab", parsed.display_path);
}

const Side = struct {
    bytes: []const u8,
    present: bool,
    argument: []const u8,
};

fn isAbsent(path: []const u8) bool {
    return path.len == 0 or std.mem.eql(u8, path, "/dev/null");
}

fn readSide(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Side {
    if (isAbsent(path)) return .{ .bytes = "", .present = false, .argument = path };
    return .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(input.max_input_bytes)),
        .present = true,
        .argument = path,
    };
}

fn noColorRequested(environ: ?*const std.process.Environ.Map) bool {
    const env = environ orelse return false;
    const value = env.get("NO_COLOR") orelse return false;
    return value.len != 0;
}

fn hasUnityDocumentHeader(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (first and std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];
        first = false;
        if (std.mem.startsWith(u8, line, "--- !u!")) return true;
    }
    return false;
}

fn validateSide(arena: std.mem.Allocator, side: Side, stderr: *std.Io.Writer) !?u8 {
    if (!side.present) return null;
    if (!core.isUnityYaml(side.bytes)) {
        try stderr.print("prefablens: Renderer input '{s}' is not Unity YAML.\n", .{side.argument});
        return 3;
    }
    if (!hasUnityDocumentHeader(side.bytes)) {
        try stderr.print("prefablens: Renderer input has no Unity document header ('{s}').\n", .{side.argument});
        return 3;
    }
    const found = core.parseDiagnostics(arena, side.bytes) catch |err| {
        if (err == error.NestingTooDeep) {
            try stderr.print("prefablens: Cannot parse renderer input: input nested too deeply ('{s}').\n", .{side.argument});
            return 2;
        }
        return err;
    };
    if (found.len != 0) {
        try stderr.print("prefablens: Cannot parse renderer input: {s} ('{s}').\n", .{ @tagName(found[0]), side.argument });
        return 2;
    }
    return null;
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    tty_color: bool,
    environ: ?*const std.process.Environ.Map,
) !u8 {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        try stdout.writeAll(help);
        return 0;
    }
    const parsed = parseArgs(args) catch {
        try stderr.writeAll("usage: " ++ usage ++ "\n");
        return 2;
    };
    if (!unity_path.isUnityPath(parsed.display_path)) {
        try stderr.print("prefablens: Unsupported renderer path '{s}'.\n", .{parsed.display_path});
        return 3;
    }

    const before = readSide(io, arena, parsed.before) catch {
        try stderr.print("prefablens: Cannot read renderer input '{s}'.\n", .{parsed.before});
        return 2;
    };
    const after = readSide(io, arena, parsed.after) catch {
        try stderr.print("prefablens: Cannot read renderer input '{s}'.\n", .{parsed.after});
        return 2;
    };
    if (!before.present and !after.present) {
        try stderr.writeAll("prefablens: Renderer inputs do not contain Unity YAML.\n");
        return 3;
    }
    if (try validateSide(arena, before, stderr)) |code| return code;
    if (try validateSide(arena, after, stderr)) |code| return code;

    const result = core.diffBytes(arena, before.bytes, after.bytes) catch |err| {
        if (err == error.NestingTooDeep) {
            try stderr.writeAll("prefablens: Cannot parse renderer input: input nested too deeply.\n");
            return 2;
        }
        return err;
    };
    if (result.roots.len == 0 and result.loose.len == 0) {
        try stdout.writeAll("No semantic changes\n");
        return 0;
    }
    const use_color = (tty_color or parsed.force_color) and !parsed.no_color and !noColorRequested(environ);
    try render_tree.renderWithOptions(arena, stdout, result, null, .{
        .color = use_color,
        .project_hint = false,
    });
    return 0;
}

const Invocation = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn invoke(
    arena: std.mem.Allocator,
    args: []const []const u8,
    tty_color: bool,
    environ: ?*const std.process.Environ.Map,
) !Invocation {
    var out: std.ArrayList(u8) = .empty;
    var out_writer = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err: std.ArrayList(u8) = .empty;
    var err_writer = std.Io.Writer.Allocating.fromArrayList(arena, &err);
    const code = try run(testing.io, arena, args, &out_writer.writer, &err_writer.writer, tty_color, environ);
    return .{
        .code = code,
        .stdout = out_writer.toArrayList().items,
        .stderr = err_writer.toArrayList().items,
    };
}

fn writeFixturePair(tmp: *testing.TmpDir, arena: std.mem.Allocator) !struct { before: []const u8, after: []const u8 } {
    const before_fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/src/testdata/cylinder_before.prefab", arena, .limited(1024 * 1024));
    const after_fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/src/testdata/cylinder_after.prefab", arena, .limited(1024 * 1024));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before literal $(echo wrong)", .data = before_fixture });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after 空 白", .data = after_fixture });
    return .{
        .before = try tmp.dir.realPathFileAlloc(testing.io, "before literal $(echo wrong)", arena),
        .after = try tmp.dir.realPathFileAlloc(testing.io, "after 空 白", arena),
    };
}

test "render-diff reads literal paths and renders the actual Unity fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    const result = try invoke(arena, &.{ paths.before, paths.after, "Assets/Cylinder.prefab" }, false, null);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Position.x: 0.64596 → 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "(1 unresolved guid reference(s))") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "--project") == null);
}

test "render-diff treats only empty arguments and dev-null as absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    const empty_arg = try invoke(arena, &.{ "", paths.after, "Assets/Cylinder.prefab" }, false, null);
    try testing.expectEqual(@as(u8, 0), empty_arg.code);
    try testing.expect(std.mem.indexOf(u8, empty_arg.stdout, "Cylinder") != null);

    const dev_null = try invoke(arena, &.{ paths.before, "/dev/null", "Assets/Cylinder.prefab" }, false, null);
    try testing.expectEqual(@as(u8, 0), dev_null.code);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty one", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty two", .data = "" });
    const empty_one = try tmp.dir.realPathFileAlloc(testing.io, "empty one", arena);
    const empty_two = try tmp.dir.realPathFileAlloc(testing.io, "empty two", arena);
    const existing_empty = try invoke(arena, &.{ empty_one, empty_two, "Assets/Empty.asset" }, false, null);
    try testing.expectEqual(@as(u8, 3), existing_empty.code);
    try testing.expectEqualStrings("", existing_empty.stdout);
    try testing.expect(existing_empty.stderr.len != 0);
}

test "render-diff returns separate unsupported and input failure exits without stdout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    const unsupported = try invoke(arena, &.{ paths.before, paths.after, "Assets/Cylinder.cs" }, false, null);
    try testing.expectEqual(@as(u8, 3), unsupported.code);
    try testing.expectEqualStrings("", unsupported.stdout);
    try testing.expect(unsupported.stderr.len != 0);

    const missing_path = try std.fs.path.join(arena, &.{ paths.before, "missing" });
    const missing = try invoke(arena, &.{ missing_path, paths.after, "Assets/Cylinder.prefab" }, false, null);
    try testing.expectEqual(@as(u8, 2), missing.code);
    try testing.expectEqualStrings("", missing.stdout);
    try testing.expect(missing.stderr.len != 0);
}

test "render-diff rejects malformed Unity YAML before writing stdout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "malformed", .data = "--- !u!114 &1\nMonoBehaviour:\n  values: [1, 2\n" });
    const malformed_path = try tmp.dir.realPathFileAlloc(testing.io, "malformed", arena);

    const result = try invoke(arena, &.{ paths.before, malformed_path, "Assets/Cylinder.prefab" }, false, null);

    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.startsWith(u8, result.stderr, "prefablens: Cannot parse renderer input: invalid_flow_value"));
    try testing.expect(std.mem.indexOf(u8, result.stderr, malformed_path) != null);
}

test "render-diff rejects a directive-only real file as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "only directive",
        .data = "%TAG !u! tag:unity3d.com,2011:\n",
    });
    const directive_path = try tmp.dir.realPathFileAlloc(testing.io, "only directive", arena);

    const result = try invoke(arena, &.{ "/dev/null", directive_path, "Assets/OnlyDirective.asset" }, false, null);

    try testing.expectEqual(@as(u8, 3), result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "document header") != null);
}

test "render-diff reports a successful empty semantic result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const before_fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/src/testdata/cylinder_before.prefab", arena, .limited(1024 * 1024));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before", .data = before_fixture });
    const after = try std.fmt.allocPrint(arena, "{s}# Only a comment changed.\n", .{before_fixture});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after", .data = after });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after", arena);

    const result = try invoke(arena, &.{ before_path, after_path, "Assets/Cylinder.prefab" }, false, null);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings("No semantic changes\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "render-diff no-color settings override forced and terminal color" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    const forced_color = try invoke(arena, &.{ "--color", paths.before, paths.after, "Assets/Cylinder.prefab" }, false, null);
    try testing.expectEqual(@as(u8, 0), forced_color.code);
    try testing.expect(std.mem.indexOf(u8, forced_color.stdout, "\x1b[") != null);

    var env = std.process.Environ.Map.init(arena);
    try env.put("NO_COLOR", "1");
    const no_color_env = try invoke(arena, &.{ "--color", paths.before, paths.after, "Assets/Cylinder.prefab" }, false, &env);
    try testing.expectEqual(@as(u8, 0), no_color_env.code);
    try testing.expect(std.mem.indexOf(u8, no_color_env.stdout, "\x1b[") == null);

    const no_color_flag = try invoke(arena, &.{ "--color", "--no-color", paths.before, paths.after, "Assets/Cylinder.prefab" }, true, null);
    try testing.expectEqual(@as(u8, 0), no_color_flag.code);
    try testing.expect(std.mem.indexOf(u8, no_color_flag.stdout, "\x1b[") == null);
}

test "render-diff rejects invalid arguments without stdout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const missing = try invoke(arena, &.{ "before", "after" }, false, null);
    try testing.expectEqual(@as(u8, 2), missing.code);
    try testing.expectEqualStrings("", missing.stdout);
    try testing.expect(missing.stderr.len != 0);

    const unknown = try invoke(arena, &.{ "--json", "before", "after", "Assets/Foo.prefab" }, false, null);
    try testing.expectEqual(@as(u8, 2), unknown.code);
    try testing.expectEqualStrings("", unknown.stdout);
    try testing.expect(unknown.stderr.len != 0);
}
