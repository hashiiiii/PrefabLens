const std = @import("std");
const merge_apply = @import("merge_apply.zig");
const merge_model = @import("merge_model.zig");
const merge_planner = @import("merge_planner.zig");
const merge_validate = @import("merge_validate.zig");
const model = @import("model.zig");
const source = @import("source.zig");

const testing = std.testing;

pub const Error = merge_model.Error;
pub const MergePlan = merge_model.MergePlan;
pub const Operation = merge_model.Operation;
pub const OperationId = merge_model.OperationId;
pub const Resolution = merge_model.Resolution;
pub const Side = merge_model.Side;
pub const SideValue = merge_model.SideValue;
pub const properties = @import("merge_properties.zig");

pub const BuildResult = struct {
    plan: MergePlan,
    partial: []const u8,
};

pub fn build(
    arena: std.mem.Allocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
) Error!BuildResult {
    return buildWithContext(arena, base, ours, theirs, .{});
}

pub fn buildWithContext(arena: std.mem.Allocator, base: []const u8, ours: []const u8, theirs: []const u8, context: @import("merge_context.zig").Context) Error!BuildResult {
    const parsed_base = try merge_planner.parseMergeSide(arena, base);
    const parsed_ours = try merge_planner.parseMergeSide(arena, ours);
    const parsed_theirs = try merge_planner.parseMergeSide(arena, theirs);
    var plan = try merge_planner.buildSemanticWithContext(arena, parsed_base, parsed_ours, parsed_theirs, context);
    try verifyTheirsCoverage(arena, parsed_base, parsed_ours, parsed_theirs, context);
    try verifyOursDocumentCoverage(&plan);
    const partial = try merge_apply.applyResolved(arena, &plan, false);
    try merge_validate.validate(arena, partial);
    return .{
        .plan = plan,
        .partial = partial,
    };
}

fn verifyTheirsCoverage(
    arena: std.mem.Allocator,
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    context: @import("merge_context.zig").Context,
) Error!void {
    if (std.mem.eql(u8, ours.bytes, theirs.bytes)) return;

    var replay = try merge_planner.buildSemanticWithContext(arena, base, base, theirs, .{ .base = context.base, .ours = context.base, .theirs = context.theirs, .output = context.theirs });
    // Coverage checks reachability of Theirs bytes, including explicit context choices.
    for (replay.operations) |*operation| {
        if (operation.collection != null and operation.resolution == .unresolved) operation.resolution = .{ .take = .theirs };
    }
    if (replay.unresolvedCount() != 0) return error.UnsupportedStructure;
    const replayed = try merge_apply.applyResolved(arena, &replay, false);
    if (!std.mem.eql(u8, replayed, theirs.bytes)) return error.UnsupportedStructure;
}

fn verifyOursDocumentCoverage(plan: *const MergePlan) Error!void {
    for (plan.operations) |*operation| {
        switch (operation.kind) {
            .document, .component, .game_object => {},
            else => continue,
        }
        const ours = operation.values.ours orelse continue;
        const selected = switch (operation.resolution) {
            .unresolved => continue,
            .remove => null,
            .take => |side| operation.values.get(side),
            .custom => return error.InvalidMerge,
        };
        if (selected) |value| {
            if (std.mem.eql(u8, ours.bytes, value.bytes)) continue;
        }
        const base = operation.values.base orelse return error.UnsupportedStructure;
        if (!std.mem.eql(u8, ours.bytes, base.bytes)) return error.UnsupportedStructure;
    }
}

pub fn resolve(
    arena: std.mem.Allocator,
    plan: *MergePlan,
    operation_id: OperationId,
    resolution: Resolution,
) Error!void {
    const operation = merge_model.operationById(plan, operation_id) orelse
        return error.InvalidResolution;
    const atomic = merge_model.atomicById(plan, operation.atomic_id) orelse
        return error.InvalidResolution;
    var stored_resolution = resolution;
    var component_custom: ?ComponentCustom = null;
    switch (resolution) {
        .unresolved => return error.InvalidResolution,
        .take => |side| if (side == .base or operation.values.get(side) == null)
            return error.InvalidResolution,
        .custom => |value| {
            if (atomic.kind == .component and
                (operation.kind == .sequence_membership or operation.kind == .component))
            {
                component_custom = try validateComponentCustom(arena, plan, operation, atomic, value);
            } else if (operation.collection) |binding_ref| {
                const parsed = @import("merge_yaml.zig").parseValue(arena, value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidResolution,
                };
                const conflict = plan.collections[binding_ref.binding].plan.conflicts[binding_ref.conflict];
                if (conflict.sequence and parsed.* != .seq) return error.InvalidResolution;
            } else {
                const supports_custom_kind = operation.kind == .field or
                    (operation.kind == .prefab_override and operation.item_path != null);
                if (!supports_custom_kind or atomic.operation_ids.len != 1 or
                    !supportsCustomValue(operation) or !wasConflict(operation)) return error.InvalidResolution;
                _ = try merge_apply.parseCustomValue(arena, value);
            }
            stored_resolution = .{ .custom = try arena.dupe(u8, value) };
        },
        .remove => {},
    }
    const previous = try arena.alloc(merge_model.Resolution, atomic.operation_ids.len);
    for (atomic.operation_ids) |id| {
        const member = merge_model.operationById(plan, id) orelse
            return error.InvalidResolution;
        if (member.atomic_id != atomic.id) return error.InvalidResolution;
    }
    for (atomic.operation_ids, previous) |id, *old_resolution| {
        const member = merge_model.operationById(plan, id).?;
        old_resolution.* = member.resolution;
        if (component_custom) |custom| {
            if (member.id == custom.membership_id) {
                member.resolution = .{ .take = custom.membership_side };
            } else if (member.id == custom.document_id) {
                member.resolution = stored_resolution;
            } else {
                return error.InvalidResolution;
            }
        } else {
            member.resolution = stored_resolution;
        }
    }
    errdefer {
        for (atomic.operation_ids, previous) |id, old_resolution| {
            merge_model.operationById(plan, id).?.resolution = old_resolution;
        }
    }
    if (operation.collection) |reference| {
        try @import("merge_binding.zig").validateSelection(arena, plan, reference);
    }
    const candidate = try merge_apply.applyResolved(arena, plan, false);
    merge_validate.validate(arena, candidate) catch |validation_error| switch (validation_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
}

const ComponentCustom = struct {
    membership_id: OperationId,
    document_id: OperationId,
    membership_side: Side,
};

fn validateComponentCustom(
    arena: std.mem.Allocator,
    plan: *const MergePlan,
    operation: *const Operation,
    atomic: *const merge_model.AtomicOperation,
    value: []const u8,
) Error!ComponentCustom {
    var membership: ?*const Operation = null;
    var document: ?*const Operation = null;
    for (atomic.operation_ids) |member_id| {
        const member = merge_model.operationByIdConst(plan, member_id) orelse
            return error.InvalidResolution;
        switch (member.kind) {
            .sequence_membership => {
                if (membership != null) return error.InvalidResolution;
                membership = member;
            },
            .component => {
                if (document != null) return error.InvalidResolution;
                document = member;
            },
            else => return error.InvalidResolution,
        }
    }
    const membership_operation = membership orelse return error.InvalidResolution;
    const document_operation = document orelse return error.InvalidResolution;
    if (atomic.operation_ids.len != 2) return error.InvalidResolution;
    if (operation.id != membership_operation.id and operation.id != document_operation.id)
        return error.InvalidResolution;
    const membership_side = componentMembershipSide(membership_operation);
    if (membership_operation.values.get(membership_side) == null or
        document_operation.values.get(membership_side) == null)
        return error.InvalidResolution;
    const selected_document = componentDocument(plan, document_operation, membership_side) orelse
        return error.InvalidResolution;

    const parsed = merge_planner.parseMergeSide(arena, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    if (parsed.documents.len != 1) return error.InvalidResolution;
    const custom_document = parsed.documents[0];
    if (custom_document.class_id != document_operation.identity.document.class_id or
        custom_document.file_id != document_operation.identity.document.file_id or
        !std.mem.eql(u8, custom_document.type_name, selected_document.type_name) or
        custom_document.stripped != selected_document.stripped)
        return error.InvalidResolution;
    const owner = custom_document.body.get("m_GameObject") orelse
        return error.InvalidResolution;
    if (owner.* != .ref or owner.ref.guid != null or
        owner.ref.file_id != membership_operation.identity.document.file_id)
        return error.InvalidResolution;

    return .{
        .membership_id = membership_operation.id,
        .document_id = document_operation.id,
        .membership_side = membership_side,
    };
}

fn componentDocument(
    plan: *const MergePlan,
    operation: *const Operation,
    side: Side,
) ?*const model.Document {
    const id = operation.identity.document;
    for (plan.file(side).documents) |*document| {
        if (document.class_id == id.class_id and document.file_id == id.file_id) return document;
    }
    return null;
}

fn componentMembershipSide(operation: *const Operation) Side {
    switch (operation.resolution) {
        .take => |side| if (operation.values.get(side) != null) return side,
        else => {},
    }
    if (operation.values.ours != null) return .ours;
    if (operation.values.theirs != null) return .theirs;
    return .base;
}

pub const CollectionConflict = struct { reason: @import("merge_value.zig").Reason, both_orders: bool };
pub fn collectionConflict(plan: *const MergePlan, operation_id: OperationId) ?CollectionConflict {
    const operation = merge_model.operationByIdConst(plan, operation_id) orelse return null;
    const ref = operation.collection orelse return null;
    const collection = plan.collections[ref.binding];
    const conflict = collection.plan.conflicts[ref.conflict];
    return .{ .reason = conflict.reason, .both_orders = offersBothOrders(collection.plan, conflict) };
}
fn offersBothOrders(plan: @import("merge_value.zig").Plan, conflict: @import("merge_value.zig").Conflict) bool {
    if (conflict.reason != .insertion_order) return false;
    if (plan.input.schema) |schema| return schema.kind != .dictionary;
    return switch (@import("merge_dictionary.zig").detect(conflict.nodes.base, conflict.nodes.ours, conflict.nodes.theirs)) {
        .shape => false,
        else => true,
    };
}
pub fn combinedCollectionValue(arena: std.mem.Allocator, plan: *const MergePlan, operation_id: OperationId, order: @import("merge_value.zig").Order) Error![]const u8 {
    const operation = merge_model.operationByIdConst(plan, operation_id) orelse return error.InvalidResolution;
    const ref = operation.collection orelse return error.InvalidResolution;
    const combined = @import("merge_value.zig").combined(arena, plan.collections[ref.binding].plan.conflicts[ref.conflict], order) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    return @import("merge_yaml.zig").flow(arena, combined) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
}
pub fn supportsCustomResolution(plan: *const MergePlan, operation_id: OperationId) bool {
    const operation = merge_model.operationByIdConst(plan, operation_id) orelse return false;
    if (operation.collection != null) return true;
    const atomic = for (plan.atomic_operations) |*candidate| {
        if (candidate.id == operation.atomic_id) break candidate;
    } else return false;
    if (atomic.kind == .component and
        (operation.kind == .sequence_membership or operation.kind == .component))
        return true;
    return (operation.kind == .field or (operation.kind == .prefab_override and operation.item_path != null)) and supportsCustomValue(operation) and wasConflict(operation);
}

fn supportsCustomValue(operation: *const Operation) bool {
    inline for (.{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
        if (value) |present| {
            const node = present.node orelse return false;
            if (node.* != .scalar and node.* != .ref) return false;
        }
    }
    return true;
}

fn wasConflict(operation: *const Operation) bool {
    return !equalOptionalValues(operation.values.ours, operation.values.base) and
        !equalOptionalValues(operation.values.theirs, operation.values.base) and
        !equalOptionalValues(operation.values.ours, operation.values.theirs);
}

fn equalOptionalValues(a: ?SideValue, b: ?SideValue) bool {
    if (a == null or b == null) return a == null and b == null;
    const a_node = a.?.node orelse return false;
    const b_node = b.?.node orelse return false;
    return model.Node.eql(a_node, b_node);
}

pub fn finish(arena: std.mem.Allocator, plan: *const MergePlan) Error![]const u8 {
    const output = try merge_apply.applyResolved(arena, plan, true);
    try merge_validate.validate(arena, output);
    return output;
}

test {
    _ = merge_apply;
    _ = merge_validate;
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

    const partial = try merge_apply.applyResolved(arena, &built.plan, false);

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

test "merge facade: rejects deletion of changed Ours document bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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

    // The deletion operation covers this document, so it must account for its Ours bytes.
    try testing.expectError(error.UnsupportedStructure, build(arena, base, ours, ""));
}

test "merge facade: keeps Ours bytes for equal document additions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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

    var built = try build(arena, "", ours, theirs);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings(ours, built.partial);
    try testing.expectEqualStrings(ours, try finish(arena, &built.plan));
}

test "map container delete and edit resolves symmetrically" {
    const base =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Config:\n" ++
        "    left: 1\n" ++
        "    right: 1\n" ++
        "  m_After: keep\n";
    const deleted =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_After: keep\n";
    const edited =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Config:\n" ++
        "    left: 2\n" ++
        "    right: 1\n" ++
        "  m_After: keep\n";

    inline for (.{
        .{ .ours = deleted, .theirs = edited },
        .{ .ours = edited, .theirs = deleted },
    }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var take_deleted = try build(arena, base, case.ours, case.theirs);
        try std.testing.expectEqual(@as(usize, 1), take_deleted.plan.unresolvedCount());
        const operation = &take_deleted.plan.operations[0];
        try std.testing.expectEqualStrings("m_Config", operation.property_path);
        try resolve(arena, &take_deleted.plan, operation.id, .remove);
        try std.testing.expectEqualStrings(deleted, try finish(arena, &take_deleted.plan));

        var take_edited = try build(arena, base, case.ours, case.theirs);
        const edited_operation = &take_edited.plan.operations[0];
        const edited_resolution: Resolution = if (edited_operation.values.ours != null)
            .{ .take = .ours }
        else
            .{ .take = .theirs };
        try resolve(arena, &take_edited.plan, edited_operation.id, edited_resolution);
        try std.testing.expectEqualStrings(edited, try finish(arena, &take_edited.plan));
    }
}

test "component document custom resolution keeps its owner membership" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("component-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try build(arena, fixture.base, fixture.ours, fixture.theirs);
    const atomic = support.findAtomicByKind(&built.plan, .component).?;
    const membership = merge_model.operationById(&built.plan, atomic.operation_ids[0]).?;
    const component = for (atomic.operation_ids) |operation_id| {
        const candidate = merge_model.operationById(&built.plan, operation_id).?;
        if (candidate.kind == .component) break candidate;
    } else return error.TestUnexpectedResult;
    const corrected = "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 3";
    const expected = try std.mem.replaceOwned(u8, arena, fixture.expected, "m_Mass: 2\n", "m_Mass: 3\n");

    try testing.expectEqual(merge_model.OperationKind.sequence_membership, membership.kind);
    try testing.expect(supportsCustomResolution(&built.plan, membership.id));
    try testing.expect(supportsCustomResolution(&built.plan, component.id));
    try resolve(arena, &built.plan, component.id, .{ .custom = corrected });
    try testing.expectEqualStrings(expected, try finish(arena, &built.plan));
}

test "component document custom resolution can be edited again and reversed" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("component-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try build(arena, fixture.base, fixture.ours, fixture.theirs);
    const atomic = support.findAtomicByKind(&built.plan, .component).?;
    const membership = merge_model.operationById(&built.plan, atomic.operation_ids[0]).?;
    const corrected_three =
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 3\n";
    const corrected_four =
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 4\n";

    try resolve(arena, &built.plan, membership.id, .{ .custom = corrected_three });
    try testing.expect(std.mem.indexOf(u8, try finish(arena, &built.plan), "m_Mass: 3") != null);
    try resolve(arena, &built.plan, membership.id, .{ .custom = corrected_four });
    try testing.expect(std.mem.indexOf(u8, try finish(arena, &built.plan), "m_Mass: 4") != null);
    try resolve(arena, &built.plan, membership.id, .{ .take = .theirs });
    try testing.expectEqualStrings(fixture.theirs, try finish(arena, &built.plan));
    try resolve(arena, &built.plan, membership.id, .remove);
    try testing.expectEqualStrings(fixture.ours, try finish(arena, &built.plan));
}

test "component document custom resolution rejects invalid identity and owner" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("component-delete-edit", true);
    const invalid_documents = [_][]const u8{
        "--- !u!54 &99\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 3\n",
        "--- !u!65 &54\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_Mass: 3\n",
        "--- !u!54 &54\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_Mass: 3\n",
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 2}\n  m_Mass: 3\n",
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1, guid: bad}\n  m_Mass: 3\n",
        "",
    };

    for (invalid_documents) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var built = try build(arena, fixture.base, fixture.ours, fixture.theirs);
        const atomic = support.findAtomicByKind(&built.plan, .component).?;
        const membership = merge_model.operationById(&built.plan, atomic.operation_ids[0]).?;
        try testing.expectError(
            error.InvalidResolution,
            resolve(arena, &built.plan, membership.id, .{ .custom = invalid }),
        );
        try testing.expectEqualStrings(
            fixture.partial.?,
            try merge_apply.applyResolved(arena, &built.plan, false),
        );
    }
}

test "component document custom resolution preserves a previous edit after rejection" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("component-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try build(arena, fixture.base, fixture.ours, fixture.theirs);
    const atomic = support.findAtomicByKind(&built.plan, .component).?;
    const membership = merge_model.operationById(&built.plan, atomic.operation_ids[0]).?;
    const corrected =
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 3\n";
    const invalid =
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 2}\n" ++
        "  m_Mass: 9\n";

    try resolve(arena, &built.plan, membership.id, .{ .custom = corrected });
    try testing.expectError(
        error.InvalidResolution,
        resolve(arena, &built.plan, membership.id, .{ .custom = invalid }),
    );
    try testing.expect(std.mem.indexOf(u8, try finish(arena, &built.plan), "m_Mass: 3") != null);
}

test "collection public resolves local insertion orders and abort restores ours" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    var built = try build(arena, prefix ++ "[a, b]\n", prefix ++ "[x, a, b]\n", prefix ++ "[y, a, b, z]\n");
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(prefix ++ "[x, a, b]\n", built.partial);
    const id = built.plan.operations[0].id;
    try testing.expect(supportsCustomResolution(&built.plan, id));
    try testing.expect(collectionConflict(&built.plan, id).?.both_orders);
    try resolve(arena, &built.plan, id, .{ .custom = try combinedCollectionValue(arena, &built.plan, id, .ours_first) });
    try testing.expectEqualStrings(prefix ++ "[x, y, a, b, z]\n", try finish(arena, &built.plan));
    built.plan.operations[0].resolution = .unresolved;
    try testing.expectEqualStrings(prefix ++ "[x, a, b]\n", try merge_apply.applyResolved(arena, &built.plan, false));
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "{bad: shape}" }));
    try resolve(arena, &built.plan, id, .{ .custom = try combinedCollectionValue(arena, &built.plan, id, .theirs_first) });
    try testing.expectEqualStrings(prefix ++ "[y, x, a, b, z]\n", try finish(arena, &built.plan));
}

test "collection public accepts pasted block YAML without changing surrounding source" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\r\nMonoBehaviour:\r\n  values:\r\n  - A\r\n";
    const suffix = "  after: keep # comment\r\n";
    var built = try build(arena, prefix ++ suffix, prefix ++ "  - Ours\r\n" ++ suffix, prefix ++ "  - Theirs\r\n" ++ suffix);

    // A pasted block replaces only the conflicting interval and retains the file's CRLF layout.
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "  - One\n  - Two\n" });
    try testing.expectEqualStrings(prefix ++ "  - One\r\n  - Two\r\n" ++ suffix, try finish(arena, &built.plan));
}

test "collection public accepts line breaks while editing a flow value" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    var built = try build(arena, prefix ++ "[A]\n", prefix ++ "[A, Ours]\n", prefix ++ "[A, Theirs]\n");
    // Existing previews use flow YAML, so adding a line break must keep the same collection shape.
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[\n  One,\n  {name: \"two words\", count: 2}\n]\n" });
    try testing.expectEqualStrings(prefix ++ "[A, One, {name: two words, count: 2}]\n", try finish(arena, &built.plan));
    // Apostrophes inside a plain scalar do not open a quoted YAML token.
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[O'Reilly,\n 'Two',\n \"#Three\"]" });
    try testing.expectEqualStrings(prefix ++ "[A, O'Reilly, Two, \"#Three\"]\n", try finish(arena, &built.plan));
}

test "collection public rejects malformed multiline values without changing the result" {
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    for ([_][]const u8{
        "  - One\ninvalid: sibling",
        "- One\n\t- Two",
        "[One,\n {bad: shape]\n]",
        "[\"first\nsecond\"]",
        "[first\n  second]",
        "[first\n\n  second]",
        "- One\n--- !u!114 &2\nMonoBehaviour:\n  field: value",
        "- One\n%ignored\n- Two",
    }) |input| {
        var memory = std.heap.ArenaAllocator.init(testing.allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        var built = try build(arena, prefix ++ "[A]\n", prefix ++ "[A, Ours]\n", prefix ++ "[A, Theirs]\n");
        try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[Keep]" });
        // Rejection must leave the previous valid resolution available for completion.
        try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = input }));
        try testing.expectEqualStrings(prefix ++ "[A, Keep]\n", try finish(arena, &built.plan));
    }
}

test "collection public item field conflict retains independent changes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    var built = try build(arena, prefix ++ "[{left: 1, right: 1}]\n", prefix ++ "[{left: 2, right: 1}]\n", prefix ++ "[{left: 3, right: 4}]\n");
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings("[0].left", built.plan.operations[0].item_path.?);
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
    try testing.expectEqualStrings(prefix ++ "[{left: 2, right: 4}]\n", try finish(arena, &built.plan));
}

fn collectionTestContext(field: @import("merge_context.zig").Field, arena: std.mem.Allocator) !@import("merge_context.zig").Context {
    const ctx = @import("merge_context.zig");
    const fields = try arena.dupe(ctx.Field, &.{field});
    const scripts = try arena.dupe(ctx.Script, &.{.{ .guid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .fields = fields }});
    const snapshot: ctx.Snapshot = .{ .scripts = scripts };
    return .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot };
}

test "collection public key value arrays keep block YAML after taking one side" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix =
        "--- !u!114 &1\n" ++
        "MonoBehaviour:\n" ++
        "  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "  m_Stats:\n";
    const base = prefix ++
        "  - key: Goblin\n" ++
        "    value: 1\n";
    const ours = prefix ++
        "  - key: Goblin\n" ++
        "    value: 2\n" ++
        "  - key: Dragon\n" ++
        "    value: 9\n";
    const theirs = prefix ++
        "  - key: Goblin\n" ++
        "    value: 3\n" ++
        "  - key: Slime\n" ++
        "    value: 2\n";
    var merged = try build(arena, base, ours, theirs);
    try testing.expectEqual(@as(usize, 1), merged.plan.unresolvedCount());
    try resolve(arena, &merged.plan, merged.plan.operations[0].id, .{ .take = .theirs });
    // Independent keys must keep their source pair layout. A reconstructed flow map
    // is not the same YAML Unity wrote for the chosen side.
    try testing.expectEqualStrings(
        prefix ++
            "  - key: Goblin\n" ++
            "    value: 3\n" ++
            "  - key: Dragon\n" ++
            "    value: 9\n" ++
            "  - key: Slime\n" ++
            "    value: 2\n",
        try finish(arena, &merged.plan),
    );
}

test "collection public key value arrays accept a custom scalar pair value" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    var merged = try build(
        arena,
        prefix ++ "  - key: Goblin\n    value: 1\n",
        prefix ++ "  - key: Goblin\n    value: 2\n  - key: Dragon\n    value: 9\n",
        prefix ++ "  - key: Goblin\n    value: 3\n  - key: Slime\n    value: 2\n",
    );
    // Semantic Result edits send the Value cell, not a reconstructed pair. That
    // scalar must still keep Goblin's key and the independent Dragon / Slime items.
    try resolve(arena, &merged.plan, merged.plan.operations[0].id, .{ .custom = "4" });
    try testing.expectEqualStrings(
        prefix ++ "  - key: Goblin\n    value: 4\n  - key: Dragon\n    value: 9\n  - key: Slime\n    value: 2\n",
        try finish(arena, &merged.plan),
    );
}

test "collection public key value arrays merge by key without a schema" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const base = prefix ++ "[]\n";
    const ours = prefix ++ "[{key: a, value: 1}]\n";
    const theirs = prefix ++ "[{key: b, value: 2}]\n";
    var unknown = try build(arena, base, ours, theirs);
    try testing.expectEqual(@as(usize, 0), unknown.plan.unresolvedCount());
    try testing.expectEqualStrings(prefix ++ "[{key: a, value: 1}, {key: b, value: 2}]\n", unknown.partial);
    const ordered_context = try collectionTestContext(.{ .path = "values", .kind = .ordered }, arena);
    var ordered = try buildWithContext(arena, base, ours, theirs, ordered_context);
    try testing.expect(collectionConflict(&ordered.plan, ordered.plan.operations[0].id).?.both_orders);
}

test "collection public dictionary reorder conflict does not offer both orders" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    var merged = try build(
        arena,
        prefix ++ "  - key: a\n    value: 1\n  - key: b\n    value: 2\n  - key: c\n    value: 3\n",
        prefix ++ "  - key: c\n    value: 3\n  - key: b\n    value: 2\n  - key: a\n    value: 1\n",
        prefix ++ "  - key: b\n    value: 2\n  - key: a\n    value: 1\n  - key: c\n    value: 3\n",
    );
    try testing.expectEqual(@as(usize, 1), merged.plan.unresolvedCount());
    const conflict = collectionConflict(&merged.plan, merged.plan.operations[0].id).?;
    // Concatenating pair sequences would duplicate keys. Dictionaries only
    // accept one side's order, unlike ordered arrays.
    try testing.expectEqual(@import("merge_value.zig").Reason.insertion_order, conflict.reason);
    try testing.expect(!conflict.both_orders);
}

test "collection public packed integer insertion order still offers both orders" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000\n", prefix ++ "0100000002000000\n", prefix ++ "0100000003000000\n", context);
    // Packed int[] uses the same Both sides insertion-order choice as ordered arrays.
    try testing.expect(collectionConflict(&built.plan, built.plan.operations[0].id).?.both_orders);
}

test "collection public missing array type evidence stays editable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const ctx = @import("merge_context.zig");
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const known = try collectionTestContext(.{ .path = "values", .kind = .ordered }, arena);
    // Missing revision evidence must keep a manual choice available instead of
    // applying a type inferred from only the remaining scripts.
    const cases = [_]ctx.Context{
        .{ .base = known.base, .ours = known.ours, .theirs = .{} },
        .{ .base = known.base, .ours = known.ours, .theirs = known.theirs, .output = .{ .revision = "known-output", .scripts = &.{} } },
    };
    for (cases) |context| {
        var built = try buildWithContext(arena, prefix ++ "[]\n", prefix ++ "[a]\n", prefix ++ "[b]\n", context);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try testing.expectEqual(@import("merge_value.zig").Reason.context_required, collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
        try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[a, b]" });
        try testing.expectEqualStrings(prefix ++ "[a, b]\n", try finish(arena, &built.plan));
    }
}

test "collection public malformed packed encoding needs valid typed repair" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000\n", prefix ++ "broken\n", prefix ++ "02000000\n", context);
    const id = built.plan.operations[0].id;
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "broken" }));
    try resolve(arena, &built.plan, id, .{ .custom = "[1, -1]" });
    try testing.expectEqualStrings(prefix ++ "01000000ffffffff\n", try finish(arena, &built.plan));
}

test "collection public deleted field supports explicit array repair" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    var built = try build(arena, prefix ++ "  values: [a]\n  after: keep\n", prefix ++ "  after: keep\n", prefix ++ "  values: [b]\n  after: keep\n");
    const id = built.plan.operations[0].id;
    try testing.expect(supportsCustomResolution(&built.plan, id));
    try resolve(arena, &built.plan, id, .{ .custom = "[a, b]" });
    try testing.expectEqualStrings(prefix ++ "  values: [a, b]\n  after: keep\n", try finish(arena, &built.plan));
}

test "collection public whole selected sequence retains its exact source entry" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    const base = prefix ++ "  values:\n  - a\n";
    const theirs = prefix ++ "  values: # new header\n  - a\n  - b\n";
    var built = try build(arena, base, base, theirs);
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
}

test "collection public conflicting comments are explicit and take preserves selected bytes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values:\n";
    const ours = prefix ++ "  - a # ours\n";
    const theirs = prefix ++ "  - a # theirs\n";
    var built = try build(arena, prefix ++ "  - a # base\n", ours, theirs);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(ours, built.partial);
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .theirs });
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
}

test "collection public schema change permits an explicit selected scalar side" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const before = try collectionTestContext(.{ .path = "values", .kind = .ordered }, arena);
    const after = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const theirs = prefix ++ "01000000i\n";
    var built = try buildWithContext(arena, prefix ++ "[a]\n", prefix ++ "[b]\n", theirs, .{ .base = before.base, .ours = before.ours, .theirs = after.theirs, .output = after.output });
    const id = built.plan.operations[0].id;
    try testing.expectEqual(@import("merge_value.zig").Reason.context_required, collectionConflict(&built.plan, id).?.reason);
    try resolve(arena, &built.plan, id, .{ .take = .theirs });
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
}
