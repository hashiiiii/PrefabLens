const std = @import("std");
const merge_identity = @import("merge_identity.zig");
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
    order: usize = 0,
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
            if (a.atomic_id != b.atomic_id) return a.atomic_id > b.atomic_id;
            return a.order > b.order;
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
    var dependency_path: std.ArrayList(merge_model.AtomicId) = .empty;
    for (plan.atomic_operations) |atomic| {
        dependency_path.clearRetainingCapacity();
        if (!try atomicIsReady(arena, plan, atomic, &dependency_path)) {
            if (require_all) return error.InvalidResolution;
            if (atomic.kind == .component or atomic.kind == .game_object) {
                for (atomic.operation_ids) |operation_id| {
                    const stored = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
                    var operation = stored.*;
                    operation.resolution = if (operation.values.base == null) .remove else .{ .take = .base };
                    try appendPatch(arena, &patches, plan, &operation);
                }
            }
            continue;
        }
        for (atomic.operation_ids) |operation_id| {
            const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
            try appendPatch(arena, &patches, plan, operation);
        }
    }
    for (plan.operations) |*operation| {
        if (isComponentSequenceOrder(plan, operation)) {
            try appendComposedComponentSequencePatch(arena, &patches, plan, operation);
        } else if (isHierarchySequenceOrder(plan, operation)) {
            try appendComposedHierarchySequencePatch(arena, &patches, plan, operation);
        } else if (isPrefabSequenceOrder(operation)) {
            try appendComposedPrefabSequencePatch(arena, &patches, plan, operation);
        }
    }
    return applyPatches(arena, plan.ours.bytes, patches.items);
}

fn atomicIsReady(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    atomic: merge_model.AtomicOperation,
    path: *std.ArrayList(merge_model.AtomicId),
) merge_model.Error!bool {
    for (path.items) |ancestor_id| {
        if (ancestor_id == atomic.id) return error.InvalidMerge;
    }
    try path.append(arena, atomic.id);
    defer _ = path.pop();

    if (atomic.operation_ids.len == 0) return error.InvalidMerge;
    var ready = true;
    for (atomic.dependencies) |dependency_id| {
        const dependency = atomicByIdConst(plan, dependency_id) orelse return error.InvalidMerge;
        if (!try atomicIsReady(arena, plan, dependency.*, path)) ready = false;
    }
    for (atomic.operation_ids) |operation_id| {
        const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidMerge;
        if (operation.atomic_id != atomic.id) return error.InvalidMerge;
        if (operation.resolution == .unresolved) ready = false;
        for (operation.dependencies) |dependency_id| {
            const dependency = atomicByIdConst(plan, dependency_id) orelse return error.InvalidMerge;
            if (!try atomicIsReady(arena, plan, dependency.*, path)) ready = false;
        }
    }
    return ready;
}

fn appendPatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) merge_model.Error!void {
    if (operation.kind == .sequence_membership) return;
    if (operation.kind == .sequence_content) return;
    if (operation.kind == .prefab_override) return;
    if (isComponentSequenceOrder(plan, operation) or
        isHierarchySequenceOrder(plan, operation) or
        isPrefabSequenceOrder(operation)) return;
    if (operation.kind == .component or operation.kind == .game_object) {
        return appendDocumentPatch(arena, patches, plan, operation);
    }
    if (operation.resolution == .remove) {
        const ours = operation.values.ours orelse return;
        const node = ours.node orelse return error.InvalidMerge;
        const entry = plan.ours.entry_spans.get(node) orelse return error.UnsupportedStructure;
        return patches.append(arena, .{
            .span = entry.whole,
            .replacement = "",
            .atomic_id = operation.atomic_id,
            .order = operation.id,
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
            .order = operation.id,
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
        .order = operation.id,
    });
}

fn isComponentSequenceOrder(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) bool {
    if (operation.kind != .sequence_order or
        !std.mem.eql(u8, operation.property_path, "m_Component")) return false;
    const atomic = atomicByIdConst(plan, operation.atomic_id) orelse return false;
    for (atomic.dependencies) |dependency_id| {
        const dependency = atomicByIdConst(plan, dependency_id) orelse return false;
        if (dependency.kind == .component) return true;
    }
    return false;
}

fn isHierarchySequenceOrder(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) bool {
    if (operation.kind != .sequence_order or
        !std.mem.eql(u8, operation.property_path, "m_Children")) return false;
    const atomic = atomicByIdConst(plan, operation.atomic_id) orelse return false;
    for (atomic.dependencies) |dependency_id| {
        const dependency = atomicByIdConst(plan, dependency_id) orelse return false;
        if (dependency.kind == .game_object or dependency.kind == .reparent) return true;
    }
    return false;
}

fn isPrefabSequenceOrder(operation: *const merge_model.Operation) bool {
    if (operation.kind != .sequence_order or operation.identity.document.class_id != 1001) return false;
    const kind = merge_identity.sequenceKind(
        operation.identity.document.class_id,
        operation.property_path,
    ) orelse return false;
    return switch (kind) {
        .prefab_properties,
        .prefab_added_components,
        .prefab_removed_components,
        .prefab_added_game_objects,
        .prefab_removed_game_objects,
        => true,
        .components, .children => false,
    };
}

fn appendComposedHierarchySequencePatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    order_operation: *const merge_model.Operation,
) merge_model.Error!void {
    const ours_sequence = findSequence(plan.ours, order_operation) orelse return error.UnsupportedStructure;
    if (ours_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_order = switch (order_operation.resolution) {
        .unresolved => if (order_operation.values.ours) |value|
            SelectedValue{ .side = .ours, .value = value }
        else
            return error.InvalidResolution,
        .take => |side| SelectedValue{
            .side = side,
            .value = valueForSide(order_operation, side) orelse return error.InvalidResolution,
        },
        .remove, .custom => return error.InvalidResolution,
    };
    var order: std.ArrayList(i64) = .empty;
    try order.appendSlice(arena, try hierarchyOrder(arena, selected_order.value.bytes));
    var choices: std.ArrayList(SequenceChoice) = .empty;
    for (plan.operations) |*operation| {
        if (operation.kind != .sequence_membership or
            operation.identity.document.class_id != order_operation.identity.document.class_id or
            operation.identity.document.file_id != order_operation.identity.document.file_id or
            !std.mem.eql(u8, operation.property_path, order_operation.property_path)) continue;
        const atomic = atomicByIdConst(plan, operation.atomic_id) orelse return error.InvalidMerge;
        if (atomic.kind != .game_object and atomic.kind != .reparent) continue;
        const file_id = (operation.identity.item_ref orelse return error.InvalidMerge).file_id;
        const selected = try effectiveHierarchyChoice(operation, atomic.kind);
        try choices.append(arena, .{ .file_id = file_id, .selected = selected });
        if (selected == null) {
            removeComponentId(&order, file_id);
        } else if (!containsComponentId(order.items, file_id)) {
            try insertHierarchyId(arena, &order, plan, order_operation, selected.?.side, file_id);
        }
    }

    const destination_indent = sequenceIndent(plan.ours, ours_sequence) orelse
        (sequenceFieldIndent(plan.ours, ours_sequence) orelse return error.UnsupportedStructure);
    const merged_bytes = try renderHierarchySequence(
        arena,
        plan,
        order_operation,
        ours_sequence,
        order.items,
        choices.items,
        destination_indent,
    );
    const replacement = try merge_planner.sequenceReplacement(arena, plan.ours, ours_sequence, merged_bytes);
    var ours_value = order_operation.values.ours orelse return error.UnsupportedStructure;
    if (order.items.len == 0 and ours_sequence.seq.len != 0) {
        const entry = plan.ours.entry_spans.get(ours_sequence) orelse return error.UnsupportedStructure;
        const span = plan.ours.node_spans.get(ours_sequence) orelse return error.UnsupportedStructure;
        ours_value.span = .{ .start = entry.value.start, .end = span.end };
        ours_value.bytes = ours_value.span.?.bytes(plan.ours.bytes);
    }
    const patch_span = ours_value.span orelse return error.UnsupportedStructure;
    if (std.mem.eql(u8, patch_span.bytes(plan.ours.bytes), replacement)) return;
    try patches.append(arena, .{
        .span = patch_span,
        .replacement = replacement,
        .atomic_id = order_operation.atomic_id,
        .order = order_operation.id,
    });
}

fn effectiveHierarchyChoice(
    operation: *const merge_model.Operation,
    atomic_kind: merge_model.OperationKind,
) merge_model.Error!?SelectedValue {
    return switch (operation.resolution) {
        .unresolved => switch (atomic_kind) {
            .game_object => if (operation.values.base) |value| .{ .side = .base, .value = value } else null,
            .reparent => if (operation.values.ours) |value| .{ .side = .ours, .value = value } else null,
            else => return error.InvalidMerge,
        },
        .remove => null,
        .take => |side| if (valueForSide(operation, side)) |value|
            .{ .side = side, .value = value }
        else
            null,
        .custom => error.InvalidResolution,
    };
}

fn hierarchyOrder(arena: std.mem.Allocator, bytes: []const u8) merge_model.Error![]const i64 {
    var wrapped: std.ArrayList(u8) = .empty;
    try wrapped.appendSlice(arena, "--- !u!4 &1\nTransform:\n  m_Children:");
    const trimmed = std.mem.trimStart(u8, bytes, " ");
    if (std.mem.startsWith(u8, trimmed, "[")) {
        try wrapped.appendSlice(arena, " ");
        try wrapped.appendSlice(arena, trimmed);
        if (!std.mem.endsWith(u8, trimmed, "\n")) try wrapped.appendSlice(arena, "\n");
    } else {
        try wrapped.appendSlice(arena, "\n");
        try wrapped.appendSlice(arena, bytes);
    }
    const parsed = try parser.parseSpanned(arena, wrapped.items);
    if (parsed.diagnostics.len != 0 or parsed.documents.len != 1) return error.UnsupportedStructure;
    const sequence = model.findValue(parsed.documents[0].body.map, "m_Children") orelse
        return error.UnsupportedStructure;
    if (sequence.* != .seq) return error.UnsupportedStructure;
    var result: std.ArrayList(i64) = .empty;
    for (sequence.seq) |item| {
        const file_id = hierarchyFileId(item) orelse return error.UnsupportedStructure;
        if (containsComponentId(result.items, file_id)) return error.InvalidMerge;
        try result.append(arena, file_id);
    }
    return result.toOwnedSlice(arena);
}

fn insertHierarchyId(
    arena: std.mem.Allocator,
    order: *std.ArrayList(i64),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    selected_side: merge_model.Side,
    file_id: i64,
) merge_model.Error!void {
    const selected_file = fileForSide(plan, selected_side);
    const selected_sequence = findSequence(selected_file, operation) orelse return error.UnsupportedStructure;
    if (selected_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_index = for (selected_sequence.seq, 0..) |item, index| {
        if (hierarchyFileId(item) == file_id) break index;
    } else return error.UnsupportedStructure;
    for (selected_sequence.seq[selected_index + 1 ..]) |next| {
        const next_id = hierarchyFileId(next) orelse return error.UnsupportedStructure;
        if (componentIndex(order.items, next_id)) |index| {
            try order.insert(arena, index, file_id);
            return;
        }
    }
    try order.append(arena, file_id);
}

fn renderHierarchySequence(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    ours_sequence: *const model.Node,
    order: []const i64,
    choices: []const SequenceChoice,
    destination_indent: usize,
) merge_model.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (order) |file_id| {
        const selected = hierarchyItem(plan, operation, choices, file_id) orelse
            return error.UnsupportedStructure;
        if (selected.side == .ours) {
            try output.appendSlice(arena, selected.value.bytes);
            try appendOursHierarchyGap(arena, &output, plan.ours, ours_sequence, file_id);
        } else {
            try output.appendSlice(arena, try merge_planner.reindentSequenceItem(
                arena,
                selected.value.bytes,
                destination_indent,
                plan.ours.lineEndingAt((operation.values.ours orelse return error.UnsupportedStructure).span.?.start),
            ));
        }
    }
    return output.toOwnedSlice(arena);
}

fn hierarchyItem(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    choices: []const SequenceChoice,
    file_id: i64,
) ?SelectedValue {
    for (choices) |choice| if (choice.file_id == file_id) return choice.selected;
    for ([_]merge_model.Side{ .ours, .base, .theirs }) |side| {
        const file = fileForSide(plan, side);
        const sequence = findSequence(file, operation) orelse continue;
        if (sequence.* != .seq) continue;
        const item = findHierarchyItem(sequence.seq, file_id) orelse continue;
        const span = file.sequence_item_spans.get(item) orelse continue;
        return .{
            .side = side,
            .value = .{ .node = item, .bytes = span.bytes(file.bytes), .span = span },
        };
    }
    return null;
}

fn hierarchyFileId(item: *const model.Node) ?i64 {
    if (item.* != .ref or item.ref.guid != null) return null;
    return item.ref.file_id;
}

fn findHierarchyItem(items: []const *model.Node, file_id: i64) ?*const model.Node {
    for (items) |item| if (hierarchyFileId(item) == file_id) return item;
    return null;
}

fn appendOursHierarchyGap(
    arena: std.mem.Allocator,
    output: *std.ArrayList(u8),
    file: source.ParsedFile,
    sequence: *const model.Node,
    file_id: i64,
) merge_model.Error!void {
    const ours_index = for (sequence.seq, 0..) |item, index| {
        if (hierarchyFileId(item) == file_id) break index;
    } else return;
    if (ours_index + 1 == sequence.seq.len) return;
    const current_span = file.sequence_item_spans.get(sequence.seq[ours_index]) orelse
        return error.UnsupportedStructure;
    const next_item = sequence.seq[ours_index + 1];
    const next_span = file.sequence_item_spans.get(next_item) orelse return error.UnsupportedStructure;
    if (next_span.start < current_span.end) return error.UnsupportedStructure;
    try output.appendSlice(arena, file.bytes[current_span.end..next_span.start]);
}

const SequenceChoice = struct {
    file_id: i64,
    selected: ?SelectedValue,
};

const PrefabChoice = struct {
    id: []const u8,
    selected: ?SelectedValue,
};

fn appendComposedPrefabSequencePatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    order_operation: *const merge_model.Operation,
) merge_model.Error!void {
    const kind = merge_identity.sequenceKind(
        order_operation.identity.document.class_id,
        order_operation.property_path,
    ) orelse return error.UnsupportedStructure;
    const ours_sequence = findSequence(plan.ours, order_operation) orelse
        return error.UnsupportedStructure;
    if (ours_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_order = switch (order_operation.resolution) {
        .unresolved => if (order_operation.values.ours) |value|
            SelectedValue{ .side = .ours, .value = value }
        else
            return error.InvalidResolution,
        .take => |side| SelectedValue{
            .side = side,
            .value = valueForSide(order_operation, side) orelse return error.InvalidResolution,
        },
        .remove, .custom => return error.InvalidResolution,
    };
    var order: std.ArrayList([]const u8) = .empty;
    try order.appendSlice(arena, try prefabOrder(arena, selected_order.value.bytes, kind));
    var choices: std.ArrayList(PrefabChoice) = .empty;
    for (plan.operations) |*operation| {
        if (operation.kind != .prefab_override or
            operation.identity.document.class_id != order_operation.identity.document.class_id or
            operation.identity.document.file_id != order_operation.identity.document.file_id or
            !std.mem.eql(u8, operation.property_path, order_operation.property_path)) continue;
        const id = try prefabOperationId(arena, operation, kind);
        const selected = try effectivePrefabChoice(operation);
        try choices.append(arena, .{ .id = id, .selected = selected });
        if (selected == null) {
            removePrefabId(&order, id);
        } else if (!containsPrefabId(order.items, id)) {
            try insertPrefabId(
                arena,
                &order,
                plan,
                order_operation,
                selected.?.side,
                id,
                kind,
            );
        }
    }

    const destination_indent = sequenceIndent(plan.ours, ours_sequence) orelse
        (sequenceFieldIndent(plan.ours, ours_sequence) orelse return error.UnsupportedStructure);
    const merged_bytes = try renderPrefabSequence(
        arena,
        plan,
        order_operation,
        ours_sequence,
        order.items,
        choices.items,
        destination_indent,
        kind,
    );
    const replacement = try merge_planner.sequenceReplacement(
        arena,
        plan.ours,
        ours_sequence,
        merged_bytes,
    );
    var ours_value = order_operation.values.ours orelse return error.UnsupportedStructure;
    if (order.items.len == 0 and ours_sequence.seq.len != 0) {
        const entry = plan.ours.entry_spans.get(ours_sequence) orelse
            return error.UnsupportedStructure;
        const span = plan.ours.node_spans.get(ours_sequence) orelse
            return error.UnsupportedStructure;
        ours_value.span = .{ .start = entry.value.start, .end = span.end };
        ours_value.bytes = ours_value.span.?.bytes(plan.ours.bytes);
    }
    const patch_span = ours_value.span orelse return error.UnsupportedStructure;
    if (std.mem.eql(u8, patch_span.bytes(plan.ours.bytes), replacement)) return;
    try patches.append(arena, .{
        .span = patch_span,
        .replacement = replacement,
        .atomic_id = order_operation.atomic_id,
        .order = order_operation.id,
    });
}

fn effectivePrefabChoice(operation: *const merge_model.Operation) merge_model.Error!?SelectedValue {
    return switch (operation.resolution) {
        .unresolved => if (operation.values.base) |value| .{ .side = .base, .value = value } else null,
        .remove => null,
        .take => |side| if (valueForSide(operation, side)) |value|
            .{ .side = side, .value = value }
        else
            null,
        .custom => error.InvalidResolution,
    };
}

fn prefabOrder(
    arena: std.mem.Allocator,
    bytes: []const u8,
    kind: merge_identity.SequenceKind,
) merge_model.Error![]const []const u8 {
    var wrapped: std.ArrayList(u8) = .empty;
    try wrapped.appendSlice(arena, "--- !u!1001 &1\nPrefabInstance:\n  m_Modification:\n    ");
    try wrapped.appendSlice(arena, prefabField(kind));
    try wrapped.append(arena, ':');
    const trimmed = std.mem.trimStart(u8, bytes, " ");
    if (std.mem.startsWith(u8, trimmed, "[")) {
        try wrapped.append(arena, ' ');
        try wrapped.appendSlice(arena, trimmed);
        if (!std.mem.endsWith(u8, trimmed, "\n")) try wrapped.append(arena, '\n');
    } else {
        try wrapped.append(arena, '\n');
        try wrapped.appendSlice(arena, bytes);
    }
    const parsed = try parser.parseSpanned(arena, wrapped.items);
    if (parsed.diagnostics.len != 0 or parsed.documents.len != 1) return error.UnsupportedStructure;
    const modification = model.findValue(parsed.documents[0].body.map, "m_Modification") orelse
        return error.UnsupportedStructure;
    if (modification.* != .map) return error.UnsupportedStructure;
    const sequence = model.findValue(modification.map, prefabField(kind)) orelse
        return error.UnsupportedStructure;
    if (sequence.* != .seq) return error.UnsupportedStructure;
    var result: std.ArrayList([]const u8) = .empty;
    for (sequence.seq) |item| {
        const id = try prefabItemId(arena, kind, item);
        if (containsPrefabId(result.items, id)) return error.InvalidMerge;
        try result.append(arena, id);
    }
    return result.toOwnedSlice(arena);
}

fn prefabField(kind: merge_identity.SequenceKind) []const u8 {
    return switch (kind) {
        .prefab_properties => "m_Modifications",
        .prefab_added_components => "m_AddedComponents",
        .prefab_removed_components => "m_RemovedComponents",
        .prefab_added_game_objects => "m_AddedGameObjects",
        .prefab_removed_game_objects => "m_RemovedGameObjects",
        .components, .children => unreachable,
    };
}

fn prefabOperationId(
    arena: std.mem.Allocator,
    operation: *const merge_model.Operation,
    kind: merge_identity.SequenceKind,
) merge_model.Error![]const u8 {
    for ([_]?merge_model.SideValue{
        operation.values.base,
        operation.values.ours,
        operation.values.theirs,
    }) |value| {
        const present = value orelse continue;
        const item = present.node orelse continue;
        return prefabItemId(arena, kind, item);
    }
    return error.InvalidMerge;
}

fn prefabItemId(
    arena: std.mem.Allocator,
    kind: merge_identity.SequenceKind,
    item: *const model.Node,
) merge_model.Error![]const u8 {
    const identity = merge_identity.sequenceItemId(kind, item) orelse
        return error.UnsupportedStructure;
    return merge_planner.sequenceId(arena, identity);
}

fn removePrefabId(order: *std.ArrayList([]const u8), id: []const u8) void {
    for (order.items, 0..) |candidate, index| {
        if (!std.mem.eql(u8, candidate, id)) continue;
        _ = order.orderedRemove(index);
        return;
    }
}

fn containsPrefabId(order: []const []const u8, id: []const u8) bool {
    for (order) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn prefabIndex(order: []const []const u8, id: []const u8) ?usize {
    for (order, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, id)) return index;
    }
    return null;
}

fn insertPrefabId(
    arena: std.mem.Allocator,
    order: *std.ArrayList([]const u8),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    selected_side: merge_model.Side,
    id: []const u8,
    kind: merge_identity.SequenceKind,
) merge_model.Error!void {
    const selected_file = fileForSide(plan, selected_side);
    const selected_sequence = findSequence(selected_file, operation) orelse
        return error.UnsupportedStructure;
    if (selected_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_index = for (selected_sequence.seq, 0..) |item, index| {
        const candidate = try prefabItemId(arena, kind, item);
        if (std.mem.eql(u8, candidate, id)) break index;
    } else return error.UnsupportedStructure;
    for (selected_sequence.seq[selected_index + 1 ..]) |next| {
        const next_id = try prefabItemId(arena, kind, next);
        if (prefabIndex(order.items, next_id)) |index| {
            try order.insert(arena, index, id);
            return;
        }
    }
    try order.append(arena, id);
}

fn renderPrefabSequence(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    ours_sequence: *const model.Node,
    order: []const []const u8,
    choices: []const PrefabChoice,
    destination_indent: usize,
    kind: merge_identity.SequenceKind,
) merge_model.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (order) |id| {
        const selected = try prefabItem(arena, plan, operation, choices, id, kind) orelse
            return error.UnsupportedStructure;
        if (selected.side == .ours) {
            try output.appendSlice(arena, selected.value.bytes);
        } else {
            try output.appendSlice(arena, try merge_planner.reindentSequenceItem(
                arena,
                selected.value.bytes,
                destination_indent,
                plan.ours.lineEndingAt(
                    (operation.values.ours orelse return error.UnsupportedStructure).span.?.start,
                ),
            ));
        }
        try appendOursPrefabGap(arena, &output, plan.ours, ours_sequence, id, kind);
    }
    return output.toOwnedSlice(arena);
}

fn prefabItem(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    choices: []const PrefabChoice,
    id: []const u8,
    kind: merge_identity.SequenceKind,
) merge_model.Error!?SelectedValue {
    for (choices) |choice| {
        if (std.mem.eql(u8, choice.id, id)) return choice.selected;
    }
    for ([_]merge_model.Side{ .ours, .base, .theirs }) |side| {
        const file = fileForSide(plan, side);
        const sequence = findSequence(file, operation) orelse continue;
        if (sequence.* != .seq) continue;
        for (sequence.seq) |item| {
            const candidate = try prefabItemId(arena, kind, item);
            if (!std.mem.eql(u8, candidate, id)) continue;
            const span = file.sequence_item_spans.get(item) orelse
                return error.UnsupportedStructure;
            return .{
                .side = side,
                .value = .{ .node = item, .bytes = span.bytes(file.bytes), .span = span },
            };
        }
    }
    return null;
}

fn appendOursPrefabGap(
    arena: std.mem.Allocator,
    output: *std.ArrayList(u8),
    file: source.ParsedFile,
    sequence: *const model.Node,
    id: []const u8,
    kind: merge_identity.SequenceKind,
) merge_model.Error!void {
    const ours_index = for (sequence.seq, 0..) |item, index| {
        const candidate = try prefabItemId(arena, kind, item);
        if (std.mem.eql(u8, candidate, id)) break index;
    } else return;
    if (ours_index + 1 == sequence.seq.len) return;
    const current_span = file.sequence_item_spans.get(sequence.seq[ours_index]) orelse
        return error.UnsupportedStructure;
    const next_item = sequence.seq[ours_index + 1];
    const next_span = file.sequence_item_spans.get(next_item) orelse
        return error.UnsupportedStructure;
    if (next_span.start < current_span.end) return error.UnsupportedStructure;
    try output.appendSlice(arena, file.bytes[current_span.end..next_span.start]);
}

fn appendComposedComponentSequencePatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    order_operation: *const merge_model.Operation,
) merge_model.Error!void {
    const ours_sequence = findSequence(plan.ours, order_operation) orelse return error.UnsupportedStructure;
    if (ours_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_order = switch (order_operation.resolution) {
        .unresolved => if (order_operation.values.ours) |value|
            SelectedValue{ .side = .ours, .value = value }
        else
            return error.InvalidResolution,
        .take => |side| SelectedValue{
            .side = side,
            .value = valueForSide(order_operation, side) orelse return error.InvalidResolution,
        },
        .remove => return error.InvalidResolution,
        .custom => return error.InvalidResolution,
    };
    var order: std.ArrayList(i64) = .empty;
    try order.appendSlice(arena, try componentOrder(arena, selected_order.value.bytes));
    var choices: std.ArrayList(SequenceChoice) = .empty;
    for (plan.operations) |*operation| {
        if (operation.kind != .sequence_membership or
            operation.identity.document.class_id != order_operation.identity.document.class_id or
            operation.identity.document.file_id != order_operation.identity.document.file_id or
            !std.mem.eql(u8, operation.property_path, order_operation.property_path)) continue;
        const atomic = atomicByIdConst(plan, operation.atomic_id) orelse return error.InvalidMerge;
        if (atomic.kind != .component) continue;
        const file_id = (operation.identity.item_ref orelse return error.InvalidMerge).file_id;
        const selected = try effectiveComponentChoice(operation);
        try choices.append(arena, .{ .file_id = file_id, .selected = selected });
        if (selected == null) {
            removeComponentId(&order, file_id);
        } else if (!containsComponentId(order.items, file_id)) {
            try insertComponentId(arena, &order, plan, order_operation, selected.?.side, file_id);
        }
    }

    const destination_indent = sequenceIndent(plan.ours, ours_sequence) orelse
        (sequenceFieldIndent(plan.ours, ours_sequence) orelse return error.UnsupportedStructure);
    const merged_bytes = try renderComponentSequence(
        arena,
        plan,
        order_operation,
        ours_sequence,
        order.items,
        choices.items,
        destination_indent,
    );
    const replacement = try merge_planner.sequenceReplacement(arena, plan.ours, ours_sequence, merged_bytes);
    var ours_value = order_operation.values.ours orelse return error.UnsupportedStructure;
    if (order.items.len == 0 and ours_sequence.seq.len != 0) {
        const entry = plan.ours.entry_spans.get(ours_sequence) orelse return error.UnsupportedStructure;
        const span = plan.ours.node_spans.get(ours_sequence) orelse return error.UnsupportedStructure;
        ours_value.span = .{ .start = entry.value.start, .end = span.end };
        ours_value.bytes = ours_value.span.?.bytes(plan.ours.bytes);
    }
    const patch_span = ours_value.span orelse return error.UnsupportedStructure;
    if (std.mem.eql(u8, patch_span.bytes(plan.ours.bytes), replacement)) return;
    try patches.append(arena, .{
        .span = patch_span,
        .replacement = replacement,
        .atomic_id = order_operation.atomic_id,
        .order = order_operation.id,
    });
}

fn effectiveComponentChoice(operation: *const merge_model.Operation) merge_model.Error!?SelectedValue {
    return switch (operation.resolution) {
        .unresolved => if (operation.values.base) |value| .{ .side = .base, .value = value } else null,
        .remove => null,
        .take => |side| if (valueForSide(operation, side)) |value|
            .{ .side = side, .value = value }
        else
            null,
        .custom => error.InvalidResolution,
    };
}

fn componentOrder(arena: std.mem.Allocator, bytes: []const u8) merge_model.Error![]const i64 {
    var wrapped: std.ArrayList(u8) = .empty;
    try wrapped.appendSlice(arena, "--- !u!1 &1\nGameObject:\n  m_Component:");
    const trimmed = std.mem.trimStart(u8, bytes, " ");
    if (std.mem.startsWith(u8, trimmed, "[")) {
        try wrapped.appendSlice(arena, " ");
        try wrapped.appendSlice(arena, trimmed);
        if (!std.mem.endsWith(u8, trimmed, "\n")) try wrapped.appendSlice(arena, "\n");
    } else {
        try wrapped.appendSlice(arena, "\n");
        try wrapped.appendSlice(arena, bytes);
    }
    const parsed = try parser.parseSpanned(arena, wrapped.items);
    if (parsed.diagnostics.len != 0 or parsed.documents.len != 1) return error.UnsupportedStructure;
    const sequence = model.findValue(parsed.documents[0].body.map, "m_Component") orelse
        return error.UnsupportedStructure;
    if (sequence.* != .seq) return error.UnsupportedStructure;
    var result: std.ArrayList(i64) = .empty;
    for (sequence.seq) |item| {
        const file_id = componentFileId(item) orelse return error.UnsupportedStructure;
        if (containsComponentId(result.items, file_id)) return error.InvalidMerge;
        try result.append(arena, file_id);
    }
    return result.toOwnedSlice(arena);
}

fn removeComponentId(order: *std.ArrayList(i64), file_id: i64) void {
    for (order.items, 0..) |candidate, index| {
        if (candidate != file_id) continue;
        _ = order.orderedRemove(index);
        return;
    }
}

fn containsComponentId(order: []const i64, file_id: i64) bool {
    for (order) |candidate| if (candidate == file_id) return true;
    return false;
}

fn componentIndex(order: []const i64, file_id: i64) ?usize {
    for (order, 0..) |candidate, index| if (candidate == file_id) return index;
    return null;
}

fn insertComponentId(
    arena: std.mem.Allocator,
    order: *std.ArrayList(i64),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    selected_side: merge_model.Side,
    file_id: i64,
) merge_model.Error!void {
    const selected_file = fileForSide(plan, selected_side);
    const selected_sequence = findSequence(selected_file, operation) orelse return error.UnsupportedStructure;
    if (selected_sequence.* != .seq) return error.UnsupportedStructure;
    const selected_index = for (selected_sequence.seq, 0..) |item, index| {
        if (componentFileId(item) == file_id) break index;
    } else return error.UnsupportedStructure;
    for (selected_sequence.seq[selected_index + 1 ..]) |next| {
        const next_id = componentFileId(next) orelse return error.UnsupportedStructure;
        if (componentIndex(order.items, next_id)) |index| {
            try order.insert(arena, index, file_id);
            return;
        }
    }
    try order.append(arena, file_id);
}

fn renderComponentSequence(
    arena: std.mem.Allocator,
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    ours_sequence: *const model.Node,
    order: []const i64,
    choices: []const SequenceChoice,
    destination_indent: usize,
) merge_model.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (order) |file_id| {
        const selected = componentItem(plan, operation, choices, file_id) orelse
            return error.UnsupportedStructure;
        if (selected.side == .ours) {
            try output.appendSlice(arena, selected.value.bytes);
            try appendOursComponentGap(arena, &output, plan.ours, ours_sequence, file_id);
        } else {
            try output.appendSlice(arena, try merge_planner.reindentSequenceItem(
                arena,
                selected.value.bytes,
                destination_indent,
                plan.ours.lineEndingAt((operation.values.ours orelse return error.UnsupportedStructure).span.?.start),
            ));
        }
    }
    return output.toOwnedSlice(arena);
}

fn componentItem(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    choices: []const SequenceChoice,
    file_id: i64,
) ?SelectedValue {
    for (choices) |choice| {
        if (choice.file_id == file_id) return choice.selected;
    }
    for ([_]merge_model.Side{ .ours, .base, .theirs }) |side| {
        const file = fileForSide(plan, side);
        const sequence = findSequence(file, operation) orelse continue;
        if (sequence.* != .seq) continue;
        const item = findComponentItem(sequence.seq, file_id) orelse continue;
        const span = file.sequence_item_spans.get(item) orelse continue;
        return .{
            .side = side,
            .value = .{ .node = item, .bytes = span.bytes(file.bytes), .span = span },
        };
    }
    return null;
}

fn appendOursComponentGap(
    arena: std.mem.Allocator,
    output: *std.ArrayList(u8),
    file: source.ParsedFile,
    sequence: *const model.Node,
    file_id: i64,
) merge_model.Error!void {
    const ours_index = for (sequence.seq, 0..) |item, index| {
        if (componentFileId(item) == file_id) break index;
    } else return;
    if (ours_index + 1 == sequence.seq.len) return;
    const current_span = file.sequence_item_spans.get(sequence.seq[ours_index]) orelse
        return error.UnsupportedStructure;
    const next_item = sequence.seq[ours_index + 1];
    const next_span = file.sequence_item_spans.get(next_item) orelse return error.UnsupportedStructure;
    if (next_span.start < current_span.end) return error.UnsupportedStructure;
    const gap = file.bytes[current_span.end..next_span.start];
    try output.appendSlice(arena, gap);
}

fn findSequence(file: source.ParsedFile, operation: *const merge_model.Operation) ?*const model.Node {
    for (file.documents) |*document| {
        if (document.class_id != operation.identity.document.class_id or
            document.file_id != operation.identity.document.file_id) continue;
        var node = document.body;
        var path = std.mem.splitScalar(u8, operation.property_path, '.');
        while (path.next()) |field| {
            if (node.* != .map) return null;
            node = model.findValue(node.map, field) orelse return null;
        }
        return node;
    }
    return null;
}

fn componentFileId(item: *const model.Node) ?i64 {
    if (item.* != .map) return null;
    const component = model.findValue(item.map, "component") orelse return null;
    if (component.* != .ref) return null;
    return component.ref.file_id;
}

fn findComponentItem(items: []const *model.Node, file_id: i64) ?*const model.Node {
    for (items) |item| if (componentFileId(item) == file_id) return item;
    return null;
}

fn sequenceIndent(file: source.ParsedFile, sequence: *const model.Node) ?usize {
    if (sequence.* != .seq or sequence.seq.len == 0) return null;
    const span = file.sequence_item_spans.get(sequence.seq[0]) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, file.bytes, span.start, '\n') orelse span.end;
    return leadingSpaces(file.bytes[span.start..end]);
}

fn sequenceFieldIndent(file: source.ParsedFile, sequence: *const model.Node) ?usize {
    const entry = file.entry_spans.get(sequence) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, file.bytes[0..entry.key.start], '\n')) |lf| lf + 1 else 0;
    return entry.key.start - line_start;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn appendDocumentPatch(
    arena: std.mem.Allocator,
    patches: *std.ArrayList(Patch),
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
) merge_model.Error!void {
    const selected = switch (operation.resolution) {
        .unresolved => return error.InvalidResolution,
        .remove => null,
        .take => |side| valueForSide(operation, side),
        .custom => return error.InvalidResolution,
    };
    if (operation.values.ours) |ours| {
        const span = ours.span orelse return error.UnsupportedStructure;
        const replacement = if (selected) |value| value.bytes else "";
        if (std.mem.eql(u8, span.bytes(plan.ours.bytes), replacement)) return;
        return patches.append(arena, .{
            .span = span,
            .replacement = replacement,
            .atomic_id = operation.atomic_id,
            .order = operation.id,
        });
    }
    const inserted = selected orelse return;
    const selected_side = switch (operation.resolution) {
        .take => |side| side,
        .unresolved, .remove, .custom => return error.InvalidResolution,
    };
    const insert_at = if (operation.kind == .game_object)
        documentInsertionOffset(plan, operation, selected_side)
    else
        plan.ours.bytes.len;
    try patches.append(arena, .{
        .span = .{ .start = insert_at, .end = insert_at },
        .replacement = inserted.bytes,
        .atomic_id = operation.atomic_id,
        .order = operation.id,
    });
}

fn documentInsertionOffset(
    plan: *const merge_model.MergePlan,
    operation: *const merge_model.Operation,
    selected_side: merge_model.Side,
) usize {
    const selected_file = fileForSide(plan, selected_side);
    const selected_index = for (selected_file.documents, 0..) |document, index| {
        if (document.class_id == operation.identity.document.class_id and
            document.file_id == operation.identity.document.file_id) break index;
    } else return plan.ours.bytes.len;
    for (selected_file.documents[selected_index + 1 ..]) |next| {
        for (plan.ours.documents, plan.ours.document_spans) |ours_document, ours_span| {
            if (ours_document.class_id == next.class_id and ours_document.file_id == next.file_id) {
                return ours_span.whole.start;
            }
        }
    }
    return plan.ours.bytes.len;
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

test "merge apply: keeps the declared order of inserts at one offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const patches = [_]Patch{
        .{ .span = .{ .start = 0, .end = 0 }, .replacement = "a", .atomic_id = 1, .order = 1 },
        .{ .span = .{ .start = 0, .end = 0 }, .replacement = "b", .atomic_id = 1, .order = 2 },
    };

    try testing.expectEqualStrings("ab", try applyPatches(arena_state.allocator(), "", &patches));
}

fn threeFieldPlan(arena: std.mem.Allocator) !merge_model.MergePlan {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  first: 0\n  second: 0\n  third: 0\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  first: 1\n  second: 1\n  third: 1\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  first: 2\n  second: 2\n  third: 2\n";
    return merge_planner.build(
        arena,
        try merge_planner.parseMergeSide(arena, base),
        try merge_planner.parseMergeSide(arena, ours),
        try merge_planner.parseMergeSide(arena, theirs),
    );
}

test "merge apply: follows a two-hop dependency in partial and final modes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan = try threeFieldPlan(arena);
    plan.operations[0].resolution = .{ .take = .theirs };
    plan.operations[1].resolution = .{ .take = .theirs };
    plan.atomic_operations[0].dependencies = try arena.dupe(merge_model.AtomicId, &.{1});
    plan.operations[1].dependencies = try arena.dupe(merge_model.AtomicId, &.{2});

    try testing.expectEqualStrings(plan.ours.bytes, try applyResolved(arena, &plan, false));
    try testing.expectError(error.InvalidResolution, applyResolved(arena, &plan, true));
}

test "merge apply: rejects a missing dependency identifier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan = try threeFieldPlan(arena);
    plan.atomic_operations[0].dependencies = try arena.dupe(merge_model.AtomicId, &.{99});

    try testing.expectError(error.InvalidMerge, applyResolved(arena, &plan, false));
}

test "merge apply: rejects a dependency cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan = try threeFieldPlan(arena);
    plan.operations[0].resolution = .{ .take = .theirs };
    plan.operations[1].resolution = .{ .take = .theirs };
    plan.atomic_operations[0].dependencies = try arena.dupe(merge_model.AtomicId, &.{1});
    plan.atomic_operations[1].dependencies = try arena.dupe(merge_model.AtomicId, &.{0});

    try testing.expectError(error.InvalidMerge, applyResolved(arena, &plan, false));
}
