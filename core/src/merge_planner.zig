const std = @import("std");
const merge_identity = @import("merge_identity.zig");
const merge_model = @import("merge_model.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

const testing = std.testing;

const Decision = enum { ours, theirs, common, conflict };

const DocumentNodes = struct {
    base: ?*const model.Node,
    ours: ?*const model.Node,
    theirs: ?*const model.Node,
};

pub fn build(
    arena: std.mem.Allocator,
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
) merge_model.Error!merge_model.MergePlan {
    try validateMergeSide(arena, base);
    try validateMergeSide(arena, ours);
    try validateMergeSide(arena, theirs);

    var operations: std.ArrayList(merge_model.Operation) = .empty;
    var atomic_operations: std.ArrayList(merge_model.AtomicOperation) = .empty;

    for (base.documents) |base_document| {
        const ours_document = findDocument(ours.documents, base_document.class_id, base_document.file_id) orelse continue;
        const theirs_document = findDocument(theirs.documents, base_document.class_id, base_document.file_id) orelse continue;
        try collectMapFields(
            arena,
            &operations,
            &atomic_operations,
            .{ .class_id = base_document.class_id, .file_id = base_document.file_id },
            ours_document.type_name,
            "",
            .{
                .base = base_document.body,
                .ours = ours_document.body,
                .theirs = theirs_document.body,
            },
            base,
            ours,
            theirs,
        );
    }

    return .{
        .base = base,
        .ours = ours,
        .theirs = theirs,
        .operations = try operations.toOwnedSlice(arena),
        .atomic_operations = try atomic_operations.toOwnedSlice(arena),
    };
}

fn collectMapFields(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    parent_path: []const u8,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
) merge_model.Error!void {
    const base_entries = mapEntries(nodes.base);
    const ours_entries = mapEntries(nodes.ours);
    const theirs_entries = mapEntries(nodes.theirs);

    for (base_entries) |entry| {
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{
                .base = entry.value,
                .ours = findValueConst(ours_entries, entry.key),
                .theirs = findValueConst(theirs_entries, entry.key),
            },
            base_file,
            ours_file,
            theirs_file,
        );
    }
    for (ours_entries) |entry| {
        if (findValueConst(base_entries, entry.key) != null) continue;
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{
                .base = null,
                .ours = entry.value,
                .theirs = findValueConst(theirs_entries, entry.key),
            },
            base_file,
            ours_file,
            theirs_file,
        );
    }
    for (theirs_entries) |entry| {
        if (findValueConst(base_entries, entry.key) != null or findValueConst(ours_entries, entry.key) != null) continue;
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{ .base = null, .ours = null, .theirs = entry.value },
            base_file,
            ours_file,
            theirs_file,
        );
    }
}

fn collectField(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    parent_path: []const u8,
    key: []const u8,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
) merge_model.Error!void {
    const property_path = if (parent_path.len == 0)
        try arena.dupe(u8, key)
    else
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent_path, key });

    if (hasMap(nodes)) {
        if (hasNonMap(nodes)) return error.UnsupportedStructure;
        return collectMapFields(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            property_path,
            nodes,
            base_file,
            ours_file,
            theirs_file,
        );
    }
    if (hasSequence(nodes)) {
        if (equalOptional(nodes.base, nodes.ours) and equalOptional(nodes.base, nodes.theirs)) return;
        return error.UnsupportedStructure;
    }
    if (equalOptional(nodes.base, nodes.ours) and equalOptional(nodes.base, nodes.theirs)) return;

    const decision = decide(nodes.base, nodes.ours, nodes.theirs);
    const resolution: merge_model.Resolution = switch (decision) {
        .ours, .common => if (nodes.ours == null) .remove else .{ .take = .ours },
        .theirs => if (nodes.theirs == null) .remove else .{ .take = .theirs },
        .conflict => .unresolved,
    };
    const operation_id: merge_model.OperationId = @intCast(operations.items.len);
    const atomic_id: merge_model.AtomicId = @intCast(atomic_operations.items.len);
    try operations.append(arena, .{
        .id = operation_id,
        .atomic_id = atomic_id,
        .kind = .field,
        .identity = .{ .document = document_id, .property_path = property_path },
        .hierarchy_path = hierarchy_path,
        .property_path = property_path,
        .values = .{
            .base = sideValue(base_file, nodes.base),
            .ours = sideValue(ours_file, nodes.ours),
            .theirs = sideValue(theirs_file, nodes.theirs),
        },
        .resolution = resolution,
    });
    const ids = try arena.alloc(merge_model.OperationId, 1);
    ids[0] = operation_id;
    try atomic_operations.append(arena, .{
        .id = atomic_id,
        .kind = .field,
        .operation_ids = ids,
    });
}

fn findDocument(documents: []const model.Document, class_id: u32, file_id: i64) ?model.Document {
    for (documents) |document| {
        if (document.class_id == class_id and document.file_id == file_id) return document;
    }
    return null;
}

fn mapEntries(node: ?*const model.Node) []const model.Entry {
    const present = node orelse return &.{};
    return switch (present.*) {
        .map => |entries| entries,
        else => &.{},
    };
}

fn findValueConst(entries: []const model.Entry, key: []const u8) ?*const model.Node {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn hasMap(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* == .map) return true;
    }
    return false;
}

fn hasNonMap(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* != .map) return true;
    }
    return false;
}

fn hasSequence(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* == .seq) return true;
    }
    return false;
}

fn sideValue(file: source.ParsedFile, node: ?*const model.Node) ?merge_model.SideValue {
    const present = node orelse return null;
    return .{
        .node = present,
        .bytes = file.nodeBytes(present) orelse "",
        .span = file.node_spans.get(present),
    };
}

fn equalOptional(a: ?*const model.Node, b: ?*const model.Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return model.Node.eql(a.?, b.?);
}

fn decide(base: ?*const model.Node, ours: ?*const model.Node, theirs: ?*const model.Node) Decision {
    if (equalOptional(ours, base)) return .theirs;
    if (equalOptional(theirs, base)) return .ours;
    if (equalOptional(ours, theirs)) return .common;
    return .conflict;
}

pub fn parseMergeSide(arena: std.mem.Allocator, bytes: []const u8) merge_model.Error!source.ParsedFile {
    if (bytes.len != 0 and !parser.isUnityYaml(bytes)) return error.MalformedInput;
    const parsed = try parser.parseSpanned(arena, bytes);
    try validateMergeSide(arena, parsed);
    return parsed;
}

fn validateMergeSide(arena: std.mem.Allocator, parsed: source.ParsedFile) merge_model.Error!void {
    if (parsed.bytes.len != 0 and !parser.isUnityYaml(parsed.bytes)) return error.MalformedInput;
    if (parsed.diagnostics.len != 0) return error.MalformedInput;
    try merge_identity.rejectDuplicateDocuments(arena, parsed.documents);
}

fn yamlWithValue(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {s}\n",
        .{value},
    );
}

fn expectResult(
    arena: std.mem.Allocator,
    expected: ?[]const u8,
    built: @import("merge.zig").BuildResult,
) !void {
    if (expected) |value| {
        try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
        const line = try std.fmt.allocPrint(arena, "  m_Value: {s}\n", .{value});
        try testing.expect(std.mem.indexOf(u8, built.partial, line) != null);
    } else {
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    }
}

test "merge planner: applies every scalar three-way rule symmetrically" {
    const Case = struct { base: []const u8, ours: []const u8, theirs: []const u8, result: ?[]const u8 };
    const cases = [_]Case{
        .{ .base = "5", .ours = "5", .theirs = "8", .result = "8" },
        .{ .base = "5", .ours = "12", .theirs = "5", .result = "12" },
        .{ .base = "5", .ours = "12", .theirs = "12", .result = "12" },
        .{ .base = "5", .ours = "12", .theirs = "8", .result = null },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const base = try yamlWithValue(arena, case.base);
        const ours = try yamlWithValue(arena, case.ours);
        const theirs = try yamlWithValue(arena, case.theirs);
        const first = try @import("merge.zig").build(arena, base, ours, theirs);
        const second = try @import("merge.zig").build(arena, base, theirs, ours);
        try expectResult(arena, case.result, first);
        try expectResult(arena, case.result, second);
    }
}

test "merge planner: compares the complete object reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "{fileID: 7, guid: aaa, type: 3}");
    const ours = try yamlWithValue(arena, "{fileID: 7, guid: bbb, type: 3}");
    const theirs = try yamlWithValue(arena, "{fileID: 7, guid: ccc, type: 3}");
    const built = try @import("merge.zig").build(arena, base, ours, theirs);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "merge planner: rejects a changed sequence without a safe identity" {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 3\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnsupportedStructure, @import("merge.zig").build(arena_state.allocator(), base, ours, theirs));
}

test "merge planner: keeps an unchanged unknown sequence byte-for-byte" {
    const yaml = "--- !u!114 &1\nMonoBehaviour:\n  # Keep this order and spelling.\n  m_Unknown:\n  - 01\n  - 2\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try @import("merge.zig").build(arena_state.allocator(), yaml, yaml, yaml);
    try testing.expectEqualStrings(yaml, built.partial);
}

test "merge planner: rejects a non-Unity merge side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), "value: 1\n"));
}

test "merge planner: rejects a merge side with parser diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const malformed = "--- !u!114 &bad\nMonoBehaviour:\n  value: 1\n";
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), malformed));
}

test "merge planner: rejects duplicate document identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const duplicate =
        "--- !u!1 &7\nGameObject:\n  m_Name: First\n" ++
        "--- !u!1 &7\nGameObject:\n  m_Name: Second\n";
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), duplicate));
}

test "merge planner: rejects malformed input through the merge facade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const unity = "--- !u!114 &1\nMonoBehaviour:\n  value: 1\n";
    try testing.expectError(
        error.MalformedInput,
        @import("merge.zig").build(arena_state.allocator(), "value: 1\n", unity, unity),
    );
}

test "merge planner: rejects duplicate documents through the merge facade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const duplicate =
        "--- !u!1 &7\nGameObject:\n  m_Name: First\n" ++
        "--- !u!1 &7\nGameObject:\n  m_Name: Second\n";
    try testing.expectError(
        error.MalformedInput,
        @import("merge.zig").build(arena_state.allocator(), duplicate, duplicate, duplicate),
    );
}

test "merge planner: adds a field to its matching document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Name: First\n" ++
        "--- !u!114 &2\nMonoBehaviour:\n  m_Value: 5\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Name: First\n" ++
        "--- !u!114 &2\nMonoBehaviour:\n  m_Value: 5\n  m_Enabled: 1\n";

    const built = try @import("merge.zig").build(arena, base, base, theirs);

    try testing.expectEqualStrings(theirs, built.partial);
}

test "merge planner: removes a field when the other side is unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const removed = "--- !u!114 &1\nMonoBehaviour:\n";

    const first = try @import("merge.zig").build(arena, base, base, removed);
    const second = try @import("merge.zig").build(arena, base, removed, base);

    try testing.expectEqualStrings(removed, first.partial);
    try testing.expectEqualStrings(removed, second.partial);
}

test "merge planner: keeps our bytes for a common semantic value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const ours = try yamlWithValue(arena, "'12'");
    const theirs = try yamlWithValue(arena, "\"12\"");

    const built = try @import("merge.zig").build(arena, base, ours, theirs);

    try testing.expectEqualStrings(ours, built.partial);
}

test "merge facade: retains a custom resolution" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const ours = try yamlWithValue(arena, "8");
    const theirs = try yamlWithValue(arena, "12");
    var custom = [_]u8{ '4', '2' };
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = &custom });
    custom = .{ '9', '9' };
    const result = try @import("merge.zig").finish(arena, &built.plan);

    try testing.expect(std.mem.indexOf(u8, result, "  m_Value: 42\n") != null);
}

test "merge facade: rejects an invalid custom value and keeps the atomic operation unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "1");
    const ours = try yamlWithValue(arena, "2");
    const theirs = try yamlWithValue(arena, "3");
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try testing.expectError(
        error.InvalidResolution,
        @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = "{x: 1}" }),
    );
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "merge facade: restores an atomic operation when its patches overlap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  first: 1\n  second: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  first: 2\n  second: 2\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  first: 3\n  second: 3\n";
    var built = try @import("merge.zig").build(arena, base, ours, theirs);
    const operation_ids = try arena.dupe(merge_model.OperationId, &.{ 0, 1 });
    built.plan.operations[1].atomic_id = 0;
    built.plan.operations[1].values.ours.?.span = built.plan.operations[0].values.ours.?.span;
    built.plan.atomic_operations[0].operation_ids = operation_ids;
    built.plan.atomic_operations = built.plan.atomic_operations[0..1];

    try testing.expectError(
        error.InvalidMerge,
        @import("merge.zig").resolve(arena, &built.plan, 0, .{ .take = .theirs }),
    );
    try testing.expect(built.plan.operations[0].resolution == .unresolved);
    try testing.expect(built.plan.operations[1].resolution == .unresolved);
}
