const std = @import("std");

const testing = std.testing;

pub const RankMap = std.StringHashMapUnmanaged(usize);
pub const Edge = struct { before: []const u8, after: []const u8 };
pub const OrderResult = struct {
    items: []const []const u8,
    conflicts: []const Edge,
};

const StableKey = struct {
    base_rank: usize,
    side_rank: usize,
    identity: []const u8,
};

const OrderContext = struct {
    base: RankMap,
    ours: RankMap,
    theirs: RankMap,
};

pub fn merge(
    arena: std.mem.Allocator,
    base_ids: []const []const u8,
    ours_ids: []const []const u8,
    theirs_ids: []const []const u8,
) std.mem.Allocator.Error!OrderResult {
    const base = try rankMap(arena, base_ids);
    const ours = try rankMap(arena, ours_ids);
    const theirs = try rankMap(arena, theirs_ids);
    const context = OrderContext{ .base = base, .ours = ours, .theirs = theirs };
    const all_items = try uniqueItems(arena, base_ids, ours_ids, theirs_ids);
    var edges: std.ArrayList(Edge) = .empty;
    var conflicts: std.ArrayList(Edge) = .empty;

    for (all_items, 0..) |first, first_index| {
        for (all_items[first_index + 1 ..]) |second| {
            const base_order = pairOrder(base, first, second);
            const ours_order = pairOrder(ours, first, second);
            const theirs_order = pairOrder(theirs, first, second);
            const selected = if (optionalOrderEqual(ours_order, theirs_order))
                ours_order
            else if (optionalOrderEqual(ours_order, base_order))
                theirs_order
            else if (optionalOrderEqual(theirs_order, base_order))
                ours_order
            else blk: {
                try conflicts.append(arena, canonicalEdge(first, second));
                break :blk null;
            };
            if (selected) |first_is_before| {
                try edges.append(arena, if (first_is_before)
                    .{ .before = first, .after = second }
                else
                    .{ .before = second, .after = first });
            }
        }
    }

    if (conflicts.items.len != 0) {
        sortEdges(conflicts.items);
        return .{
            .items = try stableItems(arena, all_items, context),
            .conflicts = try conflicts.toOwnedSlice(arena),
        };
    }

    const items = stableTopologicalSortWithContext(arena, all_items, edges.items, context) catch |err| switch (err) {
        error.OrderCycle => return .{
            .items = try stableItems(arena, all_items, context),
            .conflicts = blk: {
                sortEdges(edges.items);
                break :blk try edges.toOwnedSlice(arena);
            },
        },
        else => |other| return other,
    };
    return .{ .items = items, .conflicts = &.{} };
}

pub fn stableTopologicalSort(
    arena: std.mem.Allocator,
    items: []const []const u8,
    edges: []const Edge,
) (std.mem.Allocator.Error || error{OrderCycle})![]const []const u8 {
    const ranks = try rankMap(arena, items);
    return stableTopologicalSortWithContext(
        arena,
        items,
        edges,
        .{ .base = ranks, .ours = ranks, .theirs = ranks },
    );
}

fn stableTopologicalSortWithContext(
    arena: std.mem.Allocator,
    items: []const []const u8,
    edges: []const Edge,
    context: OrderContext,
) (std.mem.Allocator.Error || error{OrderCycle})![]const []const u8 {
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    var result: std.ArrayList([]const u8) = .empty;
    while (result.items.len < items.len) {
        var ready: ?[]const u8 = null;
        for (items) |candidate| {
            if (selected.contains(candidate) or hasUnselectedPredecessor(candidate, edges, selected)) continue;
            if (ready == null or stableLessThan(context, candidate, ready.?)) ready = candidate;
        }
        const next = ready orelse return error.OrderCycle;
        try selected.put(arena, next, {});
        try result.append(arena, next);
    }
    return result.toOwnedSlice(arena);
}

fn hasUnselectedPredecessor(
    candidate: []const u8,
    edges: []const Edge,
    selected: std.StringHashMapUnmanaged(void),
) bool {
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.after, candidate) and !selected.contains(edge.before)) return true;
    }
    return false;
}

fn uniqueItems(
    arena: std.mem.Allocator,
    base: []const []const u8,
    ours: []const []const u8,
    theirs: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var items: std.ArrayList([]const u8) = .empty;
    inline for (.{ base, ours, theirs }) |side| {
        for (side) |item| {
            const result = try seen.getOrPut(arena, item);
            if (!result.found_existing) try items.append(arena, item);
        }
    }
    return items.toOwnedSlice(arena);
}

fn stableItems(
    arena: std.mem.Allocator,
    items: []const []const u8,
    context: OrderContext,
) std.mem.Allocator.Error![]const []const u8 {
    const result = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, result, context, stableLessThan);
    return result;
}

fn rankMap(arena: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error!RankMap {
    var ranks: RankMap = .empty;
    for (items, 0..) |item, index| try ranks.put(arena, item, index);
    return ranks;
}

fn pairOrder(ranks: RankMap, first: []const u8, second: []const u8) ?bool {
    const first_rank = ranks.get(first) orelse return null;
    const second_rank = ranks.get(second) orelse return null;
    return first_rank < second_rank;
}

fn optionalOrderEqual(a: ?bool, b: ?bool) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn canonicalEdge(first: []const u8, second: []const u8) Edge {
    return if (std.mem.order(u8, first, second) == .lt)
        .{ .before = first, .after = second }
    else
        .{ .before = second, .after = first };
}

fn sortEdges(edges: []Edge) void {
    std.mem.sort(Edge, edges, {}, struct {
        fn lessThan(_: void, a: Edge, b: Edge) bool {
            const before_order = std.mem.order(u8, a.before, b.before);
            if (before_order != .eq) return before_order == .lt;
            return std.mem.order(u8, a.after, b.after) == .lt;
        }
    }.lessThan);
}

fn stableKey(id: []const u8, base: RankMap, ours: RankMap, theirs: RankMap) StableKey {
    return .{
        .base_rank = base.get(id) orelse std.math.maxInt(usize),
        .side_rank = @min(
            ours.get(id) orelse std.math.maxInt(usize),
            theirs.get(id) orelse std.math.maxInt(usize),
        ),
        .identity = id,
    };
}

fn stableLessThan(context: OrderContext, a: []const u8, b: []const u8) bool {
    const a_key = stableKey(a, context.base, context.ours, context.theirs);
    const b_key = stableKey(b, context.base, context.ours, context.theirs);
    if (a_key.base_rank != b_key.base_rank) return a_key.base_rank < b_key.base_rank;
    if (a_key.side_rank != b_key.side_rank) return a_key.side_rank < b_key.side_rank;
    return std.mem.order(u8, a_key.identity, b_key.identity) == .lt;
}

test "merge order: accepts compatible constraints from both sides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try merge(
        arena_state.allocator(),
        &.{ "a", "b", "c" },
        &.{ "b", "a", "c", "d" },
        &.{ "a", "b", "e", "c" },
    );
    try testing.expectEqualSlices([]const u8, &.{ "b", "a", "e", "c", "d" }, result.items);
    try testing.expect(result.conflicts.len == 0);
}

test "merge order: reports opposite order constraints" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try merge(
        arena_state.allocator(),
        &.{ "a", "b", "c" },
        &.{ "b", "a", "c" },
        &.{ "a", "c", "b" },
    );
    try testing.expect(result.conflicts.len != 0);
}

test "merge order: reports a constraint cycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.OrderCycle, stableTopologicalSort(
        arena_state.allocator(),
        &.{ "a", "b", "c" },
        &.{
            .{ .before = "a", .after = "b" },
            .{ .before = "b", .after = "c" },
            .{ .before = "c", .after = "a" },
        },
    ));
}

test "merge order: reports conflicts in the same order after a side swap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try merge(arena, &.{"a"}, &.{ "x", "y", "z", "a" }, &.{ "z", "y", "x", "a" });
    const second = try merge(arena, &.{"a"}, &.{ "z", "y", "x", "a" }, &.{ "x", "y", "z", "a" });

    try testing.expectEqualSlices([]const u8, first.items, second.items);
    try testing.expectEqual(first.conflicts.len, second.conflicts.len);
    for (first.conflicts, second.conflicts) |first_edge, second_edge| {
        try testing.expectEqualStrings(first_edge.before, second_edge.before);
        try testing.expectEqualStrings(first_edge.after, second_edge.after);
    }
}
