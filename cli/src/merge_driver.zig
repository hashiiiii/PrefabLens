const std = @import("std");
const core = @import("core");
const atomic_file = @import("atomic_file.zig");
const command = @import("command.zig");
const merge_io = @import("merge_io.zig");
const testing = std.testing;

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergeDriverArgs,
    stderr: *std.Io.Writer,
) !u8 {
    const original = merge_io.readLimited(io, arena, args.ours_output) catch
        return merge_io.reportFailure(stderr, args.path);
    const base = merge_io.readLimited(io, arena, args.base) catch
        return merge_io.reportFailure(stderr, args.path);
    const theirs = merge_io.readLimited(io, arena, args.theirs) catch
        return merge_io.reportFailure(stderr, args.path);
    if ((base.len != 0 and !core.isUnityYaml(base)) or
        (original.len != 0 and !core.isUnityYaml(original)) or
        (theirs.len != 0 and !core.isUnityYaml(theirs)))
        return merge_io.reportFailure(stderr, args.path);
    const built = core.merge.build(arena, base, original, theirs) catch
        return merge_io.reportFailure(stderr, args.path);
    atomic_file.replace(io, arena, args.ours_output, original, built.partial) catch
        return merge_io.reportFailure(stderr, args.path);
    return if (built.plan.unresolvedCount() == 0) 0 else 1;
}

fn runDriverCase(
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    expected: []const u8,
    expected_code: u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "base.prefab", .data = base });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ours.prefab", .data = ours });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theirs.prefab", .data = theirs });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const args: command.MergeDriverArgs = .{
        .base = try std.fs.path.join(arena, &.{ root, "base.prefab" }),
        .ours_output = try std.fs.path.join(arena, &.{ root, "ours.prefab" }),
        .theirs = try std.fs.path.join(arena, &.{ root, "theirs.prefab" }),
        .path = "Assets/A.prefab",
    };

    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);
    const code = try run(testing.io, arena, args, &stderr.writer);
    const output = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        args.ours_output,
        arena,
        .limited(merge_io.max_input_bytes),
    );
    try testing.expectEqual(expected_code, code);
    try testing.expectEqualStrings(expected, output);
    try testing.expectEqualStrings(
        if (expected_code == 2)
            "prefablens: Merge failed for Assets/A.prefab. PrefabLens did not write the output.\n"
        else
            "",
        stderr.toArrayList().items,
    );
}

fn fixturePath(arena: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    const fixture_root = @import("test_options").fixture_root;
    return std.fs.path.join(arena, &.{ fixture_root, sub_path });
}

fn readFixture(arena: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return merge_io.readLimited(testing.io, arena, try fixturePath(arena, sub_path));
}

test "merge driver: fixture root does not depend on the process cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Test runners can start outside this checkout, so ambient cwd must never select fixture bytes.
    const path = try fixturePath(arena, "component-add/base.prefab");
    try testing.expect(std.fs.path.isAbsolute(path));
    try testing.expect(core.isUnityYaml(try merge_io.readLimited(testing.io, arena, path)));
}

test "merge driver: writes automatic and partial results with exact exit codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try runDriverCase(
        try readFixture(arena, "component-add/base.prefab"),
        try readFixture(arena, "component-add/ours.prefab"),
        try readFixture(arena, "component-add/theirs.prefab"),
        try readFixture(arena, "component-add/expected.prefab"),
        0,
    );
    try runDriverCase(
        try readFixture(arena, "component-delete-edit/base.prefab"),
        try readFixture(arena, "component-delete-edit/ours.prefab"),
        try readFixture(arena, "component-delete-edit/theirs.prefab"),
        try readFixture(arena, "component-delete-edit/partial.prefab"),
        1,
    );
}

test "merge driver: keeps ours unchanged for malformed or unsupported input" {
    const valid = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    // A misleading extension must not let non-Unity content reach the merge engine.
    try runDriverCase("not Unity YAML\n", valid, valid, valid, 2);

    // Unknown changed sequences have no safe identity, so even their independent bytes cannot be guessed.
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 3\n";
    try runDriverCase(base, ours, base, ours, 2);
}

test "merge driver: keeps ours unchanged when an input cannot be read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ours.prefab", .data = ours });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theirs.prefab", .data = ours });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const ours_path = try std.fs.path.join(arena, &.{ root, "ours.prefab" });
    const args: command.MergeDriverArgs = .{
        .base = try std.fs.path.join(arena, &.{ root, "missing.prefab" }),
        .ours_output = ours_path,
        .theirs = try std.fs.path.join(arena, &.{ root, "theirs.prefab" }),
        .path = "Assets/A.prefab",
    };
    var stderr_bytes: std.ArrayList(u8) = .empty;
    var stderr = std.Io.Writer.Allocating.fromArrayList(arena, &stderr_bytes);

    try testing.expectEqual(@as(u8, 2), try run(testing.io, arena, args, &stderr.writer));
    try testing.expectEqualStrings(
        ours,
        try std.Io.Dir.cwd().readFileAlloc(testing.io, ours_path, arena, .limited(merge_io.max_input_bytes)),
    );
    try testing.expectEqualStrings(
        "prefablens: Merge failed for Assets/A.prefab. PrefabLens did not write the output.\n",
        stderr.toArrayList().items,
    );
}
