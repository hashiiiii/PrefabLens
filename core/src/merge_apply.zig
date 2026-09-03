const std = @import("std");
const merge_model = @import("merge_model.zig");
const merge_planner = @import("merge_planner.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

const testing = std.testing;

pub const Patch = struct {
    span: source.Span,
    replacement: []const u8,
    atomic_id: merge_model.AtomicId,
};

pub const ResolutionValue = union(enum) {
    yaml_empty,
    scalar: []const u8,
    object_reference: model.Ref,
};

pub fn applyPatches(
    arena: std.mem.Allocator,
    original: []const u8,
    input: []const Patch,
) merge_model.Error![]const u8 {
    const patches = try arena.dupe(Patch, input);
    std.mem.sort(Patch, patches, {}, struct {
        fn lessThan(_: void, a: Patch, b: Patch) bool {
            if (a.span.start != b.span.start) return a.span.start > b.span.start;
            return a.atomic_id > b.atomic_id;
        }
    }.lessThan);
    var previous_start = original.len;
    var output = try std.ArrayList(u8).initCapacity(arena, original.len);
    try output.appendSlice(arena, original);
    for (patches) |patch| {
        if (patch.span.start > patch.span.end or
            patch.span.end > previous_start or
            patch.span.end > original.len) return error.InvalidMerge;
        try output.replaceRange(arena, patch.span.start, patch.span.end - patch.span.start, patch.replacement);
        previous_start = patch.span.start;
    }
    return output.toOwnedSlice(arena);
}

pub fn applyResolved(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    require_all: bool,
) merge_model.Error![]const u8 {
    var patches: std.ArrayList(Patch) = .empty;
    for (plan.atomic_operations) |atomic| {
        if (!try atomicIsReady(plan, atomic)) {
            if (require_all) return error.InvalidResolution;
            continue;
        }
        for (atomic.operation_ids) |operation_id| {
            const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
            try appendPatch(arena, &patches, plan, operation);
        }
    }
    return applyPatches(arena, plan.ours.bytes, patches.items);
}

fn atomicIsReady(
    plan: *const merge_model.MergePlan,
    atomic: merge_model.AtomicOperation,
) merge_model.Error!bool {
    if (atomic.operation_ids.len == 0) return error.InvalidMerge;
    if (!try dependenciesAreResolved(plan, atomic.dependencies)) return false;
    for (atomic.operation_ids) |operation_id| {
        const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
        if (operation.atomic_id != atomic.id) return error.InvalidMerge;
        if (operation.resolution == .unresolved) return false;
        if (!try dependenciesAreResolved(plan, operation.dependencies)) return false;
    }
    return true;
}

fn dependenciesAreResolved(
    plan: *const merge_model.MergePlan,
    dependencies: []const merge_model.AtomicId,
) merge_model.Error!bool {
    for (dependencies) |dependency_id| {
        const dependency = atomicByIdConst(plan, dependency_id) orelse return error.InvalidMerge;
        for (dependency.operation_ids) |operation_id| {
            const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
            if (operation.resolution == .unresolved) return false;
        }
    }
    return true;
}

fn appendPatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) merge_model.Error!void {
    if (operation.resolution == .remove) {
        const ours = operation.values.ours orelse return;
        const node = ours.node orelse return error.InvalidMerge;
        const entry = plan.ours.entry_spans.get(node) orelse return error.UnsupportedStructure;
        return patches.append(arena, .{
            .span = entry.whole,
            .replacement = "",
            .atomic_id = operation.atomic_id,
        });
    }

    const replacement = switch (operation.resolution) {
        .unresolved, .remove => return error.InvalidResolution,
        .take => |side| (valueForSide(operation, side) orelse return error.InvalidResolution).bytes,
        .custom => |input| blk: {
            _ = try parseCustomValue(arena, input);
            break :blk input;
        },
    };
    if (operation.values.ours) |ours| {
        const span = ours.span orelse return error.UnsupportedStructure;
        if (std.mem.eql(u8, span.bytes(plan.ours.bytes), replacement)) return;
        return patches.append(arena, .{
            .span = span,
            .replacement = replacement,
            .atomic_id = operation.atomic_id,
        });
    }

    const template = insertionTemplate(operation) orelse return error.InvalidResolution;
    const node = template.value.node orelse return error.InvalidMerge;
    const template_file = fileForSide(plan, template.side);
    const entry = template_file.entry_spans.get(node) orelse return error.UnsupportedStructure;
    const inserted = switch (operation.resolution) {
        .take => entry.whole.bytes(template_file.bytes),
        .custom => try entryWithValue(arena, template_file, entry, template.value, replacement),
        .unresolved, .remove => return error.InvalidResolution,
    };
    const insert_at = try insertionOffset(plan, operation);
    try patches.append(arena, .{
        .span = .{ .start = insert_at, .end = insert_at },
        .replacement = inserted,
        .atomic_id = operation.atomic_id,
    });
}

const SelectedValue = struct { side: merge_model.Side, value: merge_model.SideValue };

fn selectedValue(operation: *const merge_model.Operation) ?SelectedValue {
    return switch (operation.resolution) {
        .take => |side| if (valueForSide(operation, side)) |value| .{ .side = side, .value = value } else null,
        else => null,
    };
}

fn insertionTemplate(operation: *const merge_model.Operation) ?SelectedValue {
    if (selectedValue(operation)) |selected| return selected;
    if (operation.resolution != .custom) return null;
    if (operation.values.theirs) |value| return .{ .side = .theirs, .value = value };
    if (operation.values.base) |value| return .{ .side = .base, .value = value };
    return null;
}

fn entryWithValue(
    arena: std.mem.Allocator,
    file: source.ParsedFile,
    entry: source.EntrySpan,
    value: merge_model.SideValue,
    replacement: []const u8,
) merge_model.Error![]const u8 {
    const value_span = value.span orelse return error.UnsupportedStructure;
    if (value_span.start < entry.whole.start or value_span.end > entry.whole.end) return error.UnsupportedStructure;
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, file.bytes[entry.whole.start..value_span.start]);
    try bytes.appendSlice(arena, replacement);
    try bytes.appendSlice(arena, file.bytes[value_span.end..entry.whole.end]);
    return bytes.toOwnedSlice(arena);
}

fn valueForSide(operation: *const merge_model.Operation, side: merge_model.Side) ?merge_model.SideValue {
    return switch (side) {
        .base => operation.values.base,
        .ours => operation.values.ours,
        .theirs => operation.values.theirs,
    };
}

fn fileForSide(plan: *const merge_model.MergePlan, side: merge_model.Side) source.ParsedFile {
    return switch (side) {
        .base => plan.base,
        .ours => plan.ours,
        .theirs => plan.theirs,
    };
}

fn insertionOffset(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) merge_model.Error!usize {
    for (plan.ours.documents, plan.ours.document_spans) |document, document_span| {
        if (document.class_id != operation.identity.document.class_id or
            document.file_id != operation.identity.document.file_id) continue;

        var parent = document.body;
        if (std.mem.lastIndexOfScalar(u8, operation.property_path, '.')) |last_dot| {
            var components = std.mem.splitScalar(u8, operation.property_path[0..last_dot], '.');
            while (components.next()) |component| {
                parent = switch (parent.*) {
                    .map => |entries| model.findValue(entries, component) orelse return error.UnsupportedStructure,
                    else => return error.UnsupportedStructure,
                };
            }
        }
        if (plan.ours.node_spans.get(parent)) |span| return span.end;
        if (plan.ours.entry_spans.get(parent)) |entry| return entry.whole.end;
        if (parent == document.body) return document_span.whole.end;
        return error.UnsupportedStructure;
    }
    return error.UnsupportedStructure;
}

fn atomicByIdConst(
    plan: *const merge_model.MergePlan,
    id: merge_model.AtomicId,
) ?*const merge_model.AtomicOperation {
    for (plan.atomic_operations) |*atomic| {
        if (atomic.id == id) return atomic;
    }
    return null;
}

pub fn parseCustomValue(arena: std.mem.Allocator, input: []const u8) merge_model.Error!ResolutionValue {
    if (input.len == 0) return .yaml_empty;
    if (std.mem.indexOfAny(u8, input, "\r\n") != null) return error.InvalidResolution;
    const wrapper = try std.fmt.allocPrint(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  value: {s}\n",
        .{input},
    );
    const parsed = try parser.parseSpanned(arena, wrapper);
    if (parsed.diagnostics.len != 0 or parsed.documents.len != 1) return error.InvalidResolution;
    if (parsed.documents[0].body.map.len != 1) return error.InvalidResolution;
    const value = model.findValue(parsed.documents[0].body.map, "value") orelse return error.InvalidResolution;
    return switch (value.*) {
        .scalar => .{ .scalar = input },
        .ref => |ref_value| .{ .object_reference = ref_value },
        else => error.InvalidResolution,
    };
}

test "merge apply: reuses selected token bytes and keeps untouched bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!54 &54\r\nRigidbody:\r\n  m_Mass: 5\r\n  m_Drag: 0 # keep\r\n";
    const ours = "--- !u!54 &54\r\nRigidbody:\r\n  m_Mass: 12\r\n  m_Drag: 0 # keep\r\n";
    const theirs = "--- !u!54 &54\r\nRigidbody:\r\n  m_Mass: 5\r\n  m_Drag: 01 # keep\r\n";
    var plan = try merge_planner.build(
        arena,
        try merge_planner.parseMergeSide(arena, base),
        try merge_planner.parseMergeSide(arena, ours),
        try merge_planner.parseMergeSide(arena, theirs),
    );
    try testing.expectEqualStrings(
        "--- !u!54 &54\r\nRigidbody:\r\n  m_Mass: 12\r\n  m_Drag: 01 # keep\r\n",
        try applyResolved(arena, &plan, false),
    );
}

test "merge apply: distinguishes YAML empty from an empty string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const yaml_empty = try parseCustomValue(arena, "");
    const empty_string = try parseCustomValue(arena, "\"\"");
    try testing.expect(yaml_empty == .yaml_empty);
    try testing.expect(empty_string == .scalar);
}

test "merge apply: parses an object reference custom value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const value = try parseCustomValue(
        arena_state.allocator(),
        "{fileID: 7, guid: aaa, type: 3}",
    );
    try testing.expectEqual(@as(i64, 7), value.object_reference.file_id);
    try testing.expectEqualStrings("aaa", value.object_reference.guid.?);
    try testing.expectEqual(@as(i64, 3), value.object_reference.type_id.?);
}

test "merge apply: rejects a multiline custom value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.InvalidResolution,
        parseCustomValue(arena_state.allocator(), "first\nsecond"),
    );
}

test "merge apply: rejects overlapping patches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const patches = [_]Patch{
        .{ .span = .{ .start = 2, .end = 5 }, .replacement = "a", .atomic_id = 1 },
        .{ .span = .{ .start = 4, .end = 7 }, .replacement = "b", .atomic_id = 2 },
    };
    try testing.expectError(error.InvalidMerge, applyPatches(arena_state.allocator(), "0123456789", &patches));
}
