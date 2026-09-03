const std = @import("std");
const merge_apply = @import("merge_apply.zig");
const merge_model = @import("merge_model.zig");
const merge_planner = @import("merge_planner.zig");
const merge_validate = @import("merge_validate.zig");
const model = @import("model.zig");

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

pub fn build(
    arena: std.mem.Allocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
) Error!BuildResult {
    var plan = try merge_planner.build(
        arena,
        try merge_planner.parseMergeSide(arena, base),
        try merge_planner.parseMergeSide(arena, ours),
        try merge_planner.parseMergeSide(arena, theirs),
    );
    const partial = try merge_apply.applyResolved(arena, &plan, false);
    try merge_validate.validate(arena, partial);
    return .{
        .plan = plan,
        .partial = partial,
    };
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
            if (operation.kind != .field or atomic.operation_ids.len != 1 or
                !supportsCustomValue(operation) or !wasConflict(operation)) return error.InvalidResolution;
            if (!customFlowMapIsSafeToParse(value))
                return error.InvalidResolution;
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

fn customFlowMapIsSafeToParse(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " ");
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '[') return false;
    if (trimmed[0] != '{') return true;
    if (trimmed[trimmed.len - 1] != '}') return false;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " ");
    if (inner.len == 0) return true;

    var part_start: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (inner, 0..) |byte, index| {
        if (quote) |delimiter| {
            if (byte == ',' or byte == '{' or byte == '}' or byte == '[' or byte == ']')
                return false;
            if (escaped) {
                escaped = false;
            } else if (byte == '\\' and delimiter == '"') {
                escaped = true;
            } else if (byte == delimiter) {
                quote = null;
            }
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '{', '}', '[', ']' => return false,
            ',' => {
                if (!flowEntryHasValue(inner[part_start..index])) return false;
                part_start = index + 1;
            },
            else => {},
        }
    }
    return quote == null and flowEntryHasValue(inner[part_start..]);
}

fn flowEntryHasValue(input: []const u8) bool {
    const entry = std.mem.trim(u8, input, " ");
    for (entry, 0..) |byte, index| {
        if (byte == ':' and index != 0 and
            (index + 1 == entry.len or entry[index + 1] == ' ')) return true;
    }
    return false;
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
