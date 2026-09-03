const std = @import("std");
const merge_model = @import("merge_model.zig");

pub const Fixture = struct {
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    expected: []const u8,
    partial: ?[]const u8,
};

pub fn load(comptime name: []const u8, comptime has_partial: bool) Fixture {
    comptime {
        if (name.len == 0) @compileError("merge fixture name is empty");
        for (name) |byte| {
            if (!std.ascii.isLower(byte) and byte != '-')
                @compileError("merge fixture names can contain only a-z and '-'");
        }
    }
    const root = "testdata/merge/" ++ name ++ "/";
    return .{
        .base = @embedFile(root ++ "base.prefab"),
        .ours = @embedFile(root ++ "ours.prefab"),
        .theirs = @embedFile(root ++ "theirs.prefab"),
        .expected = @embedFile(root ++ "expected.prefab"),
        .partial = if (has_partial) @embedFile(root ++ "partial.prefab") else null,
    };
}

pub fn findAtomicByKind(
    plan: *merge_model.MergePlan,
    kind: merge_model.OperationKind,
) ?*merge_model.AtomicOperation {
    for (plan.atomic_operations) |*operation| {
        if (operation.kind == kind) return operation;
    }
    return null;
}

pub fn findOperationByKind(
    plan: *merge_model.MergePlan,
    kind: merge_model.OperationKind,
) ?*merge_model.Operation {
    for (plan.operations) |*operation| {
        if (operation.kind == kind) return operation;
    }
    return null;
}

pub fn expectAtomicResolutionsAreWhole(plan: *const merge_model.MergePlan) !void {
    for (plan.atomic_operations) |atomic| {
        var resolved: usize = 0;
        for (atomic.operation_ids) |id| {
            const operation = for (plan.operations) |*candidate| {
                if (candidate.id == id) break candidate;
            } else return error.InvalidMerge;
            if (operation.resolution != .unresolved) resolved += 1;
        }
        try std.testing.expect(resolved == 0 or resolved == atomic.operation_ids.len);
    }
}
