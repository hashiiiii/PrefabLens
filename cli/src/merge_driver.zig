const std = @import("std");
const core = @import("core");
const atomic_file = @import("atomic_file.zig");
const command = @import("command.zig");
const merge_io = @import("merge_io.zig");
const merge_fallback = @import("merge_fallback.zig");
const merge_git = @import("merge_git.zig");
const session_context = @import("merge_session_context.zig");
const revision = @import("merge_revision.zig");
const testing = std.testing;

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergeDriverArgs,
    stderr: *std.Io.Writer,
) !u8 {
    return runWithGit(io, arena, args, null, stderr);
}

pub fn runWithGit(
    io: std.Io,
    arena: std.mem.Allocator,
    args: command.MergeDriverArgs,
    git: ?merge_git.Git,
    stderr: *std.Io.Writer,
) !u8 {
    const original = merge_io.readLimited(io, arena, args.ours_output) catch
        return merge_io.reportFailure(stderr, args.path);
    const base = merge_io.readLimited(io, arena, args.base) catch
        return merge_io.reportFailure(stderr, args.path);
    const theirs = merge_io.readLimited(io, arena, args.theirs) catch
        return merge_io.reportFailure(stderr, args.path);
    const unity = !merge_fallback.isBinary(base) and
        !merge_fallback.isBinary(original) and
        !merge_fallback.isBinary(theirs) and
        (base.len == 0 or core.isUnityYaml(base)) and
        (original.len == 0 or core.isUnityYaml(original)) and
        (theirs.len == 0 or core.isUnityYaml(theirs));
    if (unity) {
        const context = if (git) |repository|
            inputContext(repository, args.path, .{ .base = base, .ours = original, .theirs = theirs }) catch |err| switch (err) {
                error.OutOfMemory => return merge_io.reportFailure(stderr, args.path),
                else => core.merge_context.Context{},
            }
        else
            core.merge_context.Context{};
        const built = core.merge.buildWithContext(arena, base, original, theirs, context) catch |err| switch (err) {
            error.OutOfMemory => return merge_io.reportFailure(stderr, args.path),
            else => null,
        };
        if (built) |valid| {
            if (valid.plan.unresolvedCount() == 0) {
                // Automatic acceptance needs the same final validation as an
                // interactive result, including its selected source context.
                const output = core.merge.finish(arena, &valid.plan) catch |err| switch (err) {
                    error.OutOfMemory => return merge_io.reportFailure(stderr, args.path),
                    else => null,
                };
                if (output) |bytes| {
                    atomic_file.replace(io, arena, args.ours_output, original, bytes) catch
                        return merge_io.reportFailure(stderr, args.path);
                    return 0;
                }
            }
        }
    }
    const fallback = merge_fallback.build(io, arena, args, base, original, theirs, unity) catch
        return merge_io.reportFailure(stderr, args.path);
    atomic_file.replace(io, arena, args.ours_output, original, fallback.bytes) catch
        return merge_io.reportFailure(stderr, args.path);
    return if (fallback.conflicted) 1 else 0;
}

fn inputContext(git: merge_git.Git, path: []const u8, inputs: session_context.Inputs) !core.merge_context.Context {
    const revisions = (try session_context.discover(git)) orelse return .{};
    var store = revision.Store.init(git);
    defer store.deinit();
    // A file driver runs before Git selects the candidate tree. The strategy
    // provides the immutable revisions needed for schema evidence.
    return (try session_context.bind(&store, revisions, .{ .base = path, .ours = path, .theirs = path }, inputs)) orelse .{};
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

test "merge driver: leaves conventional markers for a text conflict" {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n";
    try runDriverCase(base, ours, theirs, "--- !u!114 &1\nMonoBehaviour:\n<<<<<<< ours\n  m_Value: 2\n=======\n  m_Value: 3\n>>>>>>> theirs\n", 1);
}

test "merge driver: falls back to native merging for non-Unity text and binary" {
    try runDriverCase("base\n", "ours\n", "theirs\n", "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n", 1);
    try runDriverCase("first\nsecond\nthird\n", "ours\nsecond\nthird\n", "first\nsecond\ntheirs\n", "ours\nsecond\ntheirs\n", 0);
    try runDriverCase("base\x00\n", "ours\x00\n", "theirs\x00\n", "ours\x00\n", 1);
    try runDriverCase("base\x00\n", "base\x00\n", "theirs\x00\n", "theirs\x00\n", 0);
    const binary_base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n  m_Binary: a\x00b\n";
    const binary_ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n  m_Binary: a\x00b\n";
    const binary_theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n  m_Binary: a\x00b\n";
    try runDriverCase(binary_base, binary_ours, binary_theirs, binary_ours, 1);
}

test "merge driver: writes automatic results and marker fallback" {
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
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
            "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
            "<<<<<<< ours\n=======\n--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n>>>>>>> theirs\n",
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
    try runDriverCase(base, "", theirs, "<<<<<<< ours\n=======\n" ++ theirs ++ ">>>>>>> theirs\n", 1);
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
}

test "merge driver: unsupported structure writes conflict markers" {
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
    try runDriverCase(
        comment_base,
        comment_ours,
        comment_theirs,
        "--- !u!114 &1\n" ++
            "MonoBehaviour:\n" ++
            "<<<<<<< ours\n" ++
            "  # Base comment.\n" ++
            "  m_Value: 2\n" ++
            "=======\n" ++
            "  # Theirs comment.\n" ++
            "  m_Value: 1\n" ++
            ">>>>>>> theirs\n",
        1,
    );
}

test "merge driver: adds whole-file markers for a semantic-only sequence conflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = "--- !u!1001 &1\nPrefabInstance:\n  m_Modification:\n    m_Modifications:\n";
    const first = "    - target: {fileID: 1, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n      propertyPath: m_First\n      value: 1\n      objectReference: {fileID: 0}\n";
    const second = "    - target: {fileID: 1, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n      propertyPath: m_Second\n      value: 2\n      objectReference: {fileID: 0}\n";
    const added = "    - target: {fileID: 1, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n      propertyPath: m_Added\n      value: 3\n      objectReference: {fileID: 0}\n";
    const base = prefix ++ first ++ second;
    const ours = prefix ++ added ++ first ++ second;
    const theirs = prefix ++ first ++ second ++ added;
    const built = try core.merge.build(arena, base, ours, theirs);
    try testing.expect(built.plan.unresolvedCount() != 0);
    try runDriverCase(base, ours, theirs, "<<<<<<< ours\n" ++ ours ++ "=======\n" ++ theirs ++ ">>>>>>> theirs\n", 1);
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

    try runDriverCase(base, ours, "", "<<<<<<< ours\n" ++ ours ++ "=======\n>>>>>>> theirs\n", 1);
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

test "merge driver: merges ordered arrays and falls back for keyed shapes" {
    const valid = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    // A misleading extension must not let non-Unity content reach the merge engine.
    try runDriverCase("not Unity YAML\n", valid, valid, valid, 0);

    // A one-sided ordered edit has a proven result without field type metadata.
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 3\n";
    try runDriverCase(base, ours, base, ours, 0);

    // A keyed shape remains a whole-field choice because its identity is
    // outside the supported ordered-array schema.
    const keyed_base = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - key: A\n    value: 1\n";
    const keyed_ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - key: A\n    value: 2\n";
    try runDriverCase(keyed_base, keyed_ours, keyed_base, "<<<<<<< ours\n" ++ keyed_ours ++ "=======\n" ++ keyed_base ++ ">>>>>>> theirs\n", 1);
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
