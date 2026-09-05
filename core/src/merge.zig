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
    const parsed_base = try merge_planner.parseMergeSide(arena, base);
    const parsed_ours = try merge_planner.parseMergeSide(arena, ours);
    const parsed_theirs = try merge_planner.parseMergeSide(arena, theirs);
    var plan = try merge_planner.build(arena, parsed_base, parsed_ours, parsed_theirs);
    try verifyTheirsCoverage(arena, parsed_base, parsed_ours, parsed_theirs);
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
) Error!void {
    if (std.mem.eql(u8, ours.bytes, theirs.bytes)) return;

    var replay = try merge_planner.build(arena, base, base, theirs);
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
            const supports_custom_kind = operation.kind == .field or
                (operation.kind == .prefab_override and operation.item_path != null);
            if (!supports_custom_kind or atomic.operation_ids.len != 1 or
                !supportsCustomValue(operation) or !wasConflict(operation)) return error.InvalidResolution;
            _ = try merge_apply.parseCustomValue(arena, value);
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
        member.resolution = stored_resolution;
    }
    errdefer {
        for (atomic.operation_ids, previous) |id, old_resolution| {
            merge_model.operationById(plan, id).?.resolution = old_resolution;
        }
    }
    const candidate = try merge_apply.applyResolved(arena, plan, false);
    merge_validate.validate(arena, candidate) catch |validation_error| switch (validation_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
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
