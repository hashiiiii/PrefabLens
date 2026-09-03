const std = @import("std");
const merge = @import("merge.zig");
const merge_test_support = @import("merge_test_support.zig");
const merge_validate = @import("merge_validate.zig");

const testing = std.testing;

const cases = [_][]const u8{
    "sequence-add",
    "sequence-reorder-one-side",
    "sequence-reorder-compatible",
    "component-add",
    "component-delete",
    "game-object-add",
    "game-object-delete",
    "reparent-one-side",
    "reparent-same-parent",
    "prefab-property",
    "prefab-added-component",
    "prefab-removed-component",
    "prefab-added-game-object",
    "prefab-removed-game-object",
};

const conflict_cases = [_][]const u8{
    "sequence-delete-edit",
    "sequence-reorder-conflict",
    "component-delete-edit",
    "game-object-delete-edit",
    "reparent-conflict",
    "reparent-cycle",
    "prefab-order-conflict",
};

const regression_conflict_cases = [_][]const u8{
    "game-object-delete-reparent",
};

const all_conflict_cases = conflict_cases ++ regression_conflict_cases;

comptime {
    for (cases) |name| _ = merge_test_support.load(name, false);
    for (all_conflict_cases) |name| _ = merge_test_support.load(name, true);
}

test "merge fixtures: automatic results match bytes and invariants" {
    inline for (cases) |name| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const fixture = merge_test_support.load(name, false);
        const built = try merge.build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
        try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
        try testing.expectEqualStrings(fixture.expected, built.partial);
        try merge_validate.validate(arena_state.allocator(), built.partial);
    }
}

test "merge fixtures: conflict results match safe partial bytes" {
    inline for (all_conflict_cases) |name| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const fixture = merge_test_support.load(name, true);
        const built = try merge.build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
        try testing.expect(built.plan.unresolvedCount() != 0);
        try testing.expectEqualStrings(fixture.partial.?, built.partial);
        try merge_validate.validate(arena_state.allocator(), built.partial);
        try merge_test_support.expectAtomicResolutionsAreWhole(&built.plan);
    }
}

test "merge fixtures: errors keep ours unchanged" {
    const fixture = merge_test_support.load("component-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original_ours = try arena.dupe(u8, fixture.ours);
    const ours = try arena.dupe(u8, fixture.ours);
    try testing.expectError(
        error.MalformedInput,
        merge.build(arena, "not Unity YAML\n", ours, fixture.theirs),
    );
    try testing.expectEqualStrings(original_ours, ours);

    const base = try std.mem.replaceOwned(
        u8,
        arena,
        fixture.base,
        "  m_Name: Root\n",
        "  m_Unknown:\n  - 1\n  - 2\n  m_Name: Root\n",
    );
    const unknown_sequence_ours = try std.mem.replaceOwned(
        u8,
        arena,
        fixture.ours,
        "  m_Name: Root\n",
        "  m_Unknown:\n  - 1\n  - 3\n  m_Name: Root\n",
    );
    const original_unknown_ours = try arena.dupe(u8, unknown_sequence_ours);
    try testing.expectError(
        error.UnsupportedStructure,
        merge.build(arena, base, unknown_sequence_ours, base),
    );
    try testing.expectEqualStrings(original_unknown_ours, unknown_sequence_ours);
}
