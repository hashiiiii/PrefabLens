const std = @import("std");
const merge = @import("merge.zig");
const ctx = @import("merge_context.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const testing = std.testing;
fn context() ctx.Context {
    const snapshot: ctx.Snapshot = .{ .assets = &.{
        .{ .guid = "0464d347790434a4898eef837430e91e", .path = "Source.prefab", .bytes = @embedFile("testdata/collections/unity/Assets/Source.prefab") },
    }, .scripts = &.{.{ .guid = "2fa164009c127473f99613ff893ebea2", .class_name = "AuditBehaviour", .source_hash = "audit", .fields = &.{.{ .path = "items", .kind = .ordered }} }} };
    return .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot };
}
fn rowValue(arena: std.mem.Allocator, bytes: []const u8, path: []const u8) ![]const u8 {
    const parsed = try parser.parseSpanned(arena, bytes);
    const modification = model.findValue(parsed.documents[0].body.map, "m_Modification").?;
    const rows = model.findValue(modification.map, "m_Modifications").?;
    for (rows.seq) |row| {
        const p = model.findValue(row.map, "propertyPath").?;
        if (std.mem.eql(u8, p.scalar, path)) return model.findValue(row.map, "value").?.scalar;
    }
    return error.MissingRow;
}
fn promotionId(plan: *const merge.MergePlan) !merge.OperationId {
    for (plan.operations) |operation| {
        if (merge.isVariantPromotion(plan, operation.id)) return operation.id;
    }
    return error.MissingPromotion;
}
fn localId(plan: *const merge.MergePlan) !merge.OperationId {
    for (plan.operations) |operation| {
        if (operation.collection != null and !merge.isVariantPromotion(plan, operation.id)) return operation.id;
    }
    return error.MissingLocalChoice;
}
fn keepVariantPromotion(arena: std.mem.Allocator, plan: *merge.MergePlan) !void {
    for (plan.operations) |operation| {
        if (!merge.isVariantPromotion(plan, operation.id)) continue;
        try merge.resolve(arena, plan, operation.id, .{ .take = .ours });
        return;
    }
}
test "variant public real remove and edit rebase B and discard inactive C rows" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), context());
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("B", try rowValue(arena, output, "items.Array.data[0].name"));
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[1].speed"));
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[2].speed"));
}

test "variant public real local shrink choice retains deleted B and both append orders" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    inline for (.{ "variant-shrink-and-edit", "variant-both-append" }) |name| {
        inline for (.{ false, true }) |reverse| {
            var built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/" ++ name ++ "/base.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/ours.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/theirs.prefab"), context());
            try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
            const id = try localId(&built.plan);
            if (comptime std.mem.eql(u8, name, "variant-both-append")) {
                const combined = try merge.combinedCollectionValue(arena, &built.plan, id, if (reverse) .theirs_first else .ours_first);
                try merge.resolve(arena, &built.plan, id, .{ .custom = combined });
                try keepVariantPromotion(arena, &built.plan);
                const output = try merge.finish(arena, &built.plan);
                try testing.expectEqualStrings("5", try rowValue(arena, output, "items.Array.size"));
                try testing.expectEqualStrings(if (reverse) "Theirs" else "Ours", try rowValue(arena, output, "items.Array.data[3].name"));
                try testing.expectEqualStrings(if (reverse) "Ours" else "Theirs", try rowValue(arena, output, "items.Array.data[4].name"));
            } else {
                try merge.resolve(arena, &built.plan, id, .{ .take = .theirs });
                try keepVariantPromotion(arena, &built.plan);
                const output = try merge.finish(arena, &built.plan);
                try testing.expectEqualStrings("2", try rowValue(arena, output, "items.Array.size"));
                try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[0].name"));
                try testing.expectEqualStrings("C", try rowValue(arena, output, "items.Array.data[1].name"));
                try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[1].speed"));
            }
        }
    }
}

const small_guid = "00000000000000000000000000000001";
const small_script = "00000000000000000000000000000002";
const small_source = "--- !u!114 &40\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ small_script ++ ", type: 3}\n  items:\n  - name: A\n    speed: 1\n";
fn smallContext(arena: std.mem.Allocator, sources: [4][]const u8) !ctx.Context {
    const snapshots = try arena.alloc(ctx.Snapshot, 4);
    for (sources, snapshots) |bytes, *snapshot| {
        const assets = try arena.alloc(ctx.Asset, 1);
        assets[0] = .{ .guid = small_guid, .path = "Source.prefab", .bytes = bytes };
        snapshot.* = .{ .assets = assets, .scripts = &.{.{ .guid = small_script, .class_name = "ItemBehaviour", .source_hash = "same-script", .fields = &.{.{ .path = "items", .kind = .ordered }} }} };
    }
    return .{ .base = snapshots[0], .ours = snapshots[1], .theirs = snapshots[2], .output = snapshots[3] };
}
fn smallVariant(arena: std.mem.Allocator, content: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "--- !u!1001 &100\nPrefabInstance:\n  m_Modification:\n    m_Modifications:{s}\n  m_SourcePrefab: {{fileID: 100100000, guid: {s}, type: 3}}\n", .{ if (content.len == 0) " []" else content, small_guid });
}
fn smallRow(arena: std.mem.Allocator, path: []const u8, val: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "\n    - target: {{fileID: 40, guid: {s}, type: 3}}\n      propertyPath: {s}\n      value: {s}\n      objectReference: {{fileID: 0}}", .{ small_guid, path, val });
}
test "variant public equal inherited explicit mask survives opposite inheritance" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "items.Array.data[0].speed", "1") }));
    const built = try merge.buildWithContext(arena, base, base, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings("1", try rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.data[0].speed"));
}
test "variant public reset versus edit is local and retains other item field" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const size = try smallRow(arena, "items.Array.size", "1");
    const base = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "1") }));
    const ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].name", "Changed") }));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "99") }));
    var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .theirs });
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expectEqualStrings("Changed", try rowValue(arena, output, "items.Array.data[0].name"));
}

test "variant public no-authorship follows the selected output source" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const empty = try smallVariant(arena, "");
    const edited = try std.mem.replaceOwned(u8, arena, small_source, "speed: 1", "speed: 99");
    const built = try merge.buildWithContext(arena, empty, empty, empty, try smallContext(arena, .{ small_source, small_source, edited, small_source }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const provenance = try merge.variantProvenance(arena, &built.plan);
    try testing.expectEqual(@as(usize, 0), provenance.pending_groups);
    try testing.expectEqual(@as(usize, 0), provenance.effects.len);
    try testing.expectError(error.MissingRow, rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.data[0].speed"));
    const rebased = try merge.buildWithContext(arena, empty, empty, empty, try smallContext(arena, .{ small_source, small_source, edited, edited }));
    try testing.expectError(error.MissingRow, rowValue(arena, try merge.finish(arena, &rebased.plan), "items.Array.data[0].speed"));
}

test "variant public authored leaf survives while other leaves follow the selected source" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = try std.mem.replaceOwned(u8, arena, small_source, "speed: 1", "speed: 1\n    power: 1");
    const theirs_source = try std.mem.replaceOwned(u8, arena, source, "power: 1", "power: 2");
    const empty = try smallVariant(arena, "");
    const ours = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    const built = try merge.buildWithContext(arena, empty, ours, empty, try smallContext(arena, .{ source, source, theirs_source, source }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].power"));
}

test "variant public inherited leaf promotion requires a core decision and reports provenance" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = try std.mem.replaceOwned(u8, arena, small_source, "speed: 1", "speed: 1\n    power: 1");
    const source_two = try std.mem.concat(arena, u8, &.{ source, "  - name: B\n    speed: 2\n    power: 2\n" });
    const ours_source = try std.mem.replaceOwned(u8, arena, source_two, "  - name: A\n    speed: 1\n    power: 1\n  - name: B\n    speed: 2\n    power: 2\n", "  - name: B\n    speed: 2\n    power: 2\n  - name: A\n    speed: 1\n    power: 1\n");
    const size = try smallRow(arena, "items.Array.size", "2");
    const base = try smallVariant(arena, size);
    const ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "99") }));
    var built = try merge.buildWithContext(arena, base, ours, base, try smallContext(arena, .{ source_two, ours_source, source_two, source_two }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    const promotion_id = try promotionId(&built.plan);
    try testing.expectError(error.InvalidResolution, merge.finish(arena, &built.plan));
    const pending = try merge.variantProvenance(arena, &built.plan);
    try testing.expectEqual(@as(usize, 1), pending.pending_groups);
    try testing.expectEqual(@as(usize, 0), pending.effects.len);
    try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .ours });
    const provenance = try merge.variantProvenance(arena, &built.plan);
    try testing.expect(provenance.effects.len > 0);
    for (provenance.effects) |effect| {
        try testing.expectEqual(merge.VariantEffectKind.inherited_to_explicit, effect.kind);
        try testing.expectEqual(promotion_id, effect.decision_operation.?);
    }
    var followed = try merge.buildWithContext(arena, base, ours, base, try smallContext(arena, .{ source_two, ours_source, source_two, source_two }));
    try merge.resolve(arena, &followed.plan, try promotionId(&followed.plan), .{ .take = .theirs });
    try testing.expectEqual(@as(usize, 0), (try merge.variantProvenance(arena, &followed.plan)).effects.len);
    const followed_output = try merge.finish(arena, &followed.plan);
    try testing.expectError(error.MissingRow, rowValue(arena, followed_output, "items.Array.data[0].speed"));
    try testing.expectEqualStrings("99", try rowValue(arena, followed_output, "items.Array.data[1].speed"));
}

test "variant public inherited size promotion requires a core decision" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const empty_source = try std.mem.replaceOwned(u8, arena, small_source, "  items:\n  - name: A\n    speed: 1\n", "  items: []\n");
    const speed = try smallRow(arena, "items.Array.data[0].speed", "99");
    const variant = try smallVariant(arena, speed);
    var built = try merge.buildWithContext(arena, variant, variant, variant, try smallContext(arena, .{ small_source, empty_source, small_source, small_source }));
    const promotion_id = try promotionId(&built.plan);
    try testing.expectError(error.InvalidResolution, merge.finish(arena, &built.plan));
    try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .ours });
    const provenance = try merge.variantProvenance(arena, &built.plan);
    var found_size = false;
    for (provenance.effects) |effect| {
        if (effect.kind == .inherited_size_to_explicit) found_size = true;
    }
    try testing.expect(found_size);
    var followed = try merge.buildWithContext(arena, variant, variant, variant, try smallContext(arena, .{ small_source, empty_source, small_source, small_source }));
    const followed_id = try promotionId(&followed.plan);
    const source_value = try merge.variantPromotionValue(arena, &followed.plan, followed_id, .theirs);
    try testing.expectEqual(@as(usize, 1), source_value.node.?.seq.len);
    try testing.expectEqualStrings("1", model.findValue(source_value.node.?.seq[0].map, "speed").?.scalar);
    try merge.resolve(arena, &followed.plan, followed_id, .{ .take = .theirs });
    const output = try merge.finish(arena, &followed.plan);
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.size"));
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
}

test "variant public promotion preview uses a resolved custom structure" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const ours_source = small_source;
    const theirs_source = try std.mem.replaceOwned(u8, arena, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const variant = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    // The short branch resets an authored size; this is a Variant decision.
    const sized_variant = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    var built = try merge.buildWithContext(arena, sized_variant, variant, sized_variant, try smallContext(arena, .{ source_two, ours_source, theirs_source, source_two }));
    const local_id = try localId(&built.plan);
    const promotion_id = try promotionId(&built.plan);
    const local = for (built.plan.operations) |operation| {
        if (operation.id == local_id) break operation;
    } else return error.MissingLocalChoice;
    const promotion = for (built.plan.operations) |operation| {
        if (operation.id == promotion_id) break operation;
    } else return error.MissingPromotion;
    try testing.expect(std.mem.indexOfScalar(@TypeOf(local.atomic_id), promotion.dependencies, local.atomic_id) != null);
    try testing.expectError(error.InvalidResolution, merge.variantPromotionValue(arena, &built.plan, promotion_id, .ours));
    try merge.resolve(arena, &built.plan, local_id, .{ .custom = "[]" });
    const variant_value = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .ours);
    const source_value = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
    try testing.expectEqual(@as(usize, 1), variant_value.node.?.seq.len);
    try testing.expectEqual(@as(usize, 1), source_value.node.?.seq.len);
    try testing.expectEqualStrings("99", model.findValue(source_value.node.?.seq[0].map, "speed").?.scalar);
    try testing.expectError(error.InvalidResolution, merge.finish(arena, &built.plan));
    try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .ours });
    const provenance = try merge.variantProvenance(arena, &built.plan);
    const effect = for (provenance.effects) |candidate| {
        if (candidate.kind == .inherited_size_to_explicit) break candidate;
    } else return error.MissingSizeEffect;
    try testing.expectEqualStrings("2", effect.source_value.?.scalar);
    try testing.expectEqualStrings("1", effect.result_value.?.scalar);
}

test "variant public Source choice rebases an authored leaf by proven item correspondence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const ours_source = try std.mem.replaceOwned(
        u8,
        arena,
        source_two,
        "  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n",
        "  - name: B\n    speed: 2\n  - name: A\n    speed: 1\n",
    );
    const size = try smallRow(arena, "items.Array.size", "2");
    const base = try smallVariant(arena, size);
    const edited = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "99") }));
    inline for (.{ false, true }) |edit_is_ours| {
        const ours = if (edit_is_ours) edited else base;
        const theirs = if (edit_is_ours) base else edited;
        const ours_revision = if (edit_is_ours) ours_source else source_two;
        const theirs_revision = if (edit_is_ours) source_two else ours_source;
        var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ source_two, ours_revision, theirs_revision, source_two }));
        const promotion_id = try promotionId(&built.plan);

        const preview = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
        try testing.expectEqualStrings("[{name: A, speed: 1}, {name: B, speed: 99}]", preview.bytes);

        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[1].speed"));
    }
}

test "variant public Source choice prefers provenance to coincidental exact value matches in both directions" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const moved = try std.mem.replaceOwned(
        u8,
        arena,
        source_two,
        "  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n",
        "  - name: B\n    speed: 2\n  - name: A\n    speed: 1\n",
    );
    const size = try smallRow(arena, "items.Array.size", "2");
    const base = try smallVariant(arena, size);
    const edited = try smallVariant(arena, try std.mem.concat(arena, u8, &.{
        size,
        try smallRow(arena, "items.Array.data[0].name", "A"),
        try smallRow(arena, "items.Array.data[0].speed", "1"),
    }));
    inline for (.{ false, true }) |edit_is_ours| {
        var built = try merge.buildWithContext(arena, base, if (edit_is_ours) edited else base, if (edit_is_ours) base else edited, try smallContext(arena, .{ source_two, if (edit_is_ours) moved else source_two, if (edit_is_ours) source_two else moved, source_two }));
        const promotion_id = try promotionId(&built.plan);
        try testing.expectEqualStrings("[{name: A, speed: 1}, {name: A, speed: 1}]", (try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs)).bytes);
        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("2", try rowValue(arena, output, "items.Array.size"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].name"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[1].name"));
        try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[1].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[2].name"));
    }
}

test "variant public Source choice retains equal inherited occurrences after destination collisions" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_three = try std.mem.concat(arena, u8, &.{ small_source, "  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n" });
    const output_source = try std.mem.replaceOwned(
        u8,
        arena,
        source_three,
        "  - name: A\n    speed: 1\n  - name: A\n    speed: 1\n",
        "  - name: A\n    speed: 1\n  - name: C\n    speed: 3\n",
    );
    const moved = try std.mem.replaceOwned(
        u8,
        arena,
        source_three,
        "  - name: A\n    speed: 1\n  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n",
        "  - name: B\n    speed: 2\n  - name: A\n    speed: 1\n  - name: A\n    speed: 1\n",
    );
    const size = try smallRow(arena, "items.Array.size", "3");
    const base = try smallVariant(arena, size);
    const edited = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "99") }));
    inline for (.{ false, true }) |edit_is_ours| {
        var built = try merge.buildWithContext(arena, base, if (edit_is_ours) edited else base, if (edit_is_ours) base else edited, try smallContext(arena, .{ source_three, if (edit_is_ours) moved else source_three, if (edit_is_ours) source_three else moved, output_source }));
        for (built.plan.operations) |operation| {
            if (operation.resolution == .unresolved and !merge.isVariantPromotion(&built.plan, operation.id))
                try merge.resolve(arena, &built.plan, operation.id, .{ .take = if (edit_is_ours) .ours else .theirs });
        }
        const promotion_id = try promotionId(&built.plan);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try testing.expectError(error.InvalidResolution, merge.finish(arena, &built.plan));
        try testing.expectEqual(@as(usize, 1), (try merge.variantProvenance(arena, &built.plan)).pending_groups);
        const preview = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
        try testing.expectEqualStrings("[{name: B, speed: 99}, {name: A, speed: 1}, {name: A, speed: 1}]", preview.bytes);
        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const provenance = try merge.variantProvenance(arena, &built.plan);
        try testing.expectEqual(@as(usize, 0), provenance.pending_groups);
        try testing.expect(provenance.effects.len > 0);
        for (provenance.effects) |effect| try testing.expectEqual(promotion_id, effect.decision_operation.?);
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("3", try rowValue(arena, output, "items.Array.size"));
        try testing.expectEqualStrings("B", try rowValue(arena, output, "items.Array.data[0].name"));
        try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
        inline for (.{ "1", "2" }) |index| {
            try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[" ++ index ++ "].name"));
            try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[" ++ index ++ "].speed"));
        }
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[3].name"));
    }
}

test "variant public Source choice retains originless custom duplicate occurrences" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const changed_source = try std.mem.replaceOwned(u8, arena, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const variant = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    // The short branch resets an authored size; this is a Variant decision.
    const sized_variant = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    inline for (.{ false, true }) |short_is_ours| {
        var built = try merge.buildWithContext(arena, sized_variant, if (short_is_ours) variant else sized_variant, if (short_is_ours) sized_variant else variant, try smallContext(arena, .{ source_two, if (short_is_ours) small_source else changed_source, if (short_is_ours) changed_source else small_source, source_two }));
        try merge.resolve(arena, &built.plan, try localId(&built.plan), .{ .custom = "[{name: A, speed: 1}, {name: A, speed: 1}]" });
        const promotion_id = try promotionId(&built.plan);
        try testing.expectEqualStrings("[{name: A, speed: 99}, {name: A, speed: 1}, {name: A, speed: 1}]", (try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs)).bytes);
        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("3", try rowValue(arena, output, "items.Array.size"));
        try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
        inline for (.{ "1", "2" }) |index| {
            try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[" ++ index ++ "].name"));
            try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[" ++ index ++ "].speed"));
        }
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[3].name"));
    }
}

test "variant public Source choice keeps a proven destination when a custom exact match competes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const changed_source = try std.mem.replaceOwned(u8, arena, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const output_source = try std.mem.replaceOwned(
        u8,
        arena,
        source_two,
        "  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n",
        "  - name: B\n    speed: 2\n  - name: A\n    speed: 1\n",
    );
    const variant = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    // The short branch resets an authored size; this is a Variant decision.
    const sized_variant = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    inline for (.{ false, true }) |short_is_ours| {
        var built = try merge.buildWithContext(arena, sized_variant, if (short_is_ours) variant else sized_variant, if (short_is_ours) sized_variant else variant, try smallContext(arena, .{ source_two, if (short_is_ours) small_source else changed_source, if (short_is_ours) changed_source else small_source, output_source }));
        try merge.resolve(arena, &built.plan, try localId(&built.plan), .{ .custom = "[{name: B, speed: 2}, {name: A, speed: 1}]" });
        const promotion_id = try promotionId(&built.plan);
        try testing.expectEqualStrings("[{name: B, speed: 2}, {name: A, speed: 99}, {name: A, speed: 1}]", (try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs)).bytes);
        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("3", try rowValue(arena, output, "items.Array.size"));
        try testing.expectEqualStrings("B", try rowValue(arena, output, "items.Array.data[0].name"));
        try testing.expectEqualStrings("2", try rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[1].name"));
        try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[1].speed"));
        try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[2].name"));
        try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[2].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[3].name"));
    }
}

test "variant public Source choice preserves accepted custom data without duplicate tail items" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const theirs_source = try std.mem.replaceOwned(u8, arena, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const variant = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    // The short branch resets an authored size; this is a Variant decision.
    const sized_variant = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    inline for (.{ false, true }) |short_source_is_ours| {
        const ours_source = if (short_source_is_ours) small_source else theirs_source;
        const theirs_revision = if (short_source_is_ours) theirs_source else small_source;
        var built = try merge.buildWithContext(arena, sized_variant, if (short_source_is_ours) variant else sized_variant, if (short_source_is_ours) sized_variant else variant, try smallContext(arena, .{ source_two, ours_source, theirs_revision, source_two }));
        const local_id = try localId(&built.plan);
        const promotion_id = try promotionId(&built.plan);
        try merge.resolve(arena, &built.plan, local_id, .{ .custom = "[{name: A, speed: 77}, {name: B, speed: 2}]" });

        const preview = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
        try testing.expectEqualStrings("[{name: A, speed: 99}, {name: A, speed: 77}, {name: B, speed: 2}]", preview.bytes);

        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("3", try rowValue(arena, output, "items.Array.size"));
        try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectEqualStrings("A", try rowValue(arena, output, "items.Array.data[1].name"));
        try testing.expectEqualStrings("77", try rowValue(arena, output, "items.Array.data[1].speed"));
        try testing.expectEqualStrings("B", try rowValue(arena, output, "items.Array.data[2].name"));
        try testing.expectEqualStrings("2", try rowValue(arena, output, "items.Array.data[2].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[3].name"));
    }
}

test "variant public Source choice rejects custom nonempty-source growth with incomplete item coverage" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const theirs_source = try std.mem.replaceOwned(u8, arena, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const variant = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "99"));
    // The short branch resets an authored size; this is a Variant decision.
    const sized_variant = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    var built = try merge.buildWithContext(arena, sized_variant, variant, sized_variant, try smallContext(arena, .{ source_two, small_source, theirs_source, source_two }));
    const promotion_id = try promotionId(&built.plan);
    try merge.resolve(arena, &built.plan, try localId(&built.plan), .{ .custom = "[{name: A, speed: 77}, {name: B}]" });
    try testing.expectError(error.InvalidResolution, merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs }));
    try testing.expectEqual(merge.Resolution.unresolved, (for (built.plan.operations) |operation| {
        if (operation.id == promotion_id) break operation.resolution;
    } else return error.MissingPromotion));
}

test "variant public Source choice keeps an accepted reset and rejects the edited row in both directions" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_two = try std.mem.concat(arena, u8, &.{ small_source, "  - name: B\n    speed: 2\n" });
    const edited_source = try std.mem.replaceOwned(
        u8,
        arena,
        source_two,
        "  - name: A\n    speed: 1\n  - name: B\n    speed: 2\n",
        "  - name: B\n    speed: 2\n  - name: A\n    speed: 1\n",
    );
    const size = try smallRow(arena, "items.Array.size", "2");
    const base = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "5") }));
    const reset = try smallVariant(arena, size);
    const edited = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, try smallRow(arena, "items.Array.data[0].speed", "99") }));

    inline for (.{ false, true }) |reset_is_ours| {
        const ours = if (reset_is_ours) reset else edited;
        const theirs = if (reset_is_ours) edited else reset;
        const ours_source = if (reset_is_ours) source_two else edited_source;
        const theirs_source = if (reset_is_ours) edited_source else source_two;
        var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ source_two, ours_source, theirs_source, source_two }));
        const reset_side: merge.Side = if (reset_is_ours) .ours else .theirs;
        for (built.plan.operations) |operation| {
            if (operation.resolution == .unresolved and !merge.isVariantPromotion(&built.plan, operation.id)) {
                try merge.resolve(arena, &built.plan, operation.id, .{ .take = reset_side });
            }
        }
        const promotion_id = try promotionId(&built.plan);
        const source_preview = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
        try testing.expectEqualStrings("[{name: A, speed: 1}, {name: B, speed: 2}]", source_preview.bytes);

        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("2", try rowValue(arena, output, "items.Array.size"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[1].speed"));
    }
}

test "variant public Source choice keeps an accepted item removal in both directions" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = try std.mem.replaceOwned(u8, arena, small_source, "speed: 1", "speed: 1\n    power: 1");
    const source_two = try std.mem.concat(arena, u8, &.{ source, "  - name: B\n    speed: 2\n    power: 2\n" });
    const edited_source = try std.mem.replaceOwned(u8, arena, source_two, "power: 1", "power: 9");
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "2"));
    const removed = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const edited = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[1].speed", "99") }));

    inline for (.{ false, true }) |removal_is_ours| {
        const ours = if (removal_is_ours) removed else edited;
        const theirs = if (removal_is_ours) edited else removed;
        const ours_source = if (removal_is_ours) source_two else edited_source;
        const theirs_source = if (removal_is_ours) edited_source else source_two;
        var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ source_two, ours_source, theirs_source, source_two }));
        const removal_side: merge.Side = if (removal_is_ours) .ours else .theirs;
        for (built.plan.operations) |operation| {
            if (operation.resolution == .unresolved and !merge.isVariantPromotion(&built.plan, operation.id)) {
                try merge.resolve(arena, &built.plan, operation.id, .{ .take = removal_side });
            }
        }
        const promotion_id = try promotionId(&built.plan);
        const source_preview = try merge.variantPromotionValue(arena, &built.plan, promotion_id, .theirs);
        try testing.expectEqualStrings("[{name: A, speed: 1, power: 1}]", source_preview.bytes);

        try merge.resolve(arena, &built.plan, promotion_id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.size"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
        try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[1].name"));
    }
}

test "variant public size reset conflicts with an opposite size edit" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const ours = try smallVariant(arena, "");
    const theirs = try smallVariant(arena, try smallRow(arena, "items.Array.size", "0"));
    var reset = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), reset.plan.unresolvedCount());
    try merge.resolve(arena, &reset.plan, try localId(&reset.plan), .{ .take = .ours });
    try keepVariantPromotion(arena, &reset.plan);
    try testing.expectError(error.MissingRow, rowValue(arena, try merge.finish(arena, &reset.plan), "items.Array.size"));

    var edited = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try merge.resolve(arena, &edited.plan, try localId(&edited.plan), .{ .take = .theirs });
    try keepVariantPromotion(arena, &edited.plan);
    try testing.expectEqualStrings("0", try rowValue(arena, try merge.finish(arena, &edited.plan), "items.Array.size"));
}

test "variant public collection row formatting merges independently from values" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const size = try smallRow(arena, "items.Array.size", "1");
    const speed = try smallRow(arena, "items.Array.data[0].speed", "1");
    const base = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, speed }));

    const theirs_comment = try std.mem.replaceOwned(u8, arena, speed, "value: 1", "value: 1 # theirs comment");
    const comment_only = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, theirs_comment }));
    var comment_plan = try merge.buildWithContext(arena, base, base, comment_only, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    const comment_output = try merge.finish(arena, &comment_plan.plan);
    try testing.expect(std.mem.indexOf(u8, comment_output, "value: 1 # theirs comment") != null);

    const ours_comment = try std.mem.replaceOwned(u8, arena, speed, "value: 1", "value: 1 # ours comment");
    const ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, ours_comment }));
    const theirs_value = try std.mem.replaceOwned(u8, arena, speed, "value: 1", "value: 99");
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, theirs_value }));
    var merged_plan = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    const merged = try merge.finish(arena, &merged_plan.plan);
    try testing.expect(std.mem.indexOf(u8, merged, "value: 99 # ours comment") != null);

    const ours_size = try std.mem.replaceOwned(u8, arena, size, "value: 1", "value: 1 # ours size comment");
    const size_ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ ours_size, speed }));
    const theirs_size = try std.mem.replaceOwned(u8, arena, size, "value: 1", "value: 0");
    const size_theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ theirs_size, speed }));
    var size_plan = try merge.buildWithContext(arena, base, size_ours, size_theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    const size_output = try merge.finish(arena, &size_plan.plan);
    try testing.expect(std.mem.indexOf(u8, size_output, "value: 0 # ours size comment") != null);
}

test "variant public collection row formatting ambiguity has a usable choice" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const size = try smallRow(arena, "items.Array.size", "1");
    const speed = try smallRow(arena, "items.Array.data[0].speed", "1");
    const base = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, speed }));
    const ours_speed = try std.mem.replaceOwned(u8, arena, speed, "value: 1", "value: 1 # ours bytes");
    const theirs_speed = try std.mem.replaceOwned(u8, arena, speed, "value: 1", "value: 1 # theirs bytes");
    const ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, ours_speed }));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ size, theirs_speed }));
    var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqual(@import("merge_value.zig").Reason.source_bytes, merge.collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
    try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
    const output = try merge.finish(arena, &built.plan);
    try testing.expect(std.mem.indexOf(u8, output, "value: 1 # ours bytes") != null);
    try testing.expect(std.mem.indexOf(u8, output, "theirs bytes") == null);
}

test "variant public rebasing does not copy formatting from another item" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const ours = try std.mem.replaceOwned(u8, arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), "propertyPath: items.Array.data[1].speed\n      value: 1", "propertyPath: items.Array.data[1].speed\n      value: 1 # C comment");
    const built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), ours, @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), context());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expect(std.mem.indexOf(u8, output, "value: 99 # C comment") == null);
    try testing.expect(std.mem.indexOf(u8, output, "value: 1 # C comment") != null);
}

test "variant public real dictionary regressions use keys and preserve local choices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const snapshot: ctx.Snapshot = .{ .assets = &.{.{ .guid = "7c59a080e2ebf41a5aa9b8f70a414e5b", .path = "DictionarySource.prefab", .bytes = @embedFile("testdata/collections/unity/Assets/DictionarySource.prefab") }}, .scripts = &.{.{ .guid = "2fa164009c127473f99613ff893ebea2", .class_name = "AuditBehaviour", .source_hash = "audit", .fields = &.{.{ .path = "counts", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }} }} };
    inline for (.{ "variant-dictionary-independent-values", "variant-dictionary-remove-and-edit", "variant-dictionary-shrink-and-edit" }) |name| {
        var built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/" ++ name ++ "/base.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/ours.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/theirs.prefab"), .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot });
        const shrink = comptime std.mem.eql(u8, name, "variant-dictionary-shrink-and-edit");
        try testing.expectEqual(@as(usize, if (shrink) 1 else 0), built.plan.unresolvedCount());
        if (shrink) try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        if (comptime std.mem.eql(u8, name, "variant-dictionary-independent-values")) {
            try testing.expectEqualStrings("10", try rowValue(arena, output, "counts.Array.data[0].value"));
            try testing.expectEqualStrings("30", try rowValue(arena, output, "counts.Array.data[2].value"));
        } else {
            try testing.expectEqualStrings("2", try rowValue(arena, output, "counts.Array.size"));
            try testing.expectEqualStrings(if (shrink) "A" else "B", try rowValue(arena, output, "counts.Array.data[0].key"));
            try testing.expectEqualStrings("C", try rowValue(arena, output, "counts.Array.data[1].key"));
            try testing.expectEqualStrings("99", try rowValue(arena, output, if (shrink) "counts.Array.data[1].value" else "counts.Array.data[0].value"));
        }
    }
}

test "variant public missing schema and missing source expose usable group choices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    inline for (.{ true, false }) |missing_source| {
        var c = context();
        if (missing_source) c.output.assets = &.{} else c.output.scripts = &.{};
        var built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), c);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try testing.expectEqual(@import("merge_value.zig").Reason.context_required, merge.collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
        try testing.expectError(error.InvalidResolution, merge.finish(arena, &built.plan));
        try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings("B", try rowValue(arena, output, "items.Array.data[0].name"));
    }
}

test "variant public replay preserves omitted hidden member across removal and growth" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const replay_source = @embedFile("testdata/collections/replay/ReplaySource.prefab");
    const replay_base = @embedFile("testdata/collections/replay/base.prefab");
    const file = try parser.parseSpanned(arena, replay_source);
    const script = for (file.documents) |doc| {
        if (doc.class_id == 114) break model.findValue(doc.body.map, "m_Script").?.ref.guid.?;
    } else unreachable;
    const variant = try parser.parseSpanned(arena, replay_base);
    const guid = model.findValue(variant.documents[0].body.map, "m_SourcePrefab").?.ref.guid.?;
    const scripts = try arena.alloc(ctx.Script, 1);
    scripts[0] = .{ .guid = script, .class_name = "ReplayBehaviour", .source_hash = "replay-source", .fields = &.{.{ .path = "items", .kind = .ordered }} };
    const assets = try arena.alloc(ctx.Asset, 1);
    assets[0] = .{ .guid = guid, .path = "ReplaySource.prefab", .bytes = replay_source };
    const snapshot: ctx.Snapshot = .{ .assets = assets, .scripts = scripts };
    const c: ctx.Context = .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot };
    const built = try merge.buildWithContext(arena, replay_base, @embedFile("testdata/collections/replay/remove.prefab"), @embedFile("testdata/collections/replay/edit-b.prefab"), c);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expect(std.mem.indexOf(u8, output, "hidden") == null);
    var appended = try merge.buildWithContext(arena, replay_base, @embedFile("testdata/collections/replay/append-ours.prefab"), @embedFile("testdata/collections/replay/append-theirs.prefab"), c);
    try testing.expectEqual(@as(usize, 1), appended.plan.unresolvedCount());
    const id = try localId(&appended.plan);
    try merge.resolve(arena, &appended.plan, id, .{ .custom = try merge.combinedCollectionValue(arena, &appended.plan, id, .ours_first) });
    try keepVariantPromotion(arena, &appended.plan);
    const growth = try merge.finish(arena, &appended.plan);
    try testing.expectEqualStrings("5", try rowValue(arena, growth, "items.Array.size"));
    try testing.expect(std.mem.indexOf(u8, growth, "hidden") == null);
}

test "variant public sparse custom omitted coverage is rejected without changing resolution" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-both-append/base.prefab"), @embedFile("testdata/collections/cases/variant-both-append/ours.prefab"), @embedFile("testdata/collections/cases/variant-both-append/theirs.prefab"), context());
    try testing.expectError(error.InvalidResolution, merge.resolve(arena, &built.plan, try localId(&built.plan), .{ .custom = "[{name: Broken}]" }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "variant public discovers all declared source collections including blank packed arrays" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var c = context();
    const scripts = try arena.dupe(ctx.Script, c.base.scripts);
    scripts[0].fields = &.{ .{ .path = "items", .kind = .ordered }, .{ .path = "names", .kind = .ordered }, .{ .path = "numbers", .kind = .int32_array }, .{ .path = "counts", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default } };
    c.base.scripts = scripts;
    c.ours.scripts = scripts;
    c.theirs.scripts = scripts;
    c.output.scripts = scripts;
    const built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), c);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings("99", try rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.data[0].speed"));
}

test "variant public deletion conflicts with equal-value explicit intent at only deleted item" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const ours = try smallVariant(arena, try smallRow(arena, "items.Array.size", "0"));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "items.Array.data[0].speed", "1") }));
    var built = try merge.buildWithContext(arena, base, ours, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try merge.resolve(arena, &built.plan, try localId(&built.plan), .{ .take = .theirs });
    try keepVariantPromotion(arena, &built.plan);
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.size"));
    try testing.expectEqualStrings("1", try rowValue(arena, output, "items.Array.data[0].speed"));
}

test "variant public real unrelated scalar overrides merge and resolve in authored order" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    inline for (.{ "variant-independent-fields", "variant-same-field" }) |name| {
        var built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/" ++ name ++ "/base.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/ours.prefab"), @embedFile("testdata/collections/cases/" ++ name ++ "/theirs.prefab"), context());
        const conflict = comptime std.mem.eql(u8, name, "variant-same-field");
        try testing.expectEqual(@as(usize, if (conflict) 1 else 0), built.plan.unresolvedCount());
        if (conflict) try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .theirs });
        const output = try merge.finish(arena, &built.plan);
        try testing.expectEqualStrings(if (conflict) "20" else "10", try rowValue(arena, output, "left"));
        if (!conflict) try testing.expectEqualStrings("20", try rowValue(arena, output, "right"));
    }
}

test "variant public nested empty-source recipe preserves inherited rows" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const empty_source = "--- !u!114 &40\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ small_script ++ ", type: 3}\n  items: []\n";
    const middle = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "items.Array.data[0].name", "A"), try smallRow(arena, "items.Array.data[0].speed", "1") }));
    const middle_guid = "00000000000000000000000000000003";
    var c = try smallContext(arena, .{ empty_source, empty_source, empty_source, empty_source });
    const assets = try arena.alloc(ctx.Asset, 2);
    assets[0] = c.base.assets[0];
    assets[1] = .{ .guid = middle_guid, .path = "Middle.prefab", .bytes = middle };
    c.base.assets = assets;
    c.ours.assets = assets;
    c.theirs.assets = assets;
    c.output.assets = assets;
    const base_old = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "2"));
    const base_guid = try std.mem.replaceOwned(u8, arena, base_old, small_guid, middle_guid);
    const base = try std.mem.replaceOwned(u8, arena, base_guid, "fileID: 40,", "fileID: 76,");
    const theirs = try std.mem.replaceOwned(u8, arena, base, "value: 2", "value: 99");
    const built = try merge.buildWithContext(arena, base, base, theirs, c);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].name"));
}

test "variant public duplicate active paths and malformed indices require manual group choices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    inline for (.{ false, true }) |malformed| {
        const changed = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, if (malformed) "items.Array.data[-1].speed" else "items.Array.size", "2") }));
        var built = try merge.buildWithContext(arena, base, base, changed, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
        try testing.expect(built.plan.unresolvedCount() > 0);
        for (built.plan.operations) |operation| if (operation.resolution == .unresolved) try merge.resolve(arena, &built.plan, operation.id, .{ .take = .ours });
        try testing.expectEqualStrings("1", try rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.size"));
    }
}

test "variant public known null references retain the objectReference channel" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_bytes = try std.mem.replaceOwned(u8, arena, small_source, "speed: 1", "speed: 1\n    target: {fileID: 0}");
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const ref_row = try smallRow(arena, "items.Array.data[0].target", "");
    const theirs_row = try std.mem.replaceOwned(u8, arena, ref_row, "objectReference: {fileID: 0}", "objectReference: {fileID: 123, guid: 00000000000000000000000000000009, type: 3}");
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), theirs_row }));
    const built = try merge.buildWithContext(arena, base, base, theirs, try smallContext(arena, .{ source_bytes, source_bytes, source_bytes, source_bytes }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expect(std.mem.indexOf(u8, output, "objectReference: {fileID: 123,") != null);
}

test "variant public CRLF comments survive rebased rows and unresolved partial keeps ours collection" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const b = @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab");
    const o = @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab");
    const t = try std.mem.replaceOwned(u8, arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), "value: 99", "value: 99 # edited B");
    const base = try std.mem.replaceOwned(u8, arena, b, "\n", "\r\n");
    const ours = try std.mem.replaceOwned(u8, arena, o, "\n", "\r\n");
    const theirs = try std.mem.replaceOwned(u8, arena, t, "\n", "\r\n");
    const built = try merge.buildWithContext(arena, base, ours, theirs, context());
    const output = try merge.finish(arena, &built.plan);
    try testing.expect(std.mem.indexOf(u8, output, "value: 99 # edited B\r\n") != null);
    for (output, 0..) |byte, i| if (byte == '\n') try testing.expect(i > 0 and output[i - 1] == '\r');
    const shrink = @embedFile("testdata/collections/cases/variant-shrink-and-edit/ours.prefab");
    const partial = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-shrink-and-edit/base.prefab"), shrink, @embedFile("testdata/collections/cases/variant-shrink-and-edit/theirs.prefab"), context());
    try testing.expectEqualStrings("1", try rowValue(arena, partial.partial, "items.Array.size"));
    try testing.expectEqualStrings(shrink, partial.plan.ours.bytes);
}

test "variant public complete source-only removal and edit avoid freezing inherited names" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source_base = small_source ++ "  - name: B\n    speed: 2\n  - name: C\n    speed: 3\n";
    const source_ours = try std.mem.replaceOwned(u8, arena, source_base, "  - name: A\n    speed: 1\n", "");
    const source_theirs = try std.mem.replaceOwned(u8, arena, source_base, "speed: 2", "speed: 99");
    const variant = try smallVariant(arena, "");
    const built = try merge.buildWithContext(arena, variant, variant, variant, try smallContext(arena, .{ source_base, source_ours, source_theirs, source_ours }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[0].name"));
}

test "variant public no-authorship requires an established selected source" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const empty = try smallVariant(arena, "");
    inline for (.{ false, true }) |ambiguous| inline for (.{ false, true }) |missing_schema| {
        var c = try smallContext(arena, .{ small_source, small_source, small_source, small_source });
        if (ambiguous) c.output.assets = try std.mem.concat(arena, ctx.Asset, &.{ c.output.assets, c.output.assets }) else c.output.assets = &.{};
        if (missing_schema) {
            c.base.scripts = &.{};
            c.ours.scripts = &.{};
            c.theirs.scripts = &.{};
            c.output.scripts = &.{};
        }
        const built = try merge.buildWithContext(arena, empty, empty, empty, c);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try testing.expectEqual(@import("merge_value.zig").Reason.context_required, merge.collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
    };
}

test "variant public inactive authored rows still require output context" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const rows = try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "0"), try smallRow(arena, "items.Array.data[0].speed", "99") });
    const variant = try smallVariant(arena, rows);
    var c = try smallContext(arena, .{ small_source, small_source, small_source, small_source });
    c.output.scripts = &.{};
    const built = try merge.buildWithContext(arena, variant, variant, variant, c);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqual(@import("merge_value.zig").Reason.context_required, merge.collectionConflict(&built.plan, built.plan.operations[0].id).?.reason);
}

test "variant public size reset preserves inherited size without reintroducing row" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const ours = try smallVariant(arena, "");
    const built = try merge.buildWithContext(arena, base, ours, base, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectError(error.MissingRow, rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.size"));
}

test "variant public source GUID change requires explicit linked source and group choices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.data[0].speed", "2"));
    const new_guid = "00000000000000000000000000000004";
    const theirs = try std.mem.replaceOwned(u8, arena, base, small_guid, new_guid);
    var c = try smallContext(arena, .{ small_source, small_source, small_source, small_source });
    const assets = try arena.alloc(ctx.Asset, 2);
    assets[0] = c.base.assets[0];
    assets[1] = .{ .guid = new_guid, .path = "Other.prefab", .bytes = small_source };
    c.base.assets = assets;
    c.ours.assets = assets;
    c.theirs.assets = assets;
    c.output.assets = assets;
    var built = try merge.buildWithContext(arena, base, base, theirs, c);
    var source_choice: ?merge.OperationId = null;
    for (built.plan.operations) |op| if (std.mem.eql(u8, op.property_path, "m_SourcePrefab")) {
        source_choice = op.id;
        try testing.expect(op.resolution == .unresolved);
    };
    try testing.expect(source_choice != null);
    for (built.plan.operations) |op| if (op.collection != null and op.resolution == .unresolved) try merge.resolve(arena, &built.plan, op.id, .{ .take = .theirs });
    try testing.expectError(error.InvalidResolution, merge.resolve(arena, &built.plan, source_choice.?, .{ .take = .ours }));
    try merge.resolve(arena, &built.plan, source_choice.?, .{ .take = .theirs });
    try testing.expect(std.mem.indexOf(u8, try merge.finish(arena, &built.plan), new_guid) != null);
}

test "variant public unequal sparse coverage conflicts only affected item and preserves C edit" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = @embedFile("testdata/collections/cases/variant-shrink-and-edit/base.prefab");
    const parsed = try parser.parseSpanned(arena, base);
    const rows = @import("merge_variant_value.zig").rows(&parsed.documents[0]).?;
    var removed: ?@import("source.zig").Span = null;
    for (rows.seq) |r| if (std.mem.eql(u8, model.findValue(r.map, "propertyPath").?.scalar, "items.Array.data[1].speed")) {
        removed = parsed.sequence_item_spans.get(r).?;
        break;
    };
    const span = removed.?;
    const ours = try std.mem.concat(arena, u8, &.{ base[0..span.start], base[span.end..] });
    var built = try merge.buildWithContext(arena, base, ours, @embedFile("testdata/collections/cases/variant-shrink-and-edit/theirs.prefab"), context());
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    const op = built.plan.operations[0];
    try testing.expect(op.values.ours.?.node.?.* == .map);
    try merge.resolve(arena, &built.plan, op.id, .{ .take = .ours });
    const output = try merge.finish(arena, &built.plan);
    try testing.expectError(error.MissingRow, rowValue(arena, output, "items.Array.data[1].speed"));
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[2].speed"));
}

test "variant public absent declared source field does not block present collection" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var c = try smallContext(arena, .{ small_source, small_source, small_source, small_source });
    const scripts = try arena.dupe(ctx.Script, c.base.scripts);
    scripts[0].fields = &.{ .{ .path = "items", .kind = .ordered }, .{ .path = "absent", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default } };
    c.base.scripts = scripts;
    c.ours.scripts = scripts;
    c.theirs.scripts = scripts;
    c.output.scripts = scripts;
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    const built = try merge.buildWithContext(arena, base, base, theirs, c);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings("99", try rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.data[0].speed"));
}

test "variant public nonempty-source growth and changed sparse script require explicit recipes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const ours = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "2"), try smallRow(arena, "items.Array.data[1].name", "New") }));
    var built = try merge.buildWithContext(arena, base, ours, base, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
    try testing.expectEqualStrings("2", try rowValue(arena, try merge.finish(arena, &built.plan), "items.Array.size"));
    var c = context();
    const scripts = try arena.dupe(ctx.Script, c.output.scripts);
    scripts[0].source_hash = "changed-script";
    c.output.scripts = scripts;
    const sparse = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), c);
    try testing.expectEqual(@as(usize, 1), sparse.plan.unresolvedCount());
}

test "variant public ambiguous and cyclic sources remain manually resolvable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    inline for (.{ false, true }) |cycle| {
        var c = try smallContext(arena, .{ small_source, small_source, small_source, small_source });
        if (cycle) {
            const assets = try arena.dupe(ctx.Asset, c.output.assets);
            assets[0].bytes = base;
            c.output.assets = assets;
        } else c.output.assets = try std.mem.concat(arena, ctx.Asset, &.{ c.output.assets, c.output.assets });
        var built = try merge.buildWithContext(arena, base, base, base, c);
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
        _ = try merge.finish(arena, &built.plan);
    }
}

test "variant public unrelated override comment survives collection rebasing" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const theirs = try std.mem.replaceOwned(u8, arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/theirs.prefab"), "value: Variant", "value: Variant # keep unrelated comment");
    const built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-remove-and-edit/ours.prefab"), theirs, context());
    const output = try merge.finish(arena, &built.plan);
    try testing.expect(std.mem.indexOf(u8, output, "value: Variant # keep unrelated comment") != null);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
}

test "variant public output dictionary equality evidence cannot be borrowed from base" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const known: ctx.Snapshot = .{ .assets = &.{.{ .guid = "7c59a080e2ebf41a5aa9b8f70a414e5b", .path = "DictionarySource.prefab", .bytes = @embedFile("testdata/collections/unity/Assets/DictionarySource.prefab") }}, .scripts = &.{.{ .guid = "2fa164009c127473f99613ff893ebea2", .class_name = "AuditBehaviour", .source_hash = "audit", .fields = &.{.{ .path = "counts", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }} }} };
    var unknown = known;
    const scripts = try arena.dupe(ctx.Script, known.scripts);
    scripts[0].fields = &.{.{ .path = "counts", .kind = .string_dictionary, .dictionary_value = .int32 }};
    unknown.scripts = scripts;
    const built = try merge.buildWithContext(arena, @embedFile("testdata/collections/cases/variant-dictionary-remove-and-edit/base.prefab"), @embedFile("testdata/collections/cases/variant-dictionary-remove-and-edit/ours.prefab"), @embedFile("testdata/collections/cases/variant-dictionary-remove-and-edit/theirs.prefab"), .{ .base = known, .ours = known, .theirs = known, .output = unknown });
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "variant public duplicate unrelated override rows remain visible for manual repair" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "left", "1") }));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "left", "1"), try smallRow(arena, "left", "2") }));
    var built = try merge.buildWithContext(arena, base, base, theirs, try smallContext(arena, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .ours });
    try testing.expectEqualStrings("1", try rowValue(arena, try merge.finish(arena, &built.plan), "left"));
}

test "variant public dictionary key explicit intent conflicts with key deletion" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const bytes = "--- !u!114 &40\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ small_script ++ ", type: 3}\n  counts:\n  - key: A\n    value: 1\n";
    var c = try smallContext(arena, .{ bytes, bytes, bytes, bytes });
    const scripts = try arena.dupe(ctx.Script, c.base.scripts);
    scripts[0].fields = &.{.{ .path = "counts", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .default }};
    c.base.scripts = scripts;
    c.ours.scripts = scripts;
    c.theirs.scripts = scripts;
    c.output.scripts = scripts;
    const base = try smallVariant(arena, try smallRow(arena, "counts.Array.size", "1"));
    const ours = try smallVariant(arena, try smallRow(arena, "counts.Array.size", "0"));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "counts.Array.size", "1"), try smallRow(arena, "counts.Array.data[0].key", "A") }));
    var built = try merge.buildWithContext(arena, base, ours, theirs, c);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try merge.resolve(arena, &built.plan, built.plan.operations[0].id, .{ .take = .theirs });
    try testing.expectEqualStrings("A", try rowValue(arena, try merge.finish(arena, &built.plan), "counts.Array.data[0].key"));
}

test "variant public unchanged inherited nested arrays do not need new override rows" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const bytes = small_source ++ "    childValues: [1, 2]\n";
    const base = try smallVariant(arena, try smallRow(arena, "items.Array.size", "1"));
    const theirs = try smallVariant(arena, try std.mem.concat(arena, u8, &.{ try smallRow(arena, "items.Array.size", "1"), try smallRow(arena, "items.Array.data[0].speed", "99") }));
    const built = try merge.buildWithContext(arena, base, base, theirs, try smallContext(arena, .{ bytes, bytes, bytes, bytes }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(arena, &built.plan);
    try testing.expectEqualStrings("99", try rowValue(arena, output, "items.Array.data[0].speed"));
    try testing.expect(std.mem.indexOf(u8, output, "childValues") == null);
}

fn dictionaryContext(arena: std.mem.Allocator, kind: ctx.Kind, source_bytes: []const u8) !ctx.Context {
    const fields = try arena.alloc(ctx.Field, 1);
    fields[0] = .{ .path = "items", .kind = kind, .dictionary_value = if (kind == .string_dictionary) .int32 else .string, .dictionary_equality = .default };
    const scripts = try arena.alloc(ctx.Script, 1);
    scripts[0] = .{ .guid = small_script, .class_name = "DictionaryBehaviour", .source_hash = "same-script", .fields = fields };
    const assets = try arena.alloc(ctx.Asset, 1);
    assets[0] = .{ .guid = small_guid, .path = "Source.prefab", .bytes = source_bytes };
    const snapshot: ctx.Snapshot = .{ .assets = assets, .scripts = scripts };
    return .{ .base = snapshot, .ours = snapshot, .theirs = snapshot, .output = snapshot };
}
fn dictionaryVariant(arena: std.mem.Allocator, keys: []const []const u8, values: []const []const u8) ![]const u8 {
    var rows: std.ArrayList(u8) = .empty;
    try rows.appendSlice(arena, try smallRow(arena, "items.Array.size", try std.fmt.allocPrint(arena, "{d}", .{keys.len})));
    for (keys, values, 0..) |key, val, i| {
        try rows.appendSlice(arena, try smallRow(arena, try std.fmt.allocPrint(arena, "items.Array.data[{d}].key", .{i}), key));
        try rows.appendSlice(arena, try smallRow(arena, try std.fmt.allocPrint(arena, "items.Array.data[{d}].value", .{i}), val));
    }
    return smallVariant(arena, rows.items);
}
fn expectBlankRow(arena: std.mem.Allocator, bytes: []const u8, property_path: []const u8) !void {
    const parsed = try parser.parseSpanned(arena, bytes);
    const modification = model.findValue(parsed.documents[0].body.map, "m_Modification").?;
    const rows = model.findValue(modification.map, "m_Modifications").?;
    for (rows.seq) |row| {
        const p = model.findValue(row.map, "propertyPath").?;
        if (!std.mem.eql(u8, p.scalar, property_path)) continue;
        const raw = model.findValue(row.map, "value").?;
        if (raw.* == .scalar) return testing.expectEqualStrings("", raw.scalar);
        try testing.expect(raw.* == .map and raw.map.len == 0);
        const span = parsed.entry_spans.get(raw).?;
        return testing.expectEqualStrings("", std.mem.trim(u8, span.value.bytes(bytes), " \t\r\n"));
    }
    return error.MissingRow;
}
const dictionary_empty_source = "--- !u!114 &40\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ small_script ++ ", type: 3}\n  items: []\n";

test "variant public typed blank dictionary key preserves independent edits" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try dictionaryVariant(a, &.{ "", "B" }, &.{ "1", "2" });
    const ours = try dictionaryVariant(a, &.{ "", "B" }, &.{ "10", "2" });
    const theirs = try dictionaryVariant(a, &.{ "", "B" }, &.{ "1", "20" });
    const built = try merge.buildWithContext(a, base, ours, theirs, try dictionaryContext(a, .string_dictionary, dictionary_empty_source));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(a, &built.plan);
    try expectBlankRow(a, output, "items.Array.data[0].key");
    try testing.expectEqualStrings("10", try rowValue(a, output, "items.Array.data[0].value"));
    try testing.expectEqualStrings("20", try rowValue(a, output, "items.Array.data[1].value"));
}

test "variant public typed blank dictionary value preserves independent edits" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try dictionaryVariant(a, &.{ "1", "2" }, &.{ "", "B" });
    const ours = try dictionaryVariant(a, &.{ "1", "2" }, &.{ "A", "B" });
    const theirs = try dictionaryVariant(a, &.{ "1", "2" }, &.{ "", "" });
    const built = try merge.buildWithContext(a, base, ours, theirs, try dictionaryContext(a, .int32_dictionary, dictionary_empty_source));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(a, &built.plan);
    try testing.expectEqualStrings("A", try rowValue(a, output, "items.Array.data[0].value"));
    try expectBlankRow(a, output, "items.Array.data[1].value");
}

test "variant public typed blank dictionary key collision is a local choice" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try dictionaryVariant(a, &.{"B"}, &.{"1"});
    const ours = try dictionaryVariant(a, &.{ "B", "" }, &.{ "2", "10" });
    const theirs = try dictionaryVariant(a, &.{ "B", "" }, &.{ "1", "20" });
    var built = try merge.buildWithContext(a, base, ours, theirs, try dictionaryContext(a, .string_dictionary, dictionary_empty_source));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    const id = try localId(&built.plan);
    try testing.expectEqual(@import("merge_value.zig").Reason.edit_edit, merge.collectionConflict(&built.plan, id).?.reason);
    try merge.resolve(a, &built.plan, id, .{ .take = .theirs });
    const output = try merge.finish(a, &built.plan);
    try testing.expectEqualStrings("2", try rowValue(a, output, "items.Array.size"));
    try testing.expectEqualStrings("2", try rowValue(a, output, "items.Array.data[0].value"));
    try expectBlankRow(a, output, "items.Array.data[1].key");
    try testing.expectEqualStrings("20", try rowValue(a, output, "items.Array.data[1].value"));
}

test "variant public typed blank dictionary rejects integer and unknown channels" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const blank_integer = try dictionaryVariant(a, &.{"A"}, &.{""});
    const invalid = try merge.buildWithContext(a, blank_integer, blank_integer, blank_integer, try dictionaryContext(a, .string_dictionary, dictionary_empty_source));
    try testing.expect(invalid.plan.unresolvedCount() > 0);
    try testing.expectError(error.InvalidResolution, merge.finish(a, &invalid.plan));
    const blank_key = try dictionaryVariant(a, &.{""}, &.{"value"});
    const integer_key = try merge.buildWithContext(a, blank_key, blank_key, blank_key, try dictionaryContext(a, .int32_dictionary, dictionary_empty_source));
    try testing.expect(integer_key.plan.unresolvedCount() > 0);
    try testing.expectError(error.InvalidResolution, merge.finish(a, &integer_key.plan));
    const blank_unknown = try dictionaryVariant(a, &.{""}, &.{"1"});
    const unknown = try merge.buildWithContext(a, blank_unknown, blank_unknown, blank_unknown, try smallContext(a, .{ dictionary_empty_source, dictionary_empty_source, dictionary_empty_source, dictionary_empty_source }));
    try testing.expect(unknown.plan.unresolvedCount() > 0);
    try testing.expectError(error.InvalidResolution, merge.finish(a, &unknown.plan));
}

test "variant public typed blank dictionary does not interpret a literal map as string" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const source_bytes = try std.mem.replaceOwned(u8, a, dictionary_empty_source, "items: []", "items:\n  - key: A\n    value: 1");
    const variant = try dictionaryVariant(a, &.{"{}"}, &.{"1"});
    const built = try merge.buildWithContext(a, variant, variant, variant, try dictionaryContext(a, .string_dictionary, source_bytes));
    try testing.expect(built.plan.unresolvedCount() > 0);
    try testing.expectError(error.InvalidResolution, merge.finish(a, &built.plan));
}

test "variant public typed blank dictionary rejects duplicate empty keys in one input" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try dictionaryVariant(a, &.{""}, &.{"1"});
    const ours = try dictionaryVariant(a, &.{ "", "" }, &.{ "1", "2" });
    const built = try merge.buildWithContext(a, base, ours, base, try dictionaryContext(a, .string_dictionary, dictionary_empty_source));
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqual(@import("merge_value.zig").Reason.invalid_dictionary, merge.collectionConflict(&built.plan, try localId(&built.plan)).?.reason);
    try testing.expectError(error.InvalidResolution, merge.finish(a, &built.plan));
}

test "variant public typed blank dictionary works in an inherited Variant layer" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const middle_guid = "00000000000000000000000000000003";
    const middle = try dictionaryVariant(a, &.{ "", "B" }, &.{ "1", "1" });
    var c = try dictionaryContext(a, .string_dictionary, dictionary_empty_source);
    const assets = try a.alloc(ctx.Asset, 2);
    assets[0] = c.base.assets[0];
    assets[1] = .{ .guid = middle_guid, .path = "Middle.prefab", .bytes = middle };
    c.base.assets = assets;
    c.ours.assets = assets;
    c.theirs.assets = assets;
    c.output.assets = assets;
    const base_old = try smallVariant(a, try smallRow(a, "items.Array.data[0].value", "2"));
    const base_guid = try std.mem.replaceOwned(u8, a, base_old, small_guid, middle_guid);
    const base = try std.mem.replaceOwned(u8, a, base_guid, "fileID: 40,", "fileID: 76,");
    const ours = try std.mem.replaceOwned(u8, a, base, "value: 2", "value: 10");
    const theirs_old = try smallVariant(a, try std.mem.concat(a, u8, &.{ try smallRow(a, "items.Array.data[0].value", "2"), try smallRow(a, "items.Array.data[1].value", "20") }));
    const theirs_guid = try std.mem.replaceOwned(u8, a, theirs_old, small_guid, middle_guid);
    const theirs = try std.mem.replaceOwned(u8, a, theirs_guid, "fileID: 40,", "fileID: 76,");
    const built = try merge.buildWithContext(a, base, ours, theirs, c);
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(a, &built.plan);
    try testing.expectEqualStrings("10", try rowValue(a, output, "items.Array.data[0].value"));
    try testing.expectEqualStrings("20", try rowValue(a, output, "items.Array.data[1].value"));
    try testing.expectError(error.MissingRow, rowValue(a, output, "items.Array.data[0].key"));
}

test "variant public typed blank dictionary preserves blank comments and CRLF" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base_lf = try dictionaryVariant(a, &.{ " # empty key", "B" }, &.{ "1", "2" });
    const base = try std.mem.replaceOwned(u8, a, base_lf, "\n", "\r\n");
    const ours = try std.mem.replaceOwned(u8, a, base, "value: 1\r\n", "value: 10\r\n");
    const theirs = try std.mem.replaceOwned(u8, a, base, "propertyPath: items.Array.data[1].value\r\n      value: 2", "propertyPath: items.Array.data[1].value\r\n      value: 20");
    const built = try merge.buildWithContext(a, base, ours, theirs, try dictionaryContext(a, .string_dictionary, dictionary_empty_source));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    const output = try merge.finish(a, &built.plan);
    try testing.expect(std.mem.indexOf(u8, output, "value:  # empty key\r\n") != null);
    try testing.expectEqualStrings("10", try rowValue(a, output, "items.Array.data[0].value"));
    try testing.expectEqualStrings("20", try rowValue(a, output, "items.Array.data[1].value"));
}

test "variant public selected Source does not repeat its conflict around an authored leaf" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base_source = @embedFile("testdata/collections/cases/variant-source-and-override/base-source.prefab");
    const edited_source = try std.mem.replaceOwned(u8, a, base_source, "  - name: A\n    power: 1\n    speed: 1\n", "  - name: A\n    power: 1\n    speed: 10\n");
    const removed_source = @embedFile("testdata/collections/cases/variant-source-and-override/theirs-source.prefab");
    const base = @embedFile("testdata/collections/cases/variant-source-and-override/base.prefab");
    const edited = @embedFile("testdata/collections/cases/variant-source-and-override/ours.prefab");
    inline for (.{ false, true }) |swap| {
        inline for (.{ false, true }) |remove_a| {
            const snapshots = try a.alloc(ctx.Snapshot, 4);
            const sources = [4][]const u8{ base_source, if (swap) removed_source else edited_source, if (swap) edited_source else removed_source, if (remove_a) removed_source else edited_source };
            for (snapshots, sources) |*snapshot, bytes| {
                const assets = try a.alloc(ctx.Asset, 1);
                assets[0] = .{ .guid = "0464d347790434a4898eef837430e91e", .path = "Source.prefab", .bytes = bytes };
                snapshot.* = .{ .assets = assets, .scripts = context().base.scripts };
            }
            const built = try merge.buildWithContext(a, base, if (swap) base else edited, if (swap) edited else base, .{ .base = snapshots[0], .ours = snapshots[1], .theirs = snapshots[2], .output = snapshots[3] });
            try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
            try testing.expectEqual(@as(usize, 0), (try merge.variantProvenance(a, &built.plan)).effects.len);
            const expected = if (remove_a) @embedFile("testdata/collections/cases/variant-source-and-override/expected.prefab") else edited;
            try testing.expectEqualStrings(expected, try merge.finish(a, &built.plan));
        }
    }
}

const leaf_source = small_source ++ "  - name: B\n    speed: 2\n  - name: C\n    speed: 3\n";
fn leafSourceContext(a: std.mem.Allocator, remove_a: bool) !ctx.Context {
    const edited_source = try std.mem.replaceOwned(u8, a, leaf_source, "name: A\n    speed: 1", "name: A\n    speed: 10");
    const removed_source = try std.mem.replaceOwned(u8, a, leaf_source, "  - name: A\n    speed: 1\n", "");
    return smallContext(a, .{ leaf_source, edited_source, removed_source, if (remove_a) removed_source else edited_source });
}

test "variant public selected Source merges authored leaves from both historical indices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try smallVariant(a, "");
    const ours = try smallVariant(a, try smallRow(a, "items.Array.data[1].speed", "99"));
    const theirs = try smallVariant(a, try smallRow(a, "items.Array.data[1].speed", "77"));
    inline for (.{ false, true }) |remove_a| {
        const built = try merge.buildWithContext(a, base, ours, theirs, try leafSourceContext(a, remove_a));
        try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
        const output = try merge.finish(a, &built.plan);
        try testing.expectEqualStrings("99", try rowValue(a, output, if (remove_a) "items.Array.data[0].speed" else "items.Array.data[1].speed"));
        try testing.expectEqualStrings("77", try rowValue(a, output, if (remove_a) "items.Array.data[1].speed" else "items.Array.data[2].speed"));
        try testing.expectError(error.MissingRow, rowValue(a, output, "items.Array.size"));
        try testing.expectEqual(@as(usize, 0), (try merge.variantProvenance(a, &built.plan)).effects.len);
    }
}

test "variant public selected Source retains authored reset versus edit choices" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try smallVariant(a, try smallRow(a, "items.Array.data[1].speed", "5"));
    const ours = try smallVariant(a, try smallRow(a, "items.Array.data[2].speed", "77"));
    const theirs = try smallVariant(a, try smallRow(a, "items.Array.data[0].speed", "99"));
    inline for (.{ false, true }) |keep_edit| {
        var built = try merge.buildWithContext(a, base, ours, theirs, try leafSourceContext(a, false));
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
        const id = try localId(&built.plan);
        try merge.resolve(a, &built.plan, id, .{ .take = if (keep_edit) .theirs else .ours });
        const output = try merge.finish(a, &built.plan);
        if (keep_edit) try testing.expectEqualStrings("99", try rowValue(a, output, "items.Array.data[1].speed")) else try testing.expectError(error.MissingRow, rowValue(a, output, "items.Array.data[1].speed"));
        try testing.expectEqualStrings("77", try rowValue(a, output, "items.Array.data[2].speed"));
        try testing.expectEqual(@as(usize, 0), (try merge.variantProvenance(a, &built.plan)).effects.len);
    }
}

test "variant public selected Source cannot retarget removed or ambiguous authored leaves" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const base = try smallVariant(a, "");
    inline for (.{ false, true }) |duplicate| {
        const before = if (duplicate) try std.mem.concat(a, u8, &.{ small_source, "  - name: A\n    speed: 1\n" }) else leaf_source;
        const after = if (duplicate) small_source else try std.mem.replaceOwned(u8, a, leaf_source, "  - name: B\n    speed: 2\n", "");
        const ours = try smallVariant(a, try smallRow(a, if (duplicate) "items.Array.data[0].speed" else "items.Array.data[1].speed", "99"));
        const built = try merge.buildWithContext(a, base, ours, base, try smallContext(a, .{ before, before, after, after }));
        try testing.expect(built.plan.unresolvedCount() > 0);
        try testing.expectError(error.InvalidResolution, merge.finish(a, &built.plan));
    }
}

test "variant public selected Source permits unwritten inheritance with missing historical context" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const variant = try smallVariant(a, "");
    inline for (.{ false, true }) |missing_source| {
        for (0..3) |side| {
            var c = try smallContext(a, .{ small_source, small_source, small_source, small_source });
            const snapshots = [3]*ctx.Snapshot{ &c.base, &c.ours, &c.theirs };
            if (missing_source) snapshots[side].assets = &.{} else snapshots[side].scripts = &.{};
            const built = try merge.buildWithContext(a, variant, variant, variant, c);
            try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
            try testing.expectEqualStrings(variant, try merge.finish(a, &built.plan));
        }
    }
    inline for (.{ false, true }) |ambiguous| {
        var c = try smallContext(a, .{ small_source, small_source, small_source, small_source });
        c.output.assets = if (ambiguous) try std.mem.concat(a, ctx.Asset, &.{ c.output.assets, c.output.assets }) else &.{};
        const built = try merge.buildWithContext(a, variant, variant, variant, c);
        try testing.expect(built.plan.unresolvedCount() > 0);
        try testing.expectError(error.InvalidResolution, merge.finish(a, &built.plan));
    }
}

test "variant public selected Source does not reopen inherited edits beside unchanged authored rows" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const source_two = small_source ++ "  - name: B\n    speed: 2\n";
    const changed_source = try std.mem.replaceOwned(u8, a, source_two, "name: B\n    speed: 2", "name: C\n    speed: 3");
    const variant = try smallVariant(a, try smallRow(a, "items.Array.data[0].speed", "99"));
    const built = try merge.buildWithContext(a, variant, variant, variant, try smallContext(a, .{ source_two, small_source, changed_source, source_two }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings(variant, try merge.finish(a, &built.plan));
    try testing.expectEqual(@as(usize, 0), (try merge.variantProvenance(a, &built.plan)).effects.len);
}

test "variant public selected Source preserves the empty modification header comment when adding rows" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const empty = try smallVariant(a, "");
    const base = try std.mem.replaceOwned(u8, a, empty, "m_Modifications: []", "m_Modifications: [] # overrides");
    const row = try smallVariant(a, try smallRow(a, "items.Array.data[0].speed", "99"));
    const theirs = try std.mem.replaceOwned(u8, a, row, "m_Modifications:\n", "m_Modifications: # overrides\n");
    const built = try merge.buildWithContext(a, base, base, theirs, try smallContext(a, .{ small_source, small_source, small_source, small_source }));
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings(theirs, try merge.finish(a, &built.plan));
}
