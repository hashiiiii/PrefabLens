const std = @import("std");
const core = @import("core");
const testing = std.testing;

const command = @import("command.zig");
const input = @import("input.zig");
const render_tree = @import("render_tree.zig");

pub const usage = "prefablens diff-driver <path> <old-file> <old-hex> <old-mode> <new-file> <new-hex> <new-mode> [<old-path> <xfrm-msg>]";

pub const help = usage ++
    \\
    \\
    \\Render a semantic diff from Git's external diff arguments.
    \\Git appends seven operands for a changed path, or nine for a rename.
    \\An unmerged path arrives as the repository path alone and is skipped.
    \\/dev/null means that side is absent.
    \\
;

const Side = struct {
    bytes: []const u8,
    present: bool,
};

fn isAbsent(path: []const u8) bool {
    return path.len == 0 or
        std.mem.eql(u8, path, "/dev/null") or
        std.ascii.eqlIgnoreCase(path, "nul");
}

fn readSide(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Side {
    if (isAbsent(path)) return .{ .bytes = "", .present = false };
    return .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(input.max_input_bytes)),
        .present = true,
    };
}

fn noColorRequested(environ: ?*const std.process.Environ.Map) bool {
    const env = environ orelse return false;
    const value = env.get("NO_COLOR") orelse return false;
    return value.len != 0;
}

fn reportSkip(stderr: *std.Io.Writer, path: []const u8, reason: []const u8) !u8 {
    try stderr.print("prefablens: Skipping '{s}': {s}.\n", .{ path, reason });
    // Non-zero status aborts the rest of `git diff`.
    return 0;
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.DiffDriverArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ: ?*const std.process.Environ.Map,
) !u8 {
    switch (args) {
        .help => {
            try stdout.writeAll(help);
            return 0;
        },
        .skip => return 0,
        .compare => |compare| return renderCompare(io, arena, compare, stdout, stderr, environ),
    }
}

fn renderCompare(
    io: std.Io,
    arena: std.mem.Allocator,
    compare: command.DiffDriverCompare,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ: ?*const std.process.Environ.Map,
) !u8 {
    const before = readSide(io, arena, compare.old_file) catch
        return reportSkip(stderr, compare.path, "cannot read the old file");
    const after = readSide(io, arena, compare.new_file) catch
        return reportSkip(stderr, compare.path, "cannot read the new file");
    if (!before.present and !after.present)
        return reportSkip(stderr, compare.path, "both sides are absent");
    if (before.present and !core.isUnityYaml(before.bytes))
        return reportSkip(stderr, compare.path, "the old file is not Unity YAML");
    if (after.present and !core.isUnityYaml(after.bytes))
        return reportSkip(stderr, compare.path, "the new file is not Unity YAML");

    const result = core.diffBytes(arena, before.bytes, after.bytes) catch
        return reportSkip(stderr, compare.path, "cannot parse Unity YAML");
    try stdout.print("{s}\n", .{compare.path});
    if (result.roots.len == 0 and result.loose.len == 0) {
        try stdout.writeAll("No semantic changes\n");
        return 0;
    }
    const color = !noColorRequested(environ);
    try render_tree.render(arena, stdout, result, null, color);
    return 0;
}

const Invocation = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn invoke(
    arena: std.mem.Allocator,
    args: command.DiffDriverArgs,
    environ: ?*const std.process.Environ.Map,
) !Invocation {
    var out: std.ArrayList(u8) = .empty;
    var out_writer = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err: std.ArrayList(u8) = .empty;
    var err_writer = std.Io.Writer.Allocating.fromArrayList(arena, &err);
    const code = try run(testing.io, arena, args, &out_writer.writer, &err_writer.writer, environ);
    return .{
        .code = code,
        .stdout = out_writer.toArrayList().items,
        .stderr = err_writer.toArrayList().items,
    };
}

fn writeFixturePair(tmp: *testing.TmpDir, arena: std.mem.Allocator) !struct { before: []const u8, after: []const u8 } {
    const before_fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/src/testdata/cylinder_before.prefab", arena, .limited(1024 * 1024));
    const after_fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/src/testdata/cylinder_after.prefab", arena, .limited(1024 * 1024));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old", .data = before_fixture });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new", .data = after_fixture });
    return .{
        .before = try tmp.dir.realPathFileAlloc(testing.io, "old", arena),
        .after = try tmp.dir.realPathFileAlloc(testing.io, "new", arena),
    };
}

fn compareArgs(path: []const u8, old_file: []const u8, new_file: []const u8) command.DiffDriverArgs {
    return .{ .compare = .{ .path = path, .old_file = old_file, .new_file = new_file } };
}

test "diff-driver: renders git's seven operands from the cylinder fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    var env = std.process.Environ.Map.init(arena);
    try env.put("NO_COLOR", "1");
    const result = try invoke(arena, compareArgs("Assets/Cylinder.prefab", paths.before, paths.after), &env);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "Assets/Cylinder.prefab\n"));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Position.x: 0.64596 → 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[") == null);
}

test "diff-driver: treats /dev/null as an added or deleted side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    var env = std.process.Environ.Map.init(arena);
    try env.put("NO_COLOR", "1");
    const added = try invoke(arena, compareArgs("Assets/Added.prefab", "/dev/null", paths.after), &env);
    try testing.expectEqual(@as(u8, 0), added.code);
    try testing.expect(std.mem.indexOf(u8, added.stdout, "Cylinder") != null);

    const deleted = try invoke(arena, compareArgs("Assets/Removed.prefab", paths.before, "/dev/null"), &env);
    try testing.expectEqual(@as(u8, 0), deleted.code);
    try testing.expect(std.mem.startsWith(u8, deleted.stdout, "Assets/Removed.prefab\n"));
}

test "diff-driver: skips unmerged paths and non-Unity input without failing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.cs", .data = "class A {}\n" });
    const cs = try tmp.dir.realPathFileAlloc(testing.io, "notes.cs", arena);

    const skipped = try invoke(arena, .skip, null);
    try testing.expectEqual(@as(u8, 0), skipped.code);
    try testing.expectEqualStrings("", skipped.stdout);

    const unsupported = try invoke(arena, compareArgs("Assets/Notes.cs", cs, cs), null);
    try testing.expectEqual(@as(u8, 0), unsupported.code);
    try testing.expectEqualStrings("", unsupported.stdout);
    try testing.expect(unsupported.stderr.len != 0);
}

test "diff-driver: colors through a pipe unless NO_COLOR is set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try writeFixturePair(&tmp, arena);

    const colored = try invoke(arena, compareArgs("Assets/Cylinder.prefab", paths.before, paths.after), null);
    try testing.expectEqual(@as(u8, 0), colored.code);
    try testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[") != null);

    const help_text = try invoke(arena, .help, null);
    try testing.expectEqual(@as(u8, 0), help_text.code);
    try testing.expect(std.mem.indexOf(u8, help_text.stdout, "external diff") != null);
}
