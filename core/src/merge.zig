const std = @import("std");
const merge_model = @import("merge_model.zig");
const merge_planner = @import("merge_planner.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

pub const Error = merge_model.Error;
pub const MergePlan = merge_model.MergePlan;
pub const Operation = merge_model.Operation;
pub const OperationId = merge_model.OperationId;
pub const Resolution = merge_model.Resolution;
pub const SideValue = merge_model.SideValue;

pub const BuildResult = struct {
    plan: MergePlan,
    partial: []const u8,
};

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
    order: usize,
};

pub fn build(
    arena: std.mem.Allocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
) Error!BuildResult {
    const parsed_base = try parser.parseSpanned(arena, base);
    const parsed_ours = try parser.parseSpanned(arena, ours);
    const parsed_theirs = try parser.parseSpanned(arena, theirs);
    const plan = try merge_planner.build(arena, parsed_base, parsed_ours, parsed_theirs);
    return .{
        .plan = plan,
        .partial = try render(arena, &plan, true),
    };
}

pub fn resolve(
    arena: std.mem.Allocator,
    plan: *MergePlan,
    operation_id: OperationId,
    resolution: Resolution,
) Error!void {
    const operation = merge_model.operationById(plan, operation_id) orelse return error.InvalidResolution;
    switch (resolution) {
        .take => |side| {
            const value = valueForSide(operation, side);
            if (value == null) return error.InvalidResolution;
        },
        .custom => |bytes| {
            operation.resolution = .{ .custom = try arena.dupe(u8, bytes) };
            return;
        },
        .unresolved, .remove => {},
    }
    operation.resolution = resolution;
}

pub fn finish(arena: std.mem.Allocator, plan: *const MergePlan) Error![]const u8 {
    if (plan.unresolvedCount() != 0) return error.InvalidMerge;
    return render(arena, plan, false);
}

fn render(arena: std.mem.Allocator, plan: *const MergePlan, allow_unresolved: bool) Error![]const u8 {
    var edits: std.ArrayList(Edit) = .empty;
    for (plan.operations, 0..) |*operation, order| {
        if (allow_unresolved and try atomicHasUnresolved(plan, operation.atomic_id)) continue;
        const replacement = switch (operation.resolution) {
            .unresolved => if (allow_unresolved) continue else return error.InvalidMerge,
            .take => |side| (valueForSide(operation, side) orelse return error.InvalidResolution).bytes,
            .remove => "",
            .custom => |bytes| bytes,
        };
        try appendEdit(arena, &edits, plan, operation, replacement, order);
    }
    std.mem.sort(Edit, edits.items, {}, lessThanEdit);

    var output: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (edits.items) |edit| {
        if (edit.start < cursor or edit.end < edit.start or edit.end > plan.ours.bytes.len) return error.InvalidMerge;
        try output.appendSlice(arena, plan.ours.bytes[cursor..edit.start]);
        try output.appendSlice(arena, edit.replacement);
        cursor = edit.end;
    }
    try output.appendSlice(arena, plan.ours.bytes[cursor..]);
    return output.toOwnedSlice(arena);
}

fn appendEdit(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(Edit),
    plan: *const MergePlan,
    operation: *const Operation,
    replacement: []const u8,
    order: usize,
) Error!void {
    if (operation.resolution == .remove) {
        const ours = operation.values.ours orelse return;
        const node = ours.node orelse return error.InvalidMerge;
        const entry = plan.ours.entry_spans.get(node) orelse return error.UnsupportedStructure;
        return edits.append(arena, .{ .start = entry.whole.start, .end = entry.whole.end, .replacement = "", .order = order });
    }
    if (operation.values.ours) |ours| {
        const span = ours.span orelse return error.UnsupportedStructure;
        if (std.mem.eql(u8, span.bytes(plan.ours.bytes), replacement)) return;
        return edits.append(arena, .{ .start = span.start, .end = span.end, .replacement = replacement, .order = order });
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
    try edits.append(arena, .{
        .start = insert_at,
        .end = insert_at,
        .replacement = inserted,
        .order = order,
    });
}

const SelectedValue = struct { side: merge_model.Side, value: SideValue };

fn selectedValue(operation: *const Operation) ?SelectedValue {
    return switch (operation.resolution) {
        .take => |side| if (valueForSide(operation, side)) |value| .{ .side = side, .value = value } else null,
        else => null,
    };
}

fn insertionTemplate(operation: *const Operation) ?SelectedValue {
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
    value: SideValue,
    replacement: []const u8,
) Error![]const u8 {
    const value_span = value.span orelse return error.UnsupportedStructure;
    if (value_span.start < entry.whole.start or value_span.end > entry.whole.end) return error.UnsupportedStructure;
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, file.bytes[entry.whole.start..value_span.start]);
    try bytes.appendSlice(arena, replacement);
    try bytes.appendSlice(arena, file.bytes[value_span.end..entry.whole.end]);
    return bytes.toOwnedSlice(arena);
}

fn atomicHasUnresolved(plan: *const MergePlan, atomic_id: merge_model.AtomicId) Error!bool {
    for (plan.atomic_operations) |atomic| {
        if (atomic.id != atomic_id) continue;
        for (atomic.operation_ids) |operation_id| {
            const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
            if (operation.resolution == .unresolved) return true;
        }
        return false;
    }
    return error.InvalidMerge;
}

fn valueForSide(operation: *const Operation, side: merge_model.Side) ?SideValue {
    return switch (side) {
        .base => operation.values.base,
        .ours => operation.values.ours,
        .theirs => operation.values.theirs,
    };
}

fn fileForSide(plan: *const MergePlan, side: merge_model.Side) source.ParsedFile {
    return switch (side) {
        .base => plan.base,
        .ours => plan.ours,
        .theirs => plan.theirs,
    };
}

fn insertionOffset(plan: *const MergePlan, operation: *const Operation) Error!usize {
    for (plan.ours.documents, plan.ours.document_spans) |document, document_span| {
        if (document.class_id != operation.identity.document.class_id or
            document.file_id != operation.identity.document.file_id) continue;

        var parent = document.body;
        if (std.mem.lastIndexOfScalar(u8, operation.property_path, '.')) |last_dot| {
            var components = std.mem.splitScalar(u8, operation.property_path[0..last_dot], '.');
            while (components.next()) |component| {
                parent = switch (parent.*) {
                    .map => |entries| findValue(entries, component) orelse return error.UnsupportedStructure,
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

fn findValue(entries: []const @import("model.zig").Entry, key: []const u8) ?*@import("model.zig").Node {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn lessThanEdit(_: void, a: Edit, b: Edit) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.order < b.order;
}

test "partial merge holds all members of an unresolved atomic operation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  first: 1\n  second: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  first: 1\n  second: 2\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  first: 3\n  second: 3\n";
    var built = try build(arena, base, ours, theirs);
    const operation_ids = try arena.dupe(OperationId, &.{ 0, 1 });
    built.plan.operations[1].atomic_id = 0;
    built.plan.atomic_operations[0].operation_ids = operation_ids;
    built.plan.atomic_operations = built.plan.atomic_operations[0..1];

    const partial = try render(arena, &built.plan, true);

    try std.testing.expectEqualStrings(ours, partial);
}

test "custom value inserts a field that is absent from ours" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
    var built = try build(arena, base, ours, theirs);

    try resolve(arena, &built.plan, 0, .{ .custom = "3" });
    const result = try finish(arena, &built.plan);

    try std.testing.expectEqualStrings(
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n",
        result,
    );
}

test "empty scalar stays present for take and custom resolutions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {x: 1}\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {x: 2}\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {x: }\n";

    var taken = try build(arena, base, ours, theirs);
    try resolve(arena, &taken.plan, 0, .{ .take = .theirs });
    try std.testing.expectEqualStrings(theirs, try finish(arena, &taken.plan));

    var custom = try build(arena, base, ours, theirs);
    try resolve(arena, &custom.plan, 0, .{ .custom = "" });
    try std.testing.expectEqualStrings(theirs, try finish(arena, &custom.plan));
}
