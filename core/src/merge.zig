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
            if (bytes.len == 0) return error.InvalidResolution;
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
    if (operation.resolution == .remove and operation.values.ours == null) return;
    if (operation.values.ours) |ours| {
        if (replacement.len == 0) {
            const node = ours.node orelse return error.InvalidMerge;
            const entry = plan.ours.entry_spans.get(node) orelse return error.UnsupportedStructure;
            return edits.append(arena, .{ .start = entry.whole.start, .end = entry.whole.end, .replacement = "", .order = order });
        }
        const span = ours.span orelse return error.UnsupportedStructure;
        if (std.mem.eql(u8, span.bytes(plan.ours.bytes), replacement)) return;
        return edits.append(arena, .{ .start = span.start, .end = span.end, .replacement = replacement, .order = order });
    }

    const selected = selectedValue(operation) orelse return error.InvalidResolution;
    const node = selected.value.node orelse return error.InvalidMerge;
    const selected_file = fileForSide(plan, selected.side);
    const entry = selected_file.entry_spans.get(node) orelse return error.UnsupportedStructure;
    const insert_at = try insertionOffset(plan, operation);
    try edits.append(arena, .{
        .start = insert_at,
        .end = insert_at,
        .replacement = entry.whole.bytes(selected_file.bytes),
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
