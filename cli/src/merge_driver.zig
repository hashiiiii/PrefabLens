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

test "merge driver: preserves a leading BOM when theirs changes a direct-header field" {
    const base = "\xEF\xBB\xBF--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
    const ours = "\xEF\xBB\xBF--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
    const theirs = "\xEF\xBB\xBF--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";
    const expected = "\xEF\xBB\xBF--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";

    try runDriverCase(base, ours, theirs, expected, 0);
}

test "merge driver: keeps document headers in order" {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const theirs =
        "--- !u!21 &2\nMaterial:\n  m_Name: Added\n" ++
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
    const partial =
        "--- !u!21 &2\nMaterial:\n  m_Name: Added\n" ++
        base;

    try runDriverCase(base, "", theirs, partial, 1);
}

test "merge driver: covers standalone documents and source-only changes" {
    const base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 1\n";
    const ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 2\n";
    const theirs = base ++
        "--- !u!21 &2\n" ++
        "Material:\n" ++
        "  m_Name: Added\n";
    const expected = ours ++
        "--- !u!21 &2\n" ++
        "Material:\n" ++
        "  m_Name: Added\n";

    // A document outside a GameObject bundle must not disappear from a clean merge.
    try runDriverCase(base, ours, theirs, expected, 0);
    try runDriverCase(base, theirs, ours, expected, 0);

    const stripped =
        "--- !u!114 &1 stripped\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 1\n";
    const stripped_expected =
        "--- !u!114 &1 stripped\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 2\n";
    // A header-only Theirs change must merge with an independent Ours field change.
    try runDriverCase(base, ours, stripped, stripped_expected, 0);

    const comment_base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Base comment.\n" ++
        "  m_Value: 1\n";
    const comment_ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Base comment.\n" ++
        "  m_Value: 2\n";
    const comment_theirs =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Theirs comment.\n" ++
        "  m_Value: 1\n";
    // An unmodeled source-only change must stop before the driver writes output.
    try runDriverCase(comment_base, comment_ours, comment_theirs, comment_ours, 2);
}

test "merge driver: rejects a document deletion that drops ours source bytes" {
    const base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Base comment.\n" ++
        "  m_Value: 1\n";
    const ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Ours comment.\n" ++
        "  m_Value: 1\n";

    // Semantic equality does not make different Ours document bytes safe to delete.
    try runDriverCase(base, ours, "", ours, 2);
}

test "merge driver: keeps ours source bytes for equal document additions" {
    const ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Ours comment.\n" ++
        "  m_Value: 1\n";
    const theirs =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  # Theirs comment.\n" ++
        "  m_Value: 1\n";

    // The common decision selects Ours, so it does not discard Ours document bytes.
    try runDriverCase("", ours, theirs, ours, 0);
}

test "merge driver: rejects sequence comments" {
    const sequence_base =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "  # Base comment.\n" ++
        "  - component: {fileID: 54}\n" ++
        "  m_Name: Base\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Children: []\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 1\n";
    const sequence_ours =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "  # Base comment.\n" ++
        "  - component: {fileID: 54}\n" ++
        "  m_Name: Ours\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Children: []\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 1\n";
    const sequence_theirs =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "  # Theirs comment.\n" ++
        "  - component: {fileID: 54}\n" ++
        "  m_Name: Base\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Children: []\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 1\n";
    // Known item identities do not make an unplanned comment safe.
    try runDriverCase(sequence_base, sequence_ours, sequence_theirs, sequence_ours, 2);
}

test "merge driver: rejects map source order" {
    const map_base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 1\n" ++
        "  m_Left: left\n" ++
        "  m_Right: right\n";
    const map_ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 2\n" ++
        "  m_Left: left\n" ++
        "  m_Right: right\n";
    const map_theirs =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Right: right\n" ++
        "  m_Left: left\n" ++
        "  m_Value: 1\n";
    // Semantic map equality does not preserve source order.
    try runDriverCase(map_base, map_ours, map_theirs, map_ours, 2);
}

test "merge driver: rejects line ending changes" {
    const base_lf = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
    const ours_lf = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
    const theirs_crlf = "--- !u!114 &1\r\nMonoBehaviour:\r\n  m_Left: 1\r\n  m_Right: 1\r\n";
    // Parsed equality does not preserve line endings.
    try runDriverCase(base_lf, ours_lf, theirs_crlf, ours_lf, 2);
}

test "merge driver: preserves a commented document" {
    const base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 1\n";
    const ours =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Value: 2\n";
    const theirs_commented_document = base ++
        "--- !u!21 &2\n" ++
        "Material:\n" ++
        "  # Keep this comment.\n" ++
        "  m_Name: Added\n";
    const expected_commented_document = ours ++
        "--- !u!21 &2\n" ++
        "Material:\n" ++
        "  # Keep this comment.\n" ++
        "  m_Name: Added\n";
    // A whole-document operation carries its comment bytes.
    try runDriverCase(base, ours, theirs_commented_document, expected_commented_document, 0);
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

test "merge driver: rejects malformed Unity document structure without writing" {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n";
    const malformed = [_][]const u8{
        "--- !u!114 &1\nMonoBehaviour:\n  - rogue\n",
        "--- !u!114 &1\n",
        "rogue: value\n--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n  m_Value: duplicate\n",
    };
    for (malformed) |ours| {
        try runDriverCase(base, ours, theirs, ours, 2);
    }
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
