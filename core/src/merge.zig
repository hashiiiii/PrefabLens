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
pub const VariantEffectKind = @import("merge_variant.zig").VariantEffectKind;
pub const VariantEffect = @import("merge_variant.zig").VariantEffect;
pub const VariantProvenance = @import("merge_variant.zig").VariantProvenance;

pub fn isVariantPromotion(plan: *const MergePlan, operation_id: OperationId) bool {
    return @import("merge_variant.zig").isPromotion(plan, operation_id);
}

pub fn variantProvenance(arena: std.mem.Allocator, plan: *const MergePlan) Error!VariantProvenance {
    return @import("merge_variant.zig").provenance(arena, plan);
}

pub fn variantPromotionValue(arena: std.mem.Allocator, plan: *const MergePlan, operation_id: OperationId, side: Side) Error!SideValue {
    return @import("merge_variant.zig").promotionValue(arena, plan, operation_id, side);
}

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
        if ((operation.collection != null or std.mem.eql(u8, operation.property_path, "m_SourcePrefab")) and operation.resolution == .unresolved) operation.resolution = .{ .take = .theirs };
    }
    // Invalid source dictionaries still need raw byte coverage before the real
    // plan exposes repair. Only this throwaway copy skips key and shape checks.
    const replay_collections = try arena.dupe(@import("merge_binding.zig").Binding, replay.collections);
    for (replay_collections) |*collection| {
        const conflicts = try arena.dupe(@import("merge_value.zig").Conflict, collection.plan.conflicts);
        for (conflicts) |*conflict| {
            if (conflict.reason == .invalid_dictionary) {
                collection.plan.input.schema = null;
                conflict.sequence = false;
            }
        }
        collection.plan.conflicts = conflicts;
    }
    replay.collections = replay_collections;
    if (replay.unresolvedCount() != 0) return error.UnsupportedStructure;
    const replayed = try merge_apply.applyResolved(arena, &replay, false);
    const has_variant = for (replay.collections) |collection| {
        if (collection.variant != null) break true;
    } else false;
    if (has_variant) {
        // Index rebasing and inactive-row removal intentionally change authored
        // group bytes. Compare both sides through the same proven compositor;
        // all bytes outside those boundaries still have to match exactly.
        var expected = try merge_planner.buildSemanticWithContext(arena, theirs, theirs, theirs, .{ .base = context.theirs, .ours = context.theirs, .theirs = context.theirs, .output = context.theirs });
        for (expected.operations) |*operation| {
            if ((operation.collection != null or std.mem.eql(u8, operation.property_path, "m_SourcePrefab")) and operation.resolution == .unresolved) operation.resolution = .{ .take = .theirs };
        }
        const canonical = try merge_apply.applyResolved(arena, &expected, false);
        if (!std.mem.eql(u8, replayed, canonical)) return error.UnsupportedStructure;
    } else if (!std.mem.eql(u8, replayed, theirs.bytes)) return error.UnsupportedStructure;
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
            .take => |side| valueForSide(operation, side),
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
    switch (resolution) {
        .unresolved => return error.InvalidResolution,
        .take => |side| if (side == .base or valueForSide(operation, side) == null)
            return error.InvalidResolution,
        .custom => |value| {
            if (isVariantPromotion(plan, operation_id)) return error.InvalidResolution;
            if (operation.collection) |binding_ref| {
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
        .remove => if (isVariantPromotion(plan, operation_id)) return error.InvalidResolution,
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
        member.resolution = stored_resolution;
    }
    errdefer {
        for (atomic.operation_ids, previous) |id, old_resolution| {
            merge_model.operationById(plan, id).?.resolution = old_resolution;
        }
    }
    if (operation.collection) |reference| {
        try @import("merge_binding.zig").validateSelection(arena, plan, reference);
        try @import("merge_variant.zig").validateSelection(arena, plan, reference);
    }
    const candidate = try merge_apply.applyResolved(arena, plan, false);
    merge_validate.validate(arena, candidate) catch |validation_error| switch (validation_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
}

pub const CollectionConflict = struct { reason: @import("merge_value.zig").Reason, both_orders: bool };
pub fn collectionConflict(plan: *const MergePlan, operation_id: OperationId) ?CollectionConflict {
    const operation = merge_model.operationByIdConst(plan, operation_id) orelse return null;
    const ref = operation.collection orelse return null;
    const conflict = plan.collections[ref.binding].plan.conflicts[ref.conflict];
    return .{ .reason = conflict.reason, .both_orders = conflict.reason == .insertion_order };
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
    if (isVariantPromotion(plan, operation_id)) return false;
    if (operation.collection != null) return true;
    return (operation.kind == .field or (operation.kind == .prefab_override and operation.item_path != null)) and supportsCustomValue(operation) and wasConflict(operation);
}

fn valueForSide(operation: *const Operation, side: merge_model.Side) ?SideValue {
    return switch (side) {
        .base => operation.values.base,
        .ours => operation.values.ours,
        .theirs => operation.values.theirs,
    };
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

test "merge facade: keeps selected document order at one offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const ours = "";
    const theirs =
        "--- !u!21 &2\nMaterial:\n  m_Name: Added\n" ++
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";

    var built = try build(arena, base, ours, theirs);
    const operation_id = for (built.plan.operations) |operation| {
        if (operation.kind == .document and operation.identity.document.file_id == 1)
            break operation.id;
    } else return error.TestUnexpectedResult;
    try resolve(arena, &built.plan, operation_id, .{ .take = .theirs });
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
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

test "merge build rejects a malformed flow entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const valid = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
    const malformed = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {fileID: 1, bad}\n";

    try std.testing.expectError(
        error.MalformedInput,
        build(arena_state.allocator(), valid, malformed, valid),
    );
}

test "merge build rejects invalid double-quoted escapes" {
    const invalid_values = [_][]const u8{
        "\"bad\\q\"",
        "{fileID: 0, guid: \"bad\\u12\", type: 3}",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const valid = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
        const malformed = try std.fmt.allocPrint(
            arena,
            "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {s}\n",
            .{invalid},
        );

        try std.testing.expectError(error.MalformedInput, build(arena, valid, malformed, valid));
    }
}

test "merge resolve rejects nested object reference members" {
    const nested_values = [_][]const u8{
        "{fileID: 1, extra: {value: 2}}",
        "{fileID: 1, extra: [2]}",
    };
    for (nested_values) |nested| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
        const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
        const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n";
        var built = try build(arena, base, ours, theirs);

        try std.testing.expectError(
            error.InvalidResolution,
            resolve(arena, &built.plan, 0, .{ .custom = nested }),
        );
        try std.testing.expect(built.plan.operations[0].resolution == .unresolved);
    }
}

test "merge resolve rejects invalid double-quoted escapes" {
    const invalid_values = [_][]const u8{
        "\"bad\\q\"",
        "{fileID: 0, guid: \"bad\\u12\", type: 3}",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
        const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";
        const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n";
        var built = try build(arena, base, ours, theirs);

        try std.testing.expectError(
            error.InvalidResolution,
            resolve(arena, &built.plan, 0, .{ .custom = invalid }),
        );
        try std.testing.expect(built.plan.operations[0].resolution == .unresolved);
    }
}

test "collection public merges separate gaps and recursive item fields" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    const cases = .{
        .{ "[a, b]", "[x, a, b]", "[a, b, y]", "[x, a, b, y]" },
        .{ "[{left: 1, right: 1}]", "[{left: 2, right: 1}]", "[{left: 1, right: 3}]", "[{left: 2, right: 3}]" },
        .{ "[]", "[]", "[a]", "[a]" },
        .{ "[a]", "[]", "[a]", "[]" },
    };
    inline for (cases) |case| {
        var built = try build(arena, prefix ++ case[0] ++ "\n", prefix ++ case[1] ++ "\n", prefix ++ case[2] ++ "\n");
        try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
        try testing.expectEqualStrings(prefix ++ case[3] ++ "\n", try finish(arena, &built.plan));
    }
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
    const scripts = try arena.dupe(ctx.Script, &.{.{ .guid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .class_name = "Example", .source_hash = "hash", .fields = fields }});
    const snapshot: ctx.Snapshot = .{ .scripts = scripts };
    return .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot };
}

test "collection public declared packed arrays merge signed values and empty encoding" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000i\n", prefix ++ "ffffffff01000000i\n", prefix ++ "0100000000000080i\n", context);
    try testing.expectEqualStrings(prefix ++ "ffffffff0100000000000080i\n", try finish(arena, &built.plan));
    var empty = try buildWithContext(arena, prefix ++ "\n", prefix ++ "\n", prefix ++ "01000000\n", context);
    try testing.expectEqualStrings(prefix ++ "01000000\n", try finish(arena, &empty.plan));
}

test "collection public dictionary context distinguishes declared key value arrays" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const base = prefix ++ "[]\n";
    const ours = prefix ++ "[{key: a, value: 1}]\n";
    const theirs = prefix ++ "[{key: b, value: 2}]\n";
    var unknown = try build(arena, base, ours, theirs);
    try testing.expectEqualStrings(ours, unknown.partial);
    try testing.expectEqual(@import("merge_value.zig").Reason.context_required, collectionConflict(&unknown.plan, unknown.plan.operations[0].id).?.reason);
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    var typed = try buildWithContext(arena, base, ours, theirs, context);
    try testing.expectEqualStrings(prefix ++ "[{key: a, value: 1}, {key: b, value: 2}]\n", try finish(arena, &typed.plan));
    const ordered_context = try collectionTestContext(.{ .path = "values", .kind = .ordered }, arena);
    var ordered = try buildWithContext(arena, base, ours, theirs, ordered_context);
    try testing.expect(collectionConflict(&ordered.plan, ordered.plan.operations[0].id).?.both_orders);
}

test "collection public dictionary conflicts validate keys and preserve other edits" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "[{key: a, value: 1}, {key: b, value: 1}]\n", prefix ++ "[{key: b, value: 1}]\n", prefix ++ "[{key: a, value: 2}, {key: b, value: 3}]\n", context);
    const id = built.plan.operations[0].id;
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "{key: b, value: 8}" }));
    try testing.expect(built.plan.operations[0].resolution == .unresolved);
    try resolve(arena, &built.plan, id, .{ .take = .theirs });
    try testing.expectEqualStrings(prefix ++ "[{key: a, value: 2}, {key: b, value: 3}]\n", try finish(arena, &built.plan));
    var duplicate = try buildWithContext(arena, prefix ++ "[]\n", prefix ++ "[{key: a, value: 1}, {key: a, value: 2}]\n", prefix ++ "[{key: b, value: 3}]\n", context);
    try testing.expectEqual(@as(usize, 1), duplicate.plan.unresolvedCount());
    try testing.expectError(error.InvalidResolution, resolve(arena, &duplicate.plan, duplicate.plan.operations[0].id, .{ .take = .ours }));
    try resolve(arena, &duplicate.plan, duplicate.plan.operations[0].id, .{ .custom = "[{key: a, value: 9}, {key: b, value: 3}]" });
    try testing.expectEqualStrings(prefix ++ "[{key: a, value: 9}, {key: b, value: 3}]\n", try finish(arena, &duplicate.plan));
}

test "collection public dictionary reordered choice retains value edits and new keys" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_dictionary, .dictionary_value = .string, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "[{key: 1, value: a}, {key: 2, value: b}, {key: 3, value: c}]\n", prefix ++ "[{key: 2, value: b}, {key: 1, value: a}, {key: 3, value: c}]\n", prefix ++ "[{key: 1, value: z}, {key: 3, value: c}, {key: 2, value: b}, {key: 4, value: d}]\n", context);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    const id = built.plan.operations[0].id;
    try testing.expectEqual(@import("merge_value.zig").Reason.dictionary_order, collectionConflict(&built.plan, id).?.reason);
    try resolve(arena, &built.plan, id, .{ .take = .ours });
    try testing.expectEqualStrings(prefix ++ "[{key: 2, value: b}, {key: 1, value: z}, {key: 3, value: c}, {key: 4, value: d}]\n", try finish(arena, &built.plan));
}

test "collection public packed selection retains changed encoding layout" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000\n", prefix ++ "01000000\n", prefix ++ "0100000002000000i\n", context);
    try testing.expectEqualStrings(prefix ++ "0100000002000000i\n", try finish(arena, &built.plan));
}

test "collection public dictionary invalid theirs remains editable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_dictionary, .dictionary_value = .string, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "[]\n", prefix ++ "[{key: 2, value: b}]\n", prefix ++ "[{key: 1, value: a}, {key: 01, value: c}]\n", context);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[{key: 1, value: c}, {key: 2, value: b}]" });
    try testing.expectEqualStrings(prefix ++ "[{key: 1, value: c}, {key: 2, value: b}]\n", try finish(arena, &built.plan));
}

test "collection public preserves CRLF comments and unchanged item spans" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\r\nMonoBehaviour:\r\n  values: # header\r\n";
    const tail = "  after: keep # outside\r\n";
    var built = try build(arena, prefix ++ "  - a # first\r\n  - b # second\r\n" ++ tail, prefix ++ "  - x\r\n  - a # first\r\n  - b # second\r\n" ++ tail, prefix ++ "  - a # first\r\n  - b # second\r\n  - y\r\n" ++ tail);
    try testing.expectEqualStrings(prefix ++ "  - x\r\n  - a # first\r\n  - b # second\r\n  - y\r\n" ++ tail, try finish(arena, &built.plan));
}

test "collection public duplicate occurrences and move choices preserve independent edits" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    var duplicate = try build(arena, prefix ++ "[a, x, a]\n", prefix ++ "[a, a]\n", prefix ++ "[a, x, a, y]\n");
    try testing.expectEqualStrings(prefix ++ "[a, a, y]\n", try finish(arena, &duplicate.plan));
    var moved = try build(arena, prefix ++ "[a, b, c]\n", prefix ++ "[b, c, a]\n", prefix ++ "[a, B, c]\n");
    for (moved.plan.operations) |op| if (op.resolution == .unresolved) {
        try resolve(arena, &moved.plan, op.id, .{ .take = .ours });
    };
    try testing.expectEqualStrings(prefix ++ "[B, c, a]\n", try finish(arena, &moved.plan));
}

test "collection public nested unknown dictionary shape needs context" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values: ";
    var built = try build(arena, prefix ++ "[{entries: []}]\n", prefix ++ "[{entries: [{key: a, value: 1}]}]\n", prefix ++ "[{entries: [{key: a, value: 2}]}]\n");
    try testing.expectEqual(@import("merge_value.zig").Reason.context_required, collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
}

test "collection public rejects local dictionary collision while another conflict is unresolved" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "[{key: a, value: 1}, {key: b, value: 1}, {key: c, value: 1}]\n", prefix ++ "[{key: a, value: 2}, {key: c, value: 1}]\n", prefix ++ "[{key: a, value: 3}, {key: b, value: 2}, {key: c, value: 4}]\n", context);
    try testing.expectEqual(@as(usize, 2), built.plan.unresolvedCount());
    const id = built.plan.operations[1].id;
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "{key: c, value: 9}" }));
    try testing.expectEqual(@as(usize, 2), built.plan.unresolvedCount());
}

test "collection public preserves ours formatting edit during concurrent semantic changes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values:\n";
    const ours = prefix ++ "  - x\n  - a # edited comment\n  - b\n";
    var built = try build(arena, prefix ++ "  - a # original\n  - b\n", ours, prefix ++ "  - a # original\n  - b\n  - y\n");
    if (built.plan.unresolvedCount() > 0) {
        try testing.expectEqualStrings(ours, built.partial);
    } else {
        const result = try finish(arena, &built.plan);
        try testing.expect(std.mem.indexOf(u8, result, "a # edited comment") != null);
        try testing.expect(std.mem.indexOf(u8, result, "  - y\n") != null);
    }
}

test "collection public context mismatch and unknown equality stay editable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const ctx = @import("merge_context.zig");
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const known = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const unknown_equality = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32 }, arena);
    const different_type = try collectionTestContext(.{ .path = "values", .kind = .ordered }, arena);
    const cases = [_]ctx.Context{ unknown_equality, .{ .base = known.base, .ours = known.ours, .theirs = .{} }, .{ .base = known.base, .ours = known.ours, .theirs = different_type.theirs }, .{ .base = known.base, .ours = known.ours, .theirs = known.theirs, .output = .{ .revision = "known-output", .scripts = &.{} } } };
    for (cases) |context| {
        var built = try buildWithContext(arena, prefix ++ "[]\n", prefix ++ "[{key: a, value: 1}]\n", prefix ++ "[{key: b, value: 2}]\n", context);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try testing.expectEqual(@import("merge_value.zig").Reason.context_required, collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
        try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[{key: a, value: 1}, {key: b, value: 2}]" });
        _ = try finish(arena, &built.plan);
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

test "collection public dictionary both add and key rename remain independent" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "[{key: old, value: 1}]\n", prefix ++ "[{key: renamed, value: 1}, {key: added, value: 2}]\n", prefix ++ "[{key: old, value: 3}, {key: added, value: 4}]\n", context);
    try testing.expectEqual(@as(usize, 2), built.plan.unresolvedCount());
    try resolve(arena, &built.plan, built.plan.operations[0].id, .remove);
    try resolve(arena, &built.plan, built.plan.operations[1].id, .{ .take = .theirs });
    try testing.expectEqualStrings(prefix ++ "[{key: renamed, value: 1}, {key: added, value: 4}]\n", try finish(arena, &built.plan));
}

test "collection public keeps theirs comment edit with independent ours insertion" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values:\n";
    var built = try build(arena, prefix ++ "  - a # original\n  - b\n", prefix ++ "  - x\n  - a # original\n  - b\n", prefix ++ "  - a # changed\n  - b\n  - y\n");
    try testing.expectEqualStrings(prefix ++ "  - x\n  - a # changed\n  - b\n  - y\n", try finish(arena, &built.plan));
}

test "collection public empty packed custom writes Unity empty token" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000i\n", prefix ++ "02000000i\n", prefix ++ "03000000i\n", context);
    try resolve(arena, &built.plan, built.plan.operations[0].id, .{ .custom = "[]" });
    try testing.expectEqualStrings(prefix ++ "\n", try finish(arena, &built.plan));
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

test "collection public duplicate occurrence comment edits are never silently lost" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values:\n";
    const ours = prefix ++ "  - x\n  - a # changed\n  - a # second\n";
    var built = try build(arena, prefix ++ "  - a # first\n  - a # second\n", ours, prefix ++ "  - a # first\n  - a # second\n  - y\n");
    if (built.plan.unresolvedCount() > 0) {
        try testing.expectEqualStrings(ours, built.partial);
    } else {
        const output = try finish(arena, &built.plan);
        try testing.expect(std.mem.indexOf(u8, output, "# changed") != null);
    }
}

test "collection public replays adjacent newly inserted collection and scalar fields" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    const theirs = prefix ++ "  first: [a]\n  middle: scalar\n  second: [b]\n  after: keep\n";
    var built = try build(arena, prefix ++ "  after: keep\n", prefix ++ "  after: keep\n", theirs);
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
}

test "collection public concurrent new array fields provide both insertion orders" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    var built = try build(arena, prefix ++ "  after: keep\n", prefix ++ "  values: [a]\n  after: keep\n", prefix ++ "  values: [b]\n  after: keep\n");
    const id = built.plan.operations[0].id;
    try testing.expect(collectionConflict(&built.plan, id).?.both_orders);
    try resolve(arena, &built.plan, id, .{ .custom = try combinedCollectionValue(arena, &built.plan, id, .ours_first) });
    try testing.expectEqualStrings(prefix ++ "  values: [a, b]\n  after: keep\n", try finish(arena, &built.plan));
}

test "collection public compositor respects unresolved atomic dependencies" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    const ours = prefix ++ "  scalar: 2\n  values: [x, a]\n";
    var built = try build(arena, prefix ++ "  scalar: 1\n  values: [a]\n", ours, prefix ++ "  scalar: 3\n  values: [y, a, z]\n");
    const id = built.plan.operations[1].id;
    built.plan.atomic_operations[1].dependencies = try arena.dupe(merge_model.AtomicId, &.{0});
    try resolve(arena, &built.plan, id, .{ .take = .ours });
    try testing.expectEqualStrings(ours, try merge_apply.applyResolved(arena, &built.plan, false));
    try resolve(arena, &built.plan, 0, .{ .take = .ours });
    try testing.expectEqualStrings(prefix ++ "  scalar: 2\n  values: [x, a, z]\n", try finish(arena, &built.plan));
}

test "collection public typed Unity dictionary keeps null-like literal string keys" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values:\n";
    const base = prefix ++ "  - key: null\n    value: 1\n  - key: ~\n    value: 2\n";
    const ours = prefix ++ "  - key: null\n    value: 3\n  - key: ~\n    value: 2\n";
    const theirs = prefix ++ "  - key: null\n    value: 1\n  - key: ~\n    value: 4\n  - key: NULL\n    value: 5\n";
    var built = try buildWithContext(arena, base, ours, theirs, context);
    try testing.expectEqualStrings(prefix ++ "  - key: null\n    value: 3\n  - key: ~\n    value: 4\n  - key: NULL\n    value: 5\n", try finish(arena, &built.plan));
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

test "collection public typed blank string key preserves source and rejects explicit map custom key" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n";
    const ours = prefix ++ "  values:\n  - key: \n    value: 1\n";
    var built = try buildWithContext(arena, prefix ++ "  values: []\n", ours, prefix ++ "  values:\n  - key: \n    value: 2\n", context);
    try testing.expectEqualStrings(ours, built.partial);
    const id = built.plan.operations[0].id;
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "{key: {}, value: 9}" }));
    try resolve(arena, &built.plan, id, .{ .custom = "{key: \"\", value: 9}" });
    try testing.expectEqualStrings(prefix ++ "  values:\n  - {key: \"\", value: 9}\n", try finish(arena, &built.plan));
    var automatic = try buildWithContext(arena, ours, ours, prefix ++ "  values:\n  - key: \n    value: 2\n  - key: other\n    value: 3\n", context);
    try testing.expectEqualStrings(prefix ++ "  values:\n  - key: \n    value: 2\n  - key: other\n    value: 3\n", try finish(arena, &automatic.plan));
}

test "collection public concurrent header comment change is preserved or explicit" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    const ours = prefix ++ "  values: # base\n  - x\n  - a\n";
    var built = try build(arena, prefix ++ "  values: # base\n  - a\n", ours, prefix ++ "  values: # theirs\n  - a\n  - y\n");
    if (built.plan.unresolvedCount() > 0) {
        try testing.expectEqualStrings(ours, built.partial);
    } else {
        try testing.expect(std.mem.indexOf(u8, try finish(arena, &built.plan), "# theirs") != null);
    }
}

test "collection public review identical duplicate spans retain edited occurrence bytes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  values:\n";
    const base = prefix ++ "  - a # same\n  - a # same\n";
    const ours = prefix ++ "  - x\n  - a # changed\n  - a # same\n";
    const theirs = prefix ++ "  - a # same\n  - a # same\n  - y\n";
    var built = try build(arena, base, ours, theirs);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(ours, built.partial);
    const id = built.plan.operations[0].id;
    try testing.expectEqual(@import("merge_value.zig").Reason.source_bytes, collectionConflict(&built.plan, id).?.reason);
    try resolve(arena, &built.plan, id, .{ .take = .ours });
    try testing.expectEqualStrings(ours, try finish(arena, &built.plan));
}

test "collection public review packed suffix-only change preserves the changed source" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const theirs = prefix ++ "01000000i\n";
    var built = try buildWithContext(arena, prefix ++ "01000000\n", prefix ++ "01000000\n", theirs, context);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings(theirs, try finish(arena, &built.plan));
}

test "collection public review invalid dictionary shape remains repairable and validated" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    const ours = prefix ++ "[{key: a, value: 1}]\n";
    var built = try buildWithContext(arena, prefix ++ "[]\n", ours, prefix ++ "{}\n", context);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(ours, built.partial);
    const id = built.plan.operations[0].id;
    try testing.expectEqual(@import("merge_value.zig").Reason.invalid_dictionary, collectionConflict(&built.plan, id).?.reason);
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .take = .theirs }));
    try testing.expectError(error.InvalidResolution, resolve(arena, &built.plan, id, .{ .custom = "{}" }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try resolve(arena, &built.plan, id, .{ .custom = "[]" });
    try testing.expectEqualStrings(prefix ++ "[]\n", try finish(arena, &built.plan));
}

test "collection public review packed layout edit composes with independent values" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const context = try collectionTestContext(.{ .path = "values", .kind = .int32_array }, arena);
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n  values: ";
    var built = try buildWithContext(arena, prefix ++ "01000000\n", prefix ++ "02000000\n", prefix ++ "01000000i\n", context);
    try testing.expectEqualStrings(prefix ++ "02000000i\n", try finish(arena, &built.plan));
}
