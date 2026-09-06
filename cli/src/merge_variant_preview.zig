const std = @import("std");
const core = @import("core");
const A = std.mem.Allocator;

pub const Preview = struct {
    effects: []const core.merge.VariantEffect,
    side: ?core.merge.Side,
};

// Preview resolutions belong to this copy. The live plan remains the only choice store.
pub fn inspect(arena: A, plan: *const core.merge.MergePlan, operation_id: ?core.merge.OperationId, pending: ?core.merge.Resolution, complete: bool) core.merge.Error!Preview {
    var copy = plan.*;
    var side: ?core.merge.Side = null;
    if (!complete) {
        const id = operation_id orelse return .{ .effects = &.{}, .side = null };
        if (!core.merge.isVariantPromotion(plan, id)) return .{ .effects = &.{}, .side = null };
        copy.operations = try arena.dupe(core.merge.Operation, plan.operations);
        const operation = for (copy.operations) |op| {
            if (op.id == id) break op;
        } else return error.InvalidResolution;
        const resolution = pending orelse operation.resolution;
        side = switch (resolution) {
            .unresolved => .ours,
            .take => |selected| selected,
            else => return error.InvalidResolution,
        };
        try core.merge.resolve(arena, &copy, id, .{ .take = side.? });
    }
    const provenance = try core.merge.variantProvenance(arena, &copy);
    var effects: std.ArrayList(core.merge.VariantEffect) = .empty;
    for (provenance.effects) |effect| {
        if (complete or effect.decision_operation == operation_id) try effects.append(arena, effect);
    }
    return .{ .effects = try effects.toOwnedSlice(arena), .side = side };
}

pub fn effectText(arena: A, effect: core.merge.VariantEffect) A.Error![]const u8 {
    const indexed = try std.mem.replaceOwned(u8, arena, effect.property_path, ".Array.data[", "[");
    const path = try std.mem.replaceOwned(u8, arena, indexed, ".Array.size", ".length");
    return std.fmt.allocPrint(arena, "Target {d} @{s}\n{s}: inherited {s} -> override {s}", .{
        effect.target.file_id,
        effect.target.guid orelse "local",
        path,
        try leafText(arena, effect.source_value),
        try leafText(arena, effect.result_value),
    });
}

fn leafText(arena: A, optional: ?*const core.model.Node) A.Error![]const u8 {
    const node = optional orelse return "<absent>";
    return switch (node.*) {
        .scalar => |text| if (text.len == 0 or std.mem.indexOfAny(u8, text, "\r\n\t\x1b") != null)
            std.json.Stringify.valueAlloc(arena, text, .{})
        else
            text,
        .ref => |reference| std.fmt.allocPrint(arena, "{{fileID: {d}, guid: {s}}}", .{ reference.file_id, reference.guid orelse "local" }),
        .map, .seq => "<collection>",
    };
}
