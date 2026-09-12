const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const merge_tree = @import("merge_tree.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const result_text = @import("merge_result_text.zig");
const inspector = @import("merge_inspector.zig");
const testing = std.testing;

test "merge TUI: section labels use the same muted color as value columns" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const labels = try rowText(arena, surface, body.inspector_labels_row);
    try testing.expect(std.mem.indexOf(u8, labels, "Property") != null);
    try testing.expectEqual(Palette.muted, surface.readCell(geometry.inspector.start, body.inspector_labels_row).style.fg);
    try testing.expectEqual(Palette.muted, surface.readCell(geometry.ours.start, body.inspector_labels_row).style.fg);
    const group_row = for (body.hierarchy_rows.start..body.hierarchy_rows.end) |row| {
        if (std.mem.indexOf(u8, try rowText(arena, surface, @intCast(row)), "components") != null) break @as(u16, @intCast(row));
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(Palette.muted, fgOfText(surface, geometry.hierarchy, group_row, "components") orelse return error.TestUnexpectedResult);
}

test "merge TUI: unresolved semantic Result does not show a placeholder dash" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const result = try rangeText(arena, surface, geometry.result, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, result, "—") == null);
    try testing.expect(std.mem.indexOf(u8, result, "-") == null);
}

test "merge TUI: component property editing retains its document and owner reference" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 160, 24);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("2", try view.editor.buf.dupe());
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '3', .text = "3" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    // Editing the displayed cell must retain the selected component and its GameObject membership together.
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: 3"), try core.merge.finish(arena, &fixture.plan));
}
const vxfw = vaxis.vxfw;

test "merge TUI: cancelling an empty property edit retains the component choice" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    // Cancelling a cleared cell must not clear the retained component or discard the side preview.
    try testing.expect(!view.editing);
    try testing.expectEqual(core.merge.Side.theirs, state.pending.?.take);
    try state.handle(.apply_result);
    try testing.expectEqualStrings(fixture.plan.theirs.bytes, try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: confirming an empty property preserves the component and permits another edit" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 140, 24);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(Dialog.empty, view.dialog.?);
    try pressKeyForTest(&view, &ctx, 'y');
    try testing.expectEqualStrings("", state.status);
    // Clearing a field must never mean removing its containing component.
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: "), try core.merge.finish(arena, &fixture.plan));
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 140, 24));
    try testing.expect(std.mem.indexOf(u8, screen, "<empty>") != null);
    try pressKeyForTest(&view, &ctx, vaxis.Key.left);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(view.editing);
    try testing.expectEqualStrings("", try view.editor.buf.dupe());
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '3', .text = "3" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: 3"), try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: a removed component cannot acquire an independently edited property" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_ours);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(!view.editing);
    try testing.expect(state.status.len > 0);
    try state.handle(.apply_result);
    try testing.expectEqualStrings(fixture.plan.ours.bytes, try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: property and raw views preserve the selected result across toggles" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const before = try surfaceText(arena, try drawForTest(arena, view.widget(), 120, 24));
    try testing.expect(std.mem.indexOf(u8, before, "Mass") != null);
    try testing.expect(std.mem.indexOf(u8, before, "Game Object") == null);
    var ctx = eventContext(arena);
    const click_toggle: vxfw.Event = .{ .mouse = .{
        .col = 110,
        .row = @intCast(BodyGeometry.init(24).inspector_heading_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } };
    try view.widget().handleEvent(&ctx, click_toggle);
    const raw = try surfaceText(arena, try drawForTest(arena, view.widget(), 120, 24));
    try testing.expect(std.mem.indexOf(u8, raw, "Rigidbody:") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "⇧R Semantic") != null);
    try view.widget().handleEvent(&ctx, click_toggle);
    try testing.expect(!view.raw_view);
    try testing.expectEqual(core.merge.Side.theirs, state.pending.?.take);
}

test "merge TUI: sequence order semantic view toggles to a unified diff" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    const semantic = try surfaceText(arena, try drawForTest(arena, view.widget(), 160, 24));
    try testing.expect(std.mem.indexOf(u8, semantic, "⇧R Raw") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "Name") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "Tag") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "--- Base") == null);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'r', .mods = .{ .shift = true }, .text = "R" } });
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const raw = try surfaceText(arena, surface);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const labels = try rowText(arena, surface, body.inspector_labels_row);
    try testing.expect(std.mem.indexOf(u8, raw, "⇧R Semantic") != null);
    try testing.expect(std.mem.indexOf(u8, labels, "Base") != null);
    try testing.expect(std.mem.indexOf(u8, labels, "Ours") != null);
    try testing.expect(std.mem.indexOf(u8, labels, "Theirs") != null);
    try testing.expect(std.mem.indexOf(u8, labels, "Result") != null);
    const ours = try rangeText(arena, surface, geometry.ours, body.inspector_rows.start, body.inspector_rows.end);
    const theirs = try rangeText(arena, surface, geometry.theirs, body.inspector_rows.start, body.inspector_rows.end);
    const result = try rangeText(arena, surface, geometry.result, body.inspector_rows.start, body.inspector_rows.end);
    const base = try rangeText(arena, surface, geometry.base, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, ours, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, ours, "+++ Ours") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "+++ Theirs") != null);
    try testing.expect(std.mem.indexOf(u8, base, "+++ Base") == null);
    try testing.expect(std.mem.indexOf(u8, result, "+++ Result") == null);
    try testing.expect(std.mem.indexOf(u8, result, "--- Base") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "--- Ours") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "<removed>") == null);
}

test "merge TUI: raw view is available for a collection without a property table" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try core.merge.build(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  items: [A]\n",
        "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Ours]\n",
        "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Theirs]\n",
    );
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "Conflict.prefab", fixture.partial);
    defer view.deinit();
    const semantic = try surfaceText(arena, try drawForTest(arena, view.widget(), 160, 24));
    try testing.expect(std.mem.indexOf(u8, semantic, "⇧R Raw") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "⇧T One side") != null);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'r', .mods = .{ .shift = true }, .text = "R" } });
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const raw = try surfaceText(arena, surface);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const ours = try rangeText(arena, surface, geometry.ours, body.inspector_rows.start, body.inspector_rows.end);
    const theirs = try rangeText(arena, surface, geometry.theirs, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, raw, "⇧R Semantic") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "⇧T One side") != null);
    try testing.expect(std.mem.indexOf(u8, ours, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, ours, "+++ Ours") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "+++ Theirs") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "<removed>") == null);
}

test "merge TUI: raw result shows the applied YAML" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const raw = try surfaceText(arena, surface);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const result = try rangeText(arena, surface, geometry.result, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, result, "Rigidbody:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--- Base") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "<removed>") == null);
}

test "merge TUI: raw diffs color deletions red and leave YAML headers uncolored" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    // A Unity YAML document header is not a unified-diff marker.
    try testing.expectEqual(vaxis.Color.default, firstContentFg(surface, geometry.base, body.inspector_rows.start));
    const ours_deletion = lineStartFg(surface, geometry.ours, body.inspector_rows.start, body.inspector_rows.end, "-") orelse
        return error.TestUnexpectedResult;
    const theirs_addition = lineStartFg(surface, geometry.theirs, body.inspector_rows.start, body.inspector_rows.end, "+") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(Palette.ours, ours_deletion);
    try testing.expectEqual(Palette.theirs, theirs_addition);
}

test "merge TUI: wheel scrolls only the focused inspector column" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    view.focus_area = .inspector;
    view.selected_value = .theirs;
    _ = try drawForTest(arena, view.widget(), 160, 16);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(16);
    const ours_before = try rangeText(
        arena,
        try drawForTest(arena, view.widget(), 160, 16),
        geometry.ours,
        body.inspector_rows.start,
        body.inspector_rows.end,
    );
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start + 2),
        .row = @intCast(body.inspector_rows.start),
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 0), view.column_v[@intFromEnum(ValueColumn.ours)]);
    try testing.expectEqual(@as(usize, 0), view.column_v[@intFromEnum(ValueColumn.theirs)]);
    const ours_after = try rangeText(
        arena,
        try drawForTest(arena, view.widget(), 160, 16),
        geometry.ours,
        body.inspector_rows.start,
        body.inspector_rows.end,
    );
    try testing.expectEqualStrings(ours_before, ours_after);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.theirs.start + 2),
        .row = @intCast(body.inspector_rows.start),
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), view.column_v[@intFromEnum(ValueColumn.theirs)]);
    try testing.expectEqual(@as(usize, 0), view.column_v[@intFromEnum(ValueColumn.ours)]);
}

test "merge TUI: inspector column scroll stops at the last line" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    view.focus_area = .inspector;
    view.selected_value = .theirs;
    _ = try drawForTest(arena, view.widget(), 160, 16);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(16);
    for (0..400) |_| {
        try view.widget().handleEvent(&ctx, .{ .mouse = .{
            .col = @intCast(geometry.theirs.start + 2),
            .row = @intCast(body.inspector_rows.start),
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } });
    }
    const viewport = body.inspector_rows.end - body.inspector_rows.start;
    const operation = view.selectedOperation().?;
    const text = try unifiedDiff(
        arena,
        "Base",
        try view.columnText(arena, operation, .base),
        "Theirs",
        try view.columnText(arena, operation, .theirs),
    );
    const rows = columnScrollMetrics(geometry.theirs, text, viewport, 0).rows;
    try testing.expect(view.column_v[@intFromEnum(ValueColumn.theirs)] < 400);
    try testing.expectEqual(rows -| viewport, view.column_v[@intFromEnum(ValueColumn.theirs)]);
    const surface = try drawForTest(arena, view.widget(), 160, 16);
    try testing.expect(hasScrollbarThumb(surface, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end));
}

test "merge TUI: wrapped inspector lines show a floating scrollbar only while scrolling" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    view.focus_area = .inspector;
    view.selected_value = .theirs;
    const idle = try drawForTest(arena, view.widget(), 160, 40);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(40);
    const viewport = body.inspector_rows.end - body.inspector_rows.start;
    const operation = view.selectedOperation().?;
    const text = try unifiedDiff(
        arena,
        "Base",
        try view.columnText(arena, operation, .base),
        "Theirs",
        try view.columnText(arena, operation, .theirs),
    );
    try testing.expect(countContentLines(text) <= viewport);
    try testing.expect(!hasScrollbarThumb(idle, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end));
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.theirs.start + 2),
        .row = @intCast(body.inspector_rows.start),
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    const scrolling = try drawForTest(arena, view.widget(), 160, 40);
    try testing.expect(hasScrollbarThumb(scrolling, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end));
    const thumb = scrollbarThumbCell(scrolling, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end) orelse
        return error.TestUnexpectedResult;
    try testing.expect(vaxis.Color.eql(thumb.style.bg, Palette.scrollbar));
    try testing.expect(!isScrollbarGlyph(thumb.char.grapheme));
    try testing.expect(!hasScrollbarThumb(scrolling, geometry.theirs.end - 2, body.inspector_rows.start, body.inspector_rows.end));
    try view.widget().handleEvent(&ctx, .tick);
    const hidden = try drawForTest(arena, view.widget(), 160, 40);
    try testing.expect(!hasScrollbarThumb(hidden, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end));
}

test "merge TUI: unfocused inspector columns do not show a scrollbar" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    view.focus_area = .hierarchy;
    view.selected_value = .theirs;
    view.scrollbar_visible = true;
    const surface = try drawForTest(arena, view.widget(), 160, 16);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(16);
    try testing.expect(!hasScrollbarThumb(surface, geometry.theirs.end - 1, body.inspector_rows.start, body.inspector_rows.end));
}

test "merge TUI: scrollbar thumb shrinks as the scroll range grows" {
    try testing.expectEqual(@as(usize, 20), scrollbarThumbRows(21, 22));
    try testing.expectEqual(@as(usize, 5), scrollbarThumbRows(21, 80));
    try testing.expect(scrollbarThumbRows(21, 22) > scrollbarThumbRows(21, 80));
}

test "merge TUI: wheel right scrolls wrapped inspector lines vertically" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOrderPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "PrefabOrder.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    view.focus_area = .inspector;
    view.selected_value = .theirs;
    _ = try drawForTest(arena, view.widget(), 160, 40);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(40);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.theirs.start + 2),
        .row = @intCast(body.inspector_rows.start),
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), view.column_v[@intFromEnum(ValueColumn.theirs)]);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.theirs.start + 2),
        .row = @intCast(body.inspector_rows.start),
        .button = .wheel_right,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 2), view.column_v[@intFromEnum(ValueColumn.theirs)]);
    try testing.expectEqual(@as(usize, 0), view.column_h[@intFromEnum(ValueColumn.theirs)]);
}

test "merge TUI: game object delete edit uses a Base diff and keeps ⇧R" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try gameObjectDeleteEditPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "GameObjectDeleteEdit.prefab", fixture.partial);
    defer view.deinit();
    const semantic = try surfaceText(arena, try drawForTest(arena, view.widget(), 160, 24));
    try testing.expect(std.mem.indexOf(u8, semantic, "⇧R Raw") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "Name") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "Edited Child") != null);
    try testing.expect(std.mem.indexOf(u8, semantic, "<removed>") == null);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'r', .mods = .{ .shift = true }, .text = "R" } });
    const surface = try drawForTest(arena, view.widget(), 160, 24);
    const raw = try surfaceText(arena, surface);
    const geometry = Geometry.init(160);
    const body = BodyGeometry.init(24);
    const ours = try rangeText(arena, surface, geometry.ours, body.inspector_rows.start, body.inspector_rows.end);
    const theirs = try rangeText(arena, surface, geometry.theirs, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, raw, "⇧R Semantic") != null);
    try testing.expect(std.mem.indexOf(u8, ours, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "--- Base") != null);
    try testing.expect(std.mem.indexOf(u8, theirs, "+++ Theirs") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "<removed>") == null);
    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    view.raw_view = true;
    const applied = try drawForTest(arena, view.widget(), 160, 24);
    const result = try rangeText(arena, applied, geometry.result, body.inspector_rows.start, body.inspector_rows.end);
    try testing.expect(std.mem.indexOf(u8, result, "Edited Child") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--- Base") == null);
    try testing.expectEqualStrings(fixture.plan.theirs.bytes, try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: game object name edit stays applicable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try gameObjectDeleteEditPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "GameObjectDeleteEdit.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 160, 24);
    var ctx = eventContext(arena);
    var memory_model = std.heap.ArenaAllocator.init(arena);
    defer memory_model.deinit();
    const model = try view.propertyModel(memory_model.allocator());
    const name_row = for (model.rows, 0..) |row, index| {
        if (std.mem.eql(u8, row.label, "Name")) break index;
    } else return error.TestUnexpectedResult;
    view.property_row = name_row;
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(view.editing);
    view.editor.clearRetainingCapacity();
    try view.editor.insertSliceAtCursor("Renamed");
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    try testing.expect(std.mem.indexOf(u8, try core.merge.finish(arena, &fixture.plan), "m_Name: Renamed") != null);
}

test "merge TUI: reparent cycle take theirs is applicable" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try reparentCyclePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqualStrings(fixture.plan.theirs.bytes, try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: prefab override raw edit keeps the displayed modification YAML" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOverrideSpeedPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "Enemy Variant.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 180, 24);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'r', .mods = .{ .shift = true }, .text = "R" } });
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    // Raw Result already shows the modification item. The editor must open on that YAML,
    // not the scalar conflict bytes that apply uses.
    const text = try view.editor.buf.dupe();
    try testing.expect(view.editing);
    try testing.expect(std.mem.indexOf(u8, text, "propertyPath:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "value: 3") != null);
    try testing.expect(!std.mem.eql(u8, text, "3"));
}

test "merge TUI: prefab override semantic value can be edited to a custom result" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try prefabOverrideSpeedPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "Enemy Variant.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 160, 24);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("3", try view.editor.buf.dupe());
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '4', .text = "4" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqualStrings(
        try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "value: 3", "value: 4"),
        try core.merge.finish(arena, &fixture.plan),
    );
}

test "merge TUI: dictionary raw edit keeps the displayed pair YAML" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try dictionaryGoblinPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "Stats.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 160, 24);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'r', .mods = .{ .shift = true }, .text = "R" } });
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    // Pair conflicts display the sequence item. Opening the editor must not drop the key.
    const text = try view.editor.buf.dupe();
    try testing.expect(view.editing);
    try testing.expect(std.mem.indexOf(u8, text, "key: Goblin") != null);
    try testing.expect(std.mem.indexOf(u8, text, "value: 3") != null);
    try testing.expect(!std.mem.eql(u8, text, "3"));
}

test "merge TUI: dictionary custom result keeps pair indent on every side" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try dictionaryUnionPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "Dictionary.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 180, 24);
    view.raw_view = true;
    const operation = view.selectedOperation().?;
    const ours_before = try view.columnText(arena, operation, .ours);
    const theirs_before = try view.columnText(arena, operation, .theirs);
    try state.handle(.{ .edit_result = "key: Goblin\nvalue: 4" });
    // Result must keep the sequence-item indent. Otherwise common indent drops to 0
    // and Ours/Theirs appear to shift by two spaces of invalid YAML.
    try testing.expectEqualStrings(ours_before, try view.columnText(arena, operation, .ours));
    try testing.expectEqualStrings(theirs_before, try view.columnText(arena, operation, .theirs));
    const result = try view.columnText(arena, operation, .result);
    try testing.expect(std.mem.indexOf(u8, result, "key: Goblin") != null);
    try testing.expect(std.mem.indexOf(u8, result, "value: 4") != null);
    try testing.expectEqual(lineIndent(ours_before), lineIndent(result));
}

test "merge TUI: dictionary semantic value can be edited to a custom result" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try dictionaryGoblinPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "Stats.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 160, 24);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("3", try view.editor.buf.dupe());
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '4', .text = "4" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    // A Value-cell edit is still the original pair. Reconstructing a flow map would
    // change YAML Unity did not ask to restyle.
    try testing.expectEqualStrings(
        try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "value: 3", "value: 4"),
        try core.merge.finish(arena, &fixture.plan),
    );
}

test "merge TUI: Raw shortcut preserves typed letters in the Result editor" {
    // Terminals can report Shift as a modifier or as an uppercase character.
    for ([_]bool{ false, true }) |explicit_shift| {
        var memory = std.heap.ArenaAllocator.init(testing.allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        var fixture = try componentDeletePlan(arena);
        var state = try merge_ui_state.State.init(arena, &fixture.plan);
        try state.handle(.choose_theirs);
        var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
        defer view.deinit();
        _ = try drawForTest(arena, view.widget(), 120, 24);
        var ctx = eventContext(arena);
        const raw_key: vaxis.Key = .{ .codepoint = if (explicit_shift) 'r' else 'R', .mods = .{ .shift = explicit_shift }, .text = "R" };
        try view.widget().handleEvent(&ctx, .{ .key_press = raw_key });
        const raw = try surfaceText(arena, try drawForTest(arena, view.widget(), 120, 24));
        try testing.expect(std.mem.indexOf(u8, raw, "Rigidbody:") != null);
        try view.widget().handleEvent(&ctx, .{ .key_press = raw_key });
        try focusResultForTest(&view, &ctx);
        try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
        try testing.expectEqualStrings("2", try view.editor.buf.dupe());
        // Mode shortcuts must become ordinary text once the Result editor owns focus.
        const surface = try drawForTest(arena, view.widget(), 120, 24);
        try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = raw_key });
        try testing.expectEqualStrings("2R", try view.editor.buf.dupe());
        try testing.expect(!view.raw_view);
        for (0..2) |_| try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '3', .text = "3" } });
        try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
        try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: 3"), try core.merge.finish(arena, &fixture.plan));
    }
}

const minimum_size: vxfw.Size = .{ .width = 80, .height = 10 };

const horizontal_padding: u16 = 2;

const vertical_padding: u16 = 1;

const Palette = struct {
    // Hallmark · component: scrollbar · genre: modern-minimal · theme: Terminal-adjacent
    // states: hidden-idle · visible-scroll · hidden-unfocused · overlay-bg
    const accent: vaxis.Color = .{ .rgb = .{ 176, 169, 255 } };
    const ours: vaxis.Color = .{ .rgb = .{ 255, 112, 122 } };
    const theirs: vaxis.Color = .{ .rgb = .{ 91, 224, 135 } };
    const conflict: vaxis.Color = .{ .rgb = .{ 241, 196, 74 } };
    const muted: vaxis.Color = .{ .rgb = .{ 150, 151, 168 } };
    const error_text: vaxis.Color = .{ .rgb = .{ 245, 92, 92 } };
    const focus_bg: vaxis.Color = .{ .rgb = .{ 48, 46, 68 } };
    const result_bg: vaxis.Color = .{ .rgb = .{ 31, 32, 43 } };
    const scrollbar: vaxis.Color = .{ .rgb = .{ 84, 85, 99 } };
};

const scrollbar_hide_ms: u32 = 900;
const scrollbar_width: u16 = 1;

fn scrollbarThumbRows(viewport: usize, content: usize) usize {
    if (content <= viewport or viewport == 0) return 0;
    return @max(@as(usize, 1), (viewport * viewport) / content);
}

fn isUsableSize(size: vxfw.Size) bool {
    return size.width >= minimum_size.width and size.height >= minimum_size.height;
}

const Range = struct {
    start: u16,
    end: u16,
};

const Geometry = struct {
    hierarchy: Range,
    inspector: Range,
    base: Range,
    ours: Range,
    theirs: Range,
    result: Range,

    fn init(width: u16) Geometry {
        const content_start = horizontal_padding;
        const content_end = width - horizontal_padding;
        const content_width = content_end - content_start;
        const split = content_start + @max(@as(u16, 24), content_width / 3);
        const inspector_width = content_end - split - 1;
        const inspector_start = split + 1;
        const ours_start = inspector_start + inspector_width / 4;
        const theirs_start = inspector_start + inspector_width * 2 / 4;
        const result_start = inspector_start + inspector_width * 3 / 4;
        return .{
            .hierarchy = .{ .start = content_start, .end = split },
            .inspector = .{ .start = inspector_start, .end = content_end },
            .base = .{ .start = inspector_start, .end = ours_start },
            .ours = .{ .start = ours_start, .end = theirs_start },
            .theirs = .{ .start = theirs_start, .end = result_start },
            .result = .{ .start = result_start, .end = content_end },
        };
    }
};

const FooterGeometry = struct {
    row: u16,
    complete: Range,

    fn init(width: u16, height: u16) FooterGeometry {
        const end = width - horizontal_padding;
        return .{
            .row = height - vertical_padding - 1,
            .complete = .{ .start = end - 10, .end = end },
        };
    }
};

const ours_combined_label = "Ours + Theirs";
const theirs_combined_label = "Theirs + Ours";

const InspectorHeadingGeometry = struct {
    title: Range,
    raw: ?Range = null,
    combine: ?Range = null,

    fn init(inspector_range: Range, combine: bool) InspectorHeadingGeometry {
        var result: InspectorHeadingGeometry = .{ .title = inspector_range };
        // Reserve controls from the right so neither another control nor a long title can overlap them.
        result.raw = .{ .start = result.title.end - textWidth("⇧R Semantic"), .end = result.title.end };
        result.title.end = result.raw.?.start - 2;
        if (combine) {
            result.combine = .{ .start = result.title.end - textWidth("⇧T Both sides"), .end = result.title.end };
            result.title.end = result.combine.?.start - 2;
        }
        return result;
    }
};

const Dialog = enum {
    quit,
    empty,

    fn prompt(self: Dialog) []const u8 {
        return switch (self) {
            .quit => "Quit before completion?",
            .empty => "Use an empty value?",
        };
    }

    fn detail(self: Dialog) []const u8 {
        return switch (self) {
            .quit => "PrefabLens will not write this result.",
            .empty => "This field will contain an empty YAML value.",
        };
    }

    fn confirmLabel(self: Dialog) []const u8 {
        return switch (self) {
            .quit => "[Quit]",
            .empty => "[Use Empty]",
        };
    }
};

const DialogGeometry = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,
    prompt_row: u16,
    detail_row: u16,
    buttons_row: u16,
    cancel: Range,
    confirm: Range,

    fn init(width: u16, height: u16, kind: Dialog) DialogGeometry {
        const dialog_width: u16 = if (kind == .quit) 44 else 50;
        const left = (width - dialog_width) / 2;
        const top = (height - 7) / 2;
        return .{
            .top = top,
            .bottom = top + 7,
            .left = left,
            .right = left + dialog_width,
            .prompt_row = top + 1,
            .detail_row = top + 2,
            .buttons_row = top + 5,
            .cancel = .{ .start = left + 13, .end = left + 21 },
            .confirm = .{ .start = left + 25, .end = left + 25 + @as(u16, @intCast(kind.confirmLabel().len)) },
        };
    }
};

const BodyGeometry = struct {
    header_row: u16,
    hierarchy_rows: Range,
    inspector_heading_row: u16,
    inspector_labels_row: u16,
    inspector_rows: Range,
    status_row: u16,

    fn init(height: u16) BodyGeometry {
        const header_row = vertical_padding;
        const status_row = height - vertical_padding - 2;
        return .{
            .header_row = header_row,
            .hierarchy_rows = .{ .start = header_row + 1, .end = status_row },
            .inspector_heading_row = header_row + 1,
            .inspector_labels_row = header_row + 2,
            .inspector_rows = .{ .start = header_row + 3, .end = status_row },
            .status_row = status_row,
        };
    }

    fn visibleRows(self: BodyGeometry) usize {
        return self.hierarchy_rows.end - self.hierarchy_rows.start;
    }
};

const ValueColumn = enum { base, ours, theirs, result };
const FocusArea = enum { hierarchy, inspector, complete };
const DialogChoice = enum { cancel, confirm };

fn valueRange(geometry: Geometry, column: ValueColumn) Range {
    return switch (column) {
        .base => geometry.base,
        .ours => geometry.ours,
        .theirs => geometry.theirs,
        .result => geometry.result,
    };
}

fn isWheelButton(button: vaxis.Mouse.Button) bool {
    return switch (button) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
        else => false,
    };
}

fn columnAt(geometry: Geometry, col: i16) ?ValueColumn {
    if (col < 0) return null;
    const x: u16 = @intCast(col);
    inline for (.{ ValueColumn.base, .ours, .theirs, .result }) |column| {
        if (inRange(x, valueRange(geometry, column))) return column;
    }
    return null;
}

fn countContentLines(text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var remaining = std.mem.splitScalar(u8, text, '\n');
    _ = remaining.next();
    while (lines.next()) |raw_line| {
        const more = remaining.next() != null;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!more and line.len == 0) break;
        count += 1;
    }
    return count;
}

fn consumeDisplayWidth(text: []const u8, width: usize) usize {
    var col: usize = 0;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    var consumed: usize = 0;
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width = vaxis.gwidth.gwidth(bytes, .unicode);
        if (cell_width == 0) {
            consumed = grapheme.start + grapheme.len;
            continue;
        }
        if (col + cell_width > width) break;
        col += cell_width;
        consumed = grapheme.start + grapheme.len;
    }
    return consumed;
}

fn countLineVisualRows(line: []const u8, width: usize) usize {
    if (line.len == 0 or width == 0) return 1;
    var rest = line;
    var rows: usize = 0;
    while (rest.len != 0) {
        const consumed = consumeDisplayWidth(rest, width);
        if (consumed == 0) return rows + 1;
        rest = rest[consumed..];
        rows += 1;
    }
    return rows;
}

fn visiblePaintLine(text: []const u8, line: []const u8, indent: usize) []const u8 {
    return if (isPlaceholderValue(text)) line else skipLineIndent(line, indent);
}

fn countVisualRows(text: []const u8, inner_width: usize, indent: usize) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var remaining = std.mem.splitScalar(u8, text, '\n');
    _ = remaining.next();
    while (lines.next()) |raw_line| {
        const more = remaining.next() != null;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!more and line.len == 0) break;
        count += countLineVisualRows(visiblePaintLine(text, line, indent), inner_width);
    }
    return count;
}

fn skipWrappedPrefix(line: []const u8, width: usize, skip: *usize) []const u8 {
    var rest = line;
    while (skip.* > 0) {
        if (rest.len == 0) {
            skip.* -= 1;
            return "";
        }
        const consumed = consumeDisplayWidth(rest, width);
        if (consumed == 0) {
            skip.* -= 1;
            return rest;
        }
        rest = rest[consumed..];
        skip.* -= 1;
        if (rest.len == 0) return "";
    }
    return rest;
}

const ColumnScrollMetrics = struct {
    width: usize,
    rows: usize,
    bar: bool,
};

fn columnScrollMetrics(range: Range, text: []const u8, viewport: usize, indent: usize) ColumnScrollMetrics {
    const width = range.end - range.start -| 2;
    const rows = countVisualRows(text, width, indent);
    return .{ .width = width, .rows = rows, .bar = rows > viewport };
}

fn maxScrollOffset(content: usize, viewport: usize) usize {
    return content -| viewport;
}

fn reservedScrollRange(range: Range, content: usize, viewport: usize) Range {
    _ = content;
    _ = viewport;
    return range;
}

fn paintScrollbar(
    surface: vxfw.Surface,
    right_col: u16,
    start_row: u16,
    end_row: u16,
    offset: usize,
    content: usize,
) void {
    const viewport: usize = end_row - start_row;
    const thumb_h = scrollbarThumbRows(viewport, content);
    if (thumb_h == 0) return;
    const travel = viewport -| thumb_h;
    const max_off = content -| viewport;
    const thumb_start = if (max_off == 0) 0 else (offset * travel) / max_off;
    const left_col = right_col -| (scrollbar_width - 1);
    var row = start_row;
    while (row < end_row) : (row += 1) {
        const i: usize = row - start_row;
        if (i < thumb_start or i >= thumb_start + thumb_h) continue;
        var col = left_col;
        while (col <= right_col) : (col += 1) {
            var cell = surface.readCell(col, row);
            cell.style.bg = Palette.scrollbar;
            cell.default = false;
            surface.writeCell(col, row, cell);
        }
    }
}

fn skipLines(text: []const u8, count: usize) []const u8 {
    var rest = text;
    var skipped: usize = 0;
    while (skipped < count) : (skipped += 1) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[line_end + 1 ..];
    }
    return rest;
}

fn valueStyle(column: ValueColumn) vaxis.Style {
    return switch (column) {
        .base, .ours, .theirs => .{},
        .result => .{ .bg = Palette.result_bg },
    };
}

pub const View = struct {
    state: *merge_ui_state.State,
    path: []const u8,
    tree: merge_tree.Model,
    editor: vxfw.TextField,
    editing: bool = false,
    editor_top: usize = 0,
    editor_anchor: ?usize = null,
    editor_drag_origin: ?result_text.Selection = null,
    pasting: bool = false,
    paste_into_result: bool = false,
    paste_buffer: std.ArrayList(u8) = .empty,
    editor_start_resolution: ?core.merge.Resolution = null,
    editor_changed: bool = false,
    editor_reopened: bool = false,
    horizontal_offset: usize = 0,
    column_h: [4]usize = .{ 0, 0, 0, 0 },
    column_v: [4]usize = .{ 0, 0, 0, 0 },
    column_lines: [4]usize = .{ 0, 0, 0, 0 },
    scrollbar_visible: bool = false,
    scrollbar_hide_ticks: u8 = 0,
    vertical_offset: usize = 0,
    focus_area: FocusArea = .hierarchy,
    selected_value: ValueColumn = .ours,
    combine_mode: bool = false,
    dialog: ?Dialog = null,
    dialog_choice: DialogChoice = .cancel,
    last_size: vxfw.Size = .{},
    live_screen: ?*const vaxis.Screen = null,
    raw_view: bool = false,
    property_row: usize = 0,
    property_top: usize = 0,
    property_memory: std.heap.ArenaAllocator,
    editor_document: ?core.merge.properties.Document = null,
    editor_property: ?[]const core.merge.properties.Segment = null,
    editor_semantic_value: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        state: *merge_ui_state.State,
        path: []const u8,
        tree: merge_tree.Model,
    ) View {
        var view: View = .{
            .state = state,
            .path = path,
            .tree = tree,
            .editor = vxfw.TextField.init(allocator),
            .property_memory = std.heap.ArenaAllocator.init(allocator),
        };
        if (state.outcome == .ready) view.focus_area = .complete;
        return view;
    }

    pub fn deinit(self: *View) void {
        self.property_memory.deinit();
        self.paste_buffer.deinit(self.editor.buf.allocator);
        self.editor.deinit();
    }

    pub fn widget(self: *View) vxfw.Widget {
        self.editor.userdata = self;
        self.editor.onChange = markEditorChanged;
        self.editor.onSubmit = submitCustom;
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = draw,
        };
    }

    fn eventSize(self: *const View) vxfw.Size {
        const screen = self.live_screen orelse return self.last_size;
        return .{ .width = screen.width, .height = screen.height };
    }

    fn valueGeometry(self: *const View, width: u16) Geometry {
        var result = Geometry.init(width);
        if (self.usesProperties()) {
            const width_available = result.inspector.end - result.inspector.start;
            const start = result.inspector.start + @max(@as(u16, 12), width_available / 5);
            const value_width = result.inspector.end - start;
            result.base = .{ .start = start, .end = start + value_width / 4 };
            result.ours = .{ .start = result.base.end, .end = start + value_width * 2 / 4 };
            result.theirs = .{ .start = result.ours.end, .end = start + value_width * 3 / 4 };
            result.result.start = result.theirs.end;
        }
        if (self.canCombine()) {
            // Keep both order labels readable without moving columns when the mode changes.
            result.ours.end = @max(result.ours.end, result.ours.start + @as(u16, ours_combined_label.len) + 1);
            result.theirs.start = result.ours.end;
            result.theirs.end = @max(result.theirs.end, result.theirs.start + @as(u16, theirs_combined_label.len) + 1);
            result.result.start = result.theirs.end;
        }
        return result;
    }

    fn hasProperties(self: *const View) bool {
        return inspector.supports(self.selectedOperation() orelse return false);
    }

    fn usesProperties(self: *const View) bool {
        return !self.raw_view and self.hasProperties();
    }

    fn propertyModel(self: *const View, arena: std.mem.Allocator) !inspector.Model {
        const operation = self.selectedOperation().?;
        return inspector.build(arena, operation, self.state.pending orelse operation.resolution, self.state.plan);
    }

    fn ensurePropertyVisible(self: *View, size: vxfw.Size, count: usize) void {
        self.property_row = @min(self.property_row, count -| 1);
        const body = BodyGeometry.init(size.height);
        const height = body.inspector_rows.end - body.inspector_rows.start;
        if (self.property_row < self.property_top) self.property_top = self.property_row;
        if (self.property_row >= self.property_top + height) self.property_top = self.property_row - height + 1;
        self.property_top = @min(self.property_top, count -| height);
    }

    fn moveProperty(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size, down: bool) !void {
        var memory = std.heap.ArenaAllocator.init(self.editor.buf.allocator);
        defer memory.deinit();
        const model = try self.propertyModel(memory.allocator());
        self.property_row = if (down) @min(self.property_row + 1, model.rows.len -| 1) else self.property_row -| 1;
        self.ensurePropertyVisible(size, model.rows.len);
        self.horizontal_offset = 0;
        self.revealScrollbar(ctx);
        ctx.consumeAndRedraw();
    }

    fn editsPropertyCell(self: *const View) bool {
        return self.editor_property != null or self.editor_semantic_value;
    }

    fn editorRow(self: *const View, size: vxfw.Size) u16 {
        const start = BodyGeometry.init(size.height).inspector_rows.start;
        return start + if (self.editsPropertyCell()) @as(u16, @intCast(self.property_row -| self.property_top)) else @as(u16, 0);
    }

    fn inspectorHeadingGeometry(self: *const View, width: u16) InspectorHeadingGeometry {
        return InspectorHeadingGeometry.init(self.valueGeometry(width).inspector, self.canCombine());
    }

    fn ensureSelectionVisible(self: *View, size: vxfw.Size) void {
        if (!isUsableSize(size)) return;
        const visible_rows = BodyGeometry.init(size.height).visibleRows();
        const max_offset = self.tree.rows.len -| visible_rows;
        self.vertical_offset = @min(self.vertical_offset, max_offset);
        const selected_row = self.tree.rowForConflict(self.state.selected_conflict) orelse return;
        if (selected_row < self.vertical_offset) {
            self.vertical_offset = selected_row;
        } else if (selected_row - self.vertical_offset >= visible_rows) {
            self.vertical_offset = selected_row - visible_rows + 1;
        }
        self.vertical_offset = @min(self.vertical_offset, max_offset);
    }

    fn scrollUp(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) void {
        self.vertical_offset -|= 1;
        self.clampVerticalOffset(size);
        ctx.consumeAndRedraw();
    }

    fn scrollDown(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) void {
        self.vertical_offset +|= 1;
        self.clampVerticalOffset(size);
        ctx.consumeAndRedraw();
    }

    fn handleHierarchyWheel(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) bool {
        if (mouse.type != .press or mouse.col < 0) return false;
        if (!inRange(@intCast(mouse.col), self.valueGeometry(size.width).hierarchy)) return false;
        switch (mouse.button) {
            .wheel_up, .wheel_left => self.scrollUp(ctx, size),
            .wheel_down, .wheel_right => self.scrollDown(ctx, size),
            else => return false,
        }
        return true;
    }

    fn clampVerticalOffset(self: *View, size: vxfw.Size) void {
        if (!isUsableSize(size)) return;
        const visible_rows = BodyGeometry.init(size.height).visibleRows();
        self.vertical_offset = @min(self.vertical_offset, self.tree.rows.len -| visible_rows);
    }

    fn dispatch(
        self: *View,
        ctx: *vxfw.EventContext,
        action: merge_ui_state.Action,
        size: vxfw.Size,
    ) !void {
        switch (action) {
            .move_up, .move_down, .select_conflict => self.horizontal_offset = 0,
            else => {},
        }
        const previous_conflict = self.state.selected_conflict;
        try self.state.handle(action);
        if (self.state.selected_conflict != previous_conflict) {
            self.combine_mode = false;
            self.raw_view = false;
            self.property_row = 0;
            self.property_top = 0;
            self.column_h = .{ 0, 0, 0, 0 };
            self.column_v = .{ 0, 0, 0, 0 };
            self.column_lines = .{ 0, 0, 0, 0 };
            self.hideScrollbar();
            self.horizontal_offset = 0;
        }
        self.ensureSelectionVisible(size);
        const should_quit = action == .abort and self.state.outcome == .aborted;
        if (should_quit) ctx.quit = true;
        ctx.consumeAndRedraw();
    }

    fn beginResultEdit(
        self: *View,
        ctx: *vxfw.EventContext,
        initial: []const u8,
    ) !void {
        var input = initial;
        if (self.usesProperties()) {
            if (!core.merge.supportsCustomResolution(self.state.plan, self.selectedOperation().?.id)) {
                self.state.status = "This component supports side selection only.";
                return ctx.consumeAndRedraw();
            }
            _ = self.property_memory.reset(.retain_capacity);
            const model = try self.propertyModel(self.property_memory.allocator());
            if (model.documents[3]) |document| {
                if (!model.editable(self.property_row)) {
                    self.state.status = "This property cannot be edited.";
                    return ctx.consumeAndRedraw();
                }
                self.editor_document = document;
                self.editor_property = model.rows[self.property_row].path;
                input = document.input(model.rows[self.property_row].path).?;
            } else if (hasParsedDocuments(model)) {
                self.state.status = "Choose a component to keep before editing its properties.";
                return ctx.consumeAndRedraw();
            } else {
                if (!selectEditableProperty(&self.property_row, model)) {
                    self.state.status = "This property cannot be edited.";
                    return ctx.consumeAndRedraw();
                }
                // Dictionary and Variant tables are not Unity documents. Edit the Value cell.
                self.editor_document = null;
                self.editor_property = null;
                self.editor_semantic_value = true;
                const cell = try model.text(self.property_memory.allocator(), self.property_row, 3);
                input = if (isPlaceholderValue(cell) or std.mem.eql(u8, cell, "—")) "" else cell;
            }
            self.ensurePropertyVisible(self.eventSize(), model.rows.len);
            self.state.status = "";
        }
        const normalized = try result_text.normalizeNewlines(self.editor.buf.allocator, input);
        defer self.editor.buf.allocator.free(normalized);
        self.editor.clearRetainingCapacity();
        try self.editor.insertSliceAtCursor(normalized);
        const previous_val = try self.editor.buf.allocator.dupe(u8, normalized);
        self.editor.buf.allocator.free(self.editor.previous_val);
        self.editor.previous_val = previous_val;
        self.editing = true;
        self.editor_top = 0;
        self.editor_anchor = null;
        self.editor_drag_origin = null;
        self.editor_start_resolution = self.state.pending;
        if (self.editor_start_resolution == null) {
            if (self.selectedOperation()) |operation| {
                if (operation.resolution != .unresolved) self.editor_start_resolution = operation.resolution;
            }
        }
        self.editor_changed = false;
        self.editor_reopened = false;
        try ctx.requestFocus(self.editor.widget());
        ctx.consumeAndRedraw();
    }

    fn beginTypedEdit(
        self: *View,
        ctx: *vxfw.EventContext,
        key: vaxis.Key,
    ) !void {
        try self.beginResultEdit(ctx, self.selectedResultInput());
        if (!self.editing) return;
        try self.editor.handleEvent(ctx, .{ .key_press = key });
    }

    fn editorSelection(self: *const View) ?result_text.Selection {
        const anchor = self.editor_anchor orelse return null;
        const cursor = self.editor.buf.cursor;
        if (anchor == cursor) return null;
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    fn deleteEditorSelection(self: *View) bool {
        const range = self.editorSelection() orelse return false;
        result_text.setCursor(&self.editor, range.start);
        self.editor.buf.growGapRight(range.end - range.start);
        self.editor_anchor = null;
        self.editor_drag_origin = null;
        return true;
    }

    fn handleEditorKey(self: *View, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        // Kitty keyboard reports can send a modifier before the copy key or terminal paste.
        if (key.isModifier()) {
            ctx.consumeEvent();
            return true;
        }
        self.editor_drag_origin = null;
        if (key.matches('c', .{ .super = true }) or key.matches('c', .{ .ctrl = true })) {
            if (self.editorSelection()) |range| {
                const text = try self.editor.buf.dupe();
                defer self.editor.buf.allocator.free(text);
                try ctx.copyToClipboard(text[range.start..range.end]);
            }
            ctx.consumeEvent();
            return true;
        }
        const newline = key.matches('j', .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{ .shift = true });
        const deletion = key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true });
        const text_input = key.text != null and key.text.?.len != 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.super;
        if (self.editorSelection()) |range| {
            if (deletion or newline or text_input) {
                // Replacement is one edit, so deleting a selection must not reopen the conflict before insertion.
                _ = self.deleteEditorSelection();
                if (deletion) {
                    try self.editor.handleEvent(ctx, .{ .key_press = .{ .codepoint = 0, .text = "" } });
                    return true;
                }
            } else if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.right, .{})) {
                result_text.setCursor(&self.editor, if (key.codepoint == vaxis.Key.left) range.start else range.end);
                self.editor_anchor = null;
                ctx.consumeAndRedraw();
                return true;
            }
        }
        self.editor_anchor = null;
        if (newline) {
            const before = self.editor.buf.firstHalf();
            const start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |at| at + 1 else 0;
            const text = try std.mem.concat(self.editor.buf.allocator, u8, &.{ "\n", before[start .. start + lineIndent(before[start..])] });
            defer self.editor.buf.allocator.free(text);
            try self.editor.handleEvent(ctx, .{ .key_press = .{ .codepoint = 0, .text = text } });
            return true;
        }
        if (try result_text.moveLine(&self.editor, key)) {
            ctx.consumeAndRedraw();
            return true;
        }
        return false;
    }

    fn insertPaste(self: *View, ctx: *vxfw.EventContext, text: []const u8) !void {
        if (text.len == 0) return;
        if (!self.editing) try self.beginResultEdit(ctx, self.selectedResultInput());
        if (!self.editing) return;
        // A paste is one edit; newline key events must never submit a partial value.
        const normalized = try result_text.normalizeNewlines(self.editor.buf.allocator, text);
        defer self.editor.buf.allocator.free(normalized);
        _ = self.deleteEditorSelection();
        self.editor_drag_origin = null;
        try self.editor.handleEvent(ctx, .{ .key_press = .{ .codepoint = 0, .text = normalized } });
    }

    fn handlePaste(self: *View, ctx: *vxfw.EventContext, event: vxfw.Event) !bool {
        switch (event) {
            .paste_start => {
                self.pasting = true;
                self.paste_into_result = isUsableSize(self.eventSize()) and self.dialog == null and
                    self.focus_area == .inspector and self.selected_value == .result;
                self.paste_buffer.clearRetainingCapacity();
            },
            .paste_end => {
                self.pasting = false;
                if (self.paste_into_result and isUsableSize(self.eventSize())) try self.insertPaste(ctx, self.paste_buffer.items);
                self.paste_into_result = false;
                self.paste_buffer.clearRetainingCapacity();
            },
            .key_press => |key| {
                if (!self.pasting) return false;
                if (!isUsableSize(self.eventSize())) self.paste_into_result = false;
                if (self.paste_into_result) {
                    const allocator = self.editor.buf.allocator;
                    if (key.matches(vaxis.Key.enter, .{})) {
                        try self.paste_buffer.append(allocator, '\r');
                    } else if (key.matches(vaxis.Key.tab, .{})) {
                        try self.paste_buffer.append(allocator, '\t');
                    } else if (key.mods.ctrl and key.codepoint >= 'a' and key.codepoint <= 'z') {
                        try self.paste_buffer.append(allocator, @intCast(key.codepoint - 'a' + 1));
                    } else if (key.text) |text| {
                        try self.paste_buffer.appendSlice(allocator, text);
                    }
                }
            },
            .mouse => if (!self.pasting) return false,
            .paste => |text| {
                defer ctx.alloc.free(text);
                if (isUsableSize(self.eventSize()) and self.dialog == null and self.focus_area == .inspector and self.selected_value == .result)
                    try self.insertPaste(ctx, text);
            },
            else => return false,
        }
        ctx.consumeAndRedraw();
        return true;
    }

    fn applyPendingResult(
        self: *View,
        ctx: *vxfw.EventContext,
        size: vxfw.Size,
    ) !void {
        if (self.state.selected_conflict >= self.state.conflict_indices.len) return;
        const operation_index = self.state.conflict_indices[self.state.selected_conflict];
        const previous_conflict = self.state.selected_conflict;
        try self.state.handle(.apply_result);
        self.ensureSelectionVisible(size);
        const applied = self.state.status.len == 0 and
            self.state.plan.operations[operation_index].resolution != .unresolved;
        if (applied) {
            self.combine_mode = false;
            self.resetEditor();
            self.property_row = 0;
            self.property_top = 0;
            if (self.state.selected_conflict != previous_conflict) self.raw_view = false;
            if (self.state.outcome == .ready) {
                self.focus_area = .complete;
            } else {
                self.focus_area = .hierarchy;
                try self.state.handle(.pane_left);
            }
            try ctx.requestFocus(self.widget());
        }
        ctx.consumeAndRedraw();
    }

    fn hideScrollbar(self: *View) void {
        self.scrollbar_visible = false;
        self.scrollbar_hide_ticks = 0;
    }

    fn revealScrollbar(self: *View, ctx: *vxfw.EventContext) void {
        self.scrollbar_visible = true;
        self.scrollbar_hide_ticks +|= 1;
        ctx.tick(scrollbar_hide_ms, self.widget()) catch {};
    }

    fn expireScrollbar(self: *View, ctx: *vxfw.EventContext) void {
        if (self.scrollbar_hide_ticks > 0) self.scrollbar_hide_ticks -= 1;
        if (self.scrollbar_hide_ticks != 0 or !self.scrollbar_visible) return;
        self.scrollbar_visible = false;
        ctx.consumeAndRedraw();
    }

    fn shouldPaintFloatingScrollbar(self: *const View) bool {
        return self.focus_area == .inspector and self.scrollbar_visible;
    }

    fn focusHierarchy(self: *View, ctx: *vxfw.EventContext) !void {
        self.hideScrollbar();
        self.focus_area = .hierarchy;
        self.horizontal_offset = 0;
        try self.state.handle(.pane_left);
        ctx.consumeAndRedraw();
    }

    fn focusInspector(self: *View, ctx: *vxfw.EventContext) !void {
        self.hideScrollbar();
        self.focus_area = .inspector;
        self.selected_value = .ours;
        self.horizontal_offset = 0;
        try self.state.handle(.pane_right);
        ctx.consumeAndRedraw();
    }

    fn focusResult(self: *View, ctx: *vxfw.EventContext) !void {
        self.hideScrollbar();
        self.focus_area = .inspector;
        self.selected_value = .result;
        self.horizontal_offset = 0;
        try self.state.handle(.pane_right);
        ctx.consumeAndRedraw();
    }

    fn editorCellAt(self: *View, mouse: vaxis.Mouse, size: vxfw.Size) !result_text.Selection {
        const geometry = self.valueGeometry(size.width);
        const body = BodyGeometry.init(size.height);
        const col: usize = @intCast(@max(mouse.col, 0));
        const row: usize = @intCast(@max(mouse.row, 0));
        return result_text.cellAt(
            &self.editor,
            geometry.result.end - geometry.result.start -| 2,
            self.editor_top + std.math.clamp(row, self.editorRow(size), if (self.editsPropertyCell()) self.editorRow(size) else body.inspector_rows.end - 1) - self.editorRow(size),
            col -| (geometry.result.start + 2),
        );
    }

    fn handleMouseWhileEditing(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) !void {
        if (self.editor_drag_origin) |origin| {
            if (mouse.type == .drag or mouse.type == .release) {
                const body = BodyGeometry.init(size.height);
                if (mouse.type == .drag) {
                    if (mouse.row < body.inspector_rows.start) self.editor_top -|= 1;
                    if (mouse.row >= body.inspector_rows.end) self.editor_top += 1;
                    self.editor_anchor = origin.start;
                }
                if (self.editor_anchor != null) {
                    // Cell coordinates have no left/right half, so both endpoint glyphs belong to a drag.
                    const cell = try self.editorCellAt(mouse, size);
                    const backward = cell.start < origin.start;
                    self.editor_anchor = if (backward) origin.end else origin.start;
                    result_text.setCursor(&self.editor, if (backward) cell.start else cell.end);
                }
                if (mouse.type == .release) self.editor_drag_origin = null;
                return ctx.consumeAndRedraw();
            }
        }
        if (self.handleHierarchyWheel(ctx, mouse, size)) return;
        if (mouse.type != .press or mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const geometry = self.valueGeometry(size.width);
        const body = BodyGeometry.init(size.height);
        if (row >= body.inspector_rows.start and row < body.inspector_rows.end and inRange(col, geometry.result) and
            (self.editsPropertyCell() == false or row == self.editorRow(size)))
        {
            const cell = try self.editorCellAt(mouse, size);
            result_text.setCursor(&self.editor, cell.start);
            self.editor_anchor = null;
            self.editor_drag_origin = cell;
            return ctx.consumeAndRedraw();
        }
        if (!try self.finishEditorForNavigation(ctx)) return;
        try self.handleMouse(ctx, mouse, size);
    }

    fn resetEditor(self: *View) void {
        self.editor.clearRetainingCapacity();
        self.editing = false;
        self.editor_top = 0;
        self.editor_anchor = null;
        self.editor_drag_origin = null;
        self.editor_start_resolution = null;
        self.editor_changed = false;
        self.editor_reopened = false;
        self.editor_document = null;
        self.editor_property = null;
        self.editor_semantic_value = false;
        _ = self.property_memory.reset(.retain_capacity);
    }

    fn leaveEditorWithoutApply(self: *View, ctx: *vxfw.EventContext) !void {
        self.state.pending = if (self.editor_reopened) null else self.editor_start_resolution;
        self.state.status = "";
        self.resetEditor();
        self.focus_area = .inspector;
        self.selected_value = .result;
        try ctx.requestFocus(self.widget());
        ctx.consumeAndRedraw();
    }

    fn reopenResult(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        try self.state.handle(.reopen_result);
        self.resetEditor();
        try self.focusHierarchy(ctx);
        self.ensureSelectionVisible(size);
        try ctx.requestFocus(self.widget());
    }

    fn leaveResultForHierarchy(self: *View, ctx: *vxfw.EventContext) !void {
        if (self.editor_changed and !self.editsPropertyCell()) {
            const input = try self.editor.toOwnedSlice();
            defer self.editor.buf.allocator.free(input);
            if (std.mem.trim(u8, input, "\r\n").len == 0) return self.reopenResult(ctx, self.eventSize());
        }
        try self.leaveEditorWithoutApply(ctx);
        try self.focusHierarchy(ctx);
    }

    fn finishEditorForNavigation(
        self: *View,
        ctx: *vxfw.EventContext,
    ) !bool {
        if (!self.editor_changed) {
            try self.leaveEditorWithoutApply(ctx);
            return true;
        }
        const input = try self.editor.toOwnedSlice();
        defer self.editor.buf.allocator.free(input);
        if (std.mem.trim(u8, input, "\r\n").len == 0) {
            if (self.editsPropertyCell()) {
                try self.openDialog(ctx, .empty);
                return false;
            }
            try self.reopenResult(ctx, self.eventSize());
            return true;
        }
        try submitCustom(self, ctx, input);
        return !self.editing;
    }

    fn focusComplete(self: *View, ctx: *vxfw.EventContext) void {
        self.focus_area = .complete;
        self.horizontal_offset = 0;
        ctx.consumeAndRedraw();
    }

    fn openDialog(self: *View, ctx: *vxfw.EventContext, kind: Dialog) !void {
        self.dialog = kind;
        self.dialog_choice = .cancel;
        // Empty-value confirmation temporarily takes focus from the Result editor.
        if (kind == .empty) try ctx.requestFocus(self.widget());
        ctx.consumeAndRedraw();
    }

    fn closeDialog(self: *View, ctx: *vxfw.EventContext) !void {
        const kind = self.dialog orelse return;
        self.dialog = null;
        self.dialog_choice = .cancel;
        if (kind == .empty) try ctx.requestFocus(self.editor.widget());
        ctx.consumeAndRedraw();
    }

    fn confirmDialog(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        const kind = self.dialog orelse return;
        self.dialog = null;
        self.dialog_choice = .cancel;
        switch (kind) {
            .quit => try self.dispatch(ctx, .abort, size),
            .empty => {
                if (self.editor_property != null) return self.submitProperty(ctx, "");
                const payload = try self.customResultInput("");
                try self.state.handle(.{ .edit_result = payload });
                try self.applyPendingResult(ctx, size);
                if (self.editing) try ctx.requestFocus(self.editor.widget());
            },
        }
    }

    fn handleDialog(
        self: *View,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
        size: vxfw.Size,
    ) !void {
        const kind = self.dialog orelse return;
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'y' or key.codepoint == 'Y') {
                    return self.confirmDialog(ctx, size);
                }
                if (key.codepoint == 'n' or key.codepoint == 'N' or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    return self.closeDialog(ctx);
                }
                if (key.matches(vaxis.Key.left, .{})) {
                    self.dialog_choice = .cancel;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{})) {
                    self.dialog_choice = .confirm;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    return switch (self.dialog_choice) {
                        .cancel => self.closeDialog(ctx),
                        .confirm => self.confirmDialog(ctx, size),
                    };
                }
                ctx.consumeEvent();
            },
            .mouse => |mouse| {
                if (mouse.type != .press or mouse.button != .left or
                    mouse.col < 0 or mouse.row < 0)
                {
                    return ctx.consumeEvent();
                }
                const dialog = DialogGeometry.init(size.width, size.height, kind);
                const col: u16 = @intCast(mouse.col);
                const row: u16 = @intCast(mouse.row);
                if (row == dialog.buttons_row and inRange(col, dialog.cancel)) {
                    return self.closeDialog(ctx);
                }
                if (row == dialog.buttons_row and inRange(col, dialog.confirm)) {
                    return self.confirmDialog(ctx, size);
                }
                ctx.consumeEvent();
            },
            else => {},
        }
    }

    fn selectedOperation(self: *const View) ?*const core.merge.Operation {
        if (self.state.selected_conflict >= self.state.conflict_indices.len) return null;
        const operation_index = self.state.conflict_indices[self.state.selected_conflict];
        return &self.state.plan.operations[operation_index];
    }

    fn columnText(self: *const View, arena: std.mem.Allocator, operation: *const core.merge.Operation, column: ValueColumn) std.mem.Allocator.Error![]const u8 {
        const pending = self.state.pending orelse operation.resolution;
        if (self.combinedChoices() and (column == .ours or column == .theirs)) {
            return core.merge.combinedCollectionValue(arena, self.state.plan, operation.id, if (column == .ours) .ours_first else .theirs_first) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => "<unavailable>",
            };
        }
        return switch (column) {
            .base => displaySide(self.state.plan, operation, .base, operation.values.base),
            .ours => displaySide(self.state.plan, operation, .ours, operation.values.ours),
            .theirs => displaySide(self.state.plan, operation, .theirs, operation.values.theirs),
            .result => try displayResolution(arena, self.state.plan, operation, pending),
        };
    }

    fn selectedText(self: *const View, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const operation = self.selectedOperation() orelse return "";
        if (self.usesProperties()) {
            const model = try self.propertyModel(arena);
            if (self.property_row >= model.rows.len) return "";
            return model.text(arena, self.property_row, @intFromEnum(self.selected_value));
        }
        return self.columnText(arena, operation, self.selected_value);
    }

    fn submitProperty(self: *View, ctx: *vxfw.EventContext, input: []const u8) !void {
        const bytes = core.merge.properties.edit(self.property_memory.allocator(), self.editor_document.?, self.editor_property.?, input) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => input,
        };
        try self.state.handle(.{ .edit_result = bytes });
        try self.applyPendingResult(ctx, self.eventSize());
    }

    fn selectedResultInput(self: *const View) []const u8 {
        const operation = self.selectedOperation() orelse return "";
        const resolution = self.state.pending orelse operation.resolution;
        return switch (resolution) {
            .unresolved => "",
            .take => |side| displaySide(self.state.plan, operation, side, operation.values.get(side)),
            .remove => "",
            .custom => |value| displayResolution(self.editor.buf.allocator, self.state.plan, operation, .{ .custom = value }) catch value,
        };
    }

    fn customResultInput(self: *View, input: []const u8) ![]const u8 {
        const operation = self.selectedOperation() orelse return input;
        if (operation.kind == .prefab_override) {
            if (self.editor_semantic_value) return input;
            return extractOverrideValue(input);
        }
        if (operation.kind == .field) {
            return dictionaryCustom(self.property_memory.allocator(), self.state.plan, operation, input);
        }
        return input;
    }

    fn resultIsRemoval(self: *const View) bool {
        const operation = self.selectedOperation() orelse return false;
        return switch (self.state.pending orelse operation.resolution) {
            .remove => true,
            .take => |side| operation.values.get(side) == null,
            else => false,
        };
    }

    fn maxHorizontalOffset(self: *const View, geometry: Geometry) usize {
        var memory = std.heap.ArenaAllocator.init(self.state.allocator);
        defer memory.deinit();
        const text = self.selectedText(memory.allocator()) catch return 0;
        const selected_range = valueRange(geometry, self.selected_value);
        const viewport_width: usize = selected_range.end - selected_range.start -| 2;
        var total_width: usize = 0;
        var grapheme_count: usize = 0;
        var graphemes = vaxis.unicode.graphemeIterator(text);
        while (graphemes.next()) |grapheme| {
            total_width +|= vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode);
            grapheme_count += 1;
        }
        if (total_width <= viewport_width or grapheme_count <= 1) return 0;

        var removed_width: usize = 0;
        var skipped: usize = 0;
        graphemes = vaxis.unicode.graphemeIterator(text);
        while (graphemes.next()) |grapheme| {
            if (skipped + 1 >= grapheme_count) return skipped;
            removed_width +|= vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode);
            skipped += 1;
            if (total_width -| removed_width <= viewport_width) return skipped;
        }
        return skipped;
    }

    fn scrollLeft(self: *View, ctx: *vxfw.EventContext) void {
        const index = @intFromEnum(self.selected_value);
        self.column_h[index] -|= 1;
        self.horizontal_offset = self.column_h[index];
        ctx.consumeAndRedraw();
    }

    fn scrollRight(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) void {
        const geometry = self.valueGeometry(size.width);
        const index = @intFromEnum(self.selected_value);
        self.column_h[index] = @min(self.column_h[index] +| 1, self.maxHorizontalOffset(geometry));
        self.horizontal_offset = self.column_h[index];
        ctx.consumeAndRedraw();
    }

    fn inspectorViewportRows(self: *const View) usize {
        if (!isUsableSize(self.last_size)) return 0;
        const rows = BodyGeometry.init(self.last_size.height).inspector_rows;
        return rows.end - rows.start;
    }

    fn prepareColumnScroll(
        self: *View,
        index: usize,
        text: []const u8,
        viewport: usize,
        range: Range,
        indent: usize,
    ) Range {
        const metrics = columnScrollMetrics(range, text, viewport, indent);
        self.column_lines[index] = metrics.rows;
        self.column_v[index] = @min(self.column_v[index], maxScrollOffset(metrics.rows, viewport));
        return reservedScrollRange(range, metrics.rows, viewport);
    }

    fn paintColumnScrollbars(
        self: *const View,
        surface: vxfw.Surface,
        geometry: Geometry,
        body: BodyGeometry,
    ) void {
        if (!self.shouldPaintFloatingScrollbar()) return;
        const index = @intFromEnum(self.selected_value);
        const range = valueRange(geometry, self.selected_value);
        paintScrollbar(
            surface,
            range.end -| 1,
            body.inspector_rows.start,
            body.inspector_rows.end,
            self.column_v[index],
            self.column_lines[index],
        );
    }

    fn scrollColumnVertical(self: *View, ctx: *vxfw.EventContext, column: ValueColumn, down: bool) void {
        const index = @intFromEnum(column);
        const max = maxScrollOffset(self.column_lines[index], self.inspectorViewportRows());
        if (down) self.column_v[index] = @min(self.column_v[index] +| 1, max) else self.column_v[index] -|= 1;
        self.revealScrollbar(ctx);
        ctx.consumeAndRedraw();
    }

    fn moveLeft(self: *View, ctx: *vxfw.EventContext) !void {
        switch (self.focus_area) {
            .hierarchy => ctx.consumeEvent(),
            .inspector => switch (self.selected_value) {
                .base, .ours => try self.focusHierarchy(ctx),
                .theirs => {
                    self.hideScrollbar();
                    self.selected_value = .ours;
                    self.horizontal_offset = 0;
                    ctx.consumeAndRedraw();
                },
                .result => {
                    self.hideScrollbar();
                    self.selected_value = .theirs;
                    self.horizontal_offset = 0;
                    ctx.consumeAndRedraw();
                },
            },
            .complete => try self.focusHierarchy(ctx),
        }
    }

    fn moveRight(self: *View, ctx: *vxfw.EventContext) !void {
        switch (self.focus_area) {
            .hierarchy => try self.focusInspector(ctx),
            .inspector => {
                self.hideScrollbar();
                self.selected_value = switch (self.selected_value) {
                    .base, .ours => .theirs,
                    .theirs, .result => .result,
                };
                self.horizontal_offset = 0;
                ctx.consumeAndRedraw();
            },
            .complete => ctx.consumeEvent(),
        }
    }

    fn moveUp(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        switch (self.focus_area) {
            .hierarchy => try self.dispatch(ctx, .move_up, size),
            .inspector => if (self.usesProperties()) try self.moveProperty(ctx, size, false) else self.scrollColumnVertical(ctx, self.selected_value, false),
            .complete => try self.focusResult(ctx),
        }
    }

    fn moveDown(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        switch (self.focus_area) {
            .hierarchy => {
                if (self.state.selected_conflict + 1 < self.state.conflict_indices.len) {
                    return self.dispatch(ctx, .move_down, size);
                }
                if (self.state.outcome == .ready) self.focusComplete(ctx) else ctx.consumeEvent();
            },
            .inspector => if (self.usesProperties()) try self.moveProperty(ctx, size, true) else self.scrollColumnVertical(ctx, self.selected_value, true),
            .complete => ctx.consumeEvent(),
        }
    }

    fn activate(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        switch (self.focus_area) {
            .hierarchy => try self.focusInspector(ctx),
            .inspector => switch (self.selected_value) {
                .base, .ours => {
                    try self.state.handle(self.choiceAction(.ours));
                    try self.applyPendingResult(ctx, size);
                },
                .theirs => {
                    try self.state.handle(self.choiceAction(.theirs));
                    try self.applyPendingResult(ctx, size);
                },
                .result => try self.beginResultEdit(ctx, self.selectedResultInput()),
            },
            .complete => {
                if (self.state.outcome == .ready) ctx.quit = true;
                ctx.consumeEvent();
            },
        }
    }

    fn canCombine(self: *const View) bool {
        const operation = self.selectedOperation() orelse return false;
        const conflict = core.merge.collectionConflict(self.state.plan, operation.id) orelse return false;
        return conflict.both_orders;
    }

    fn combinedChoices(self: *const View) bool {
        return self.combine_mode and self.canCombine();
    }

    fn toggleCombine(self: *View, ctx: *vxfw.EventContext) void {
        self.combine_mode = !self.combine_mode;
        self.horizontal_offset = 0;
        ctx.consumeAndRedraw();
    }

    fn choiceAction(self: *const View, column: ValueColumn) merge_ui_state.Action {
        return switch (column) {
            .ours => if (self.combinedChoices()) .combine_ours_first else .choose_ours,
            .theirs => if (self.combinedChoices()) .combine_theirs_first else .choose_theirs,
            .base, .result => unreachable,
        };
    }

    fn handleMouse(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) !void {
        if (self.handleHierarchyWheel(ctx, mouse, size)) return;
        const geometry = self.valueGeometry(size.width);
        if (isWheelButton(mouse.button)) {
            if (mouse.mods.shift) {
                if (mouse.button == .wheel_left or mouse.button == .wheel_up) return self.scrollLeft(ctx);
                if (mouse.button == .wheel_right or mouse.button == .wheel_down) return self.scrollRight(ctx, size);
                return;
            }
            const down = mouse.button == .wheel_down or mouse.button == .wheel_right;
            if (self.usesProperties() and mouse.col >= geometry.inspector.start) {
                return self.moveProperty(ctx, size, down);
            }
            if (columnAt(geometry, mouse.col)) |column| {
                if (self.focus_area == .inspector and column == self.selected_value) {
                    return self.scrollColumnVertical(ctx, column, down);
                }
                return;
            }
        }
        if (mouse.type != .press) return;
        if (mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const footer = FooterGeometry.init(size.width, size.height);
        const body = BodyGeometry.init(size.height);
        if (row == body.inspector_heading_row) {
            const heading = self.inspectorHeadingGeometry(size.width);
            if (heading.raw) |toggle| if (inRange(col, toggle)) {
                self.raw_view = !self.raw_view;
                self.horizontal_offset = 0;
                return ctx.consumeAndRedraw();
            };
            if (heading.combine) |toggle| if (inRange(col, toggle)) {
                return self.toggleCombine(ctx);
            };
        }
        if (self.state.outcome == .ready and
            row == footer.row and inRange(col, footer.complete))
        {
            self.focus_area = .complete;
            ctx.quit = true;
            return ctx.consumeEvent();
        }
        if (inRange(col, geometry.hierarchy) and
            row >= body.hierarchy_rows.start and row < body.hierarchy_rows.end)
        {
            const tree_index = self.vertical_offset + row - body.hierarchy_rows.start;
            if (tree_index >= self.tree.rows.len) return;
            const conflict_index = self.tree.rows[tree_index].conflict_index orelse return;
            self.focus_area = .hierarchy;
            try self.state.handle(.pane_left);
            return self.dispatch(ctx, .{ .select_conflict = conflict_index }, size);
        }
        if (row < body.inspector_rows.start or row >= body.inspector_rows.end or self.selectedOperation() == null) return;
        if (self.usesProperties()) {
            var memory = std.heap.ArenaAllocator.init(self.editor.buf.allocator);
            defer memory.deinit();
            const model = try self.propertyModel(memory.allocator());
            const index = self.property_top + row - body.inspector_rows.start;
            if (index >= model.rows.len) return;
            self.property_row = index;
        }
        if (inRange(col, geometry.ours)) {
            self.focus_area = .inspector;
            self.selected_value = .ours;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            return self.dispatch(ctx, self.choiceAction(.ours), size);
        }
        if (inRange(col, geometry.theirs)) {
            self.focus_area = .inspector;
            self.selected_value = .theirs;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            return self.dispatch(ctx, self.choiceAction(.theirs), size);
        }
        if (inRange(col, geometry.result)) {
            self.focus_area = .inspector;
            self.selected_value = .result;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            try self.beginResultEdit(ctx, self.selectedResultInput());
            if (self.editing) self.editor_drag_origin = try self.editorCellAt(mouse, size);
            return;
        }
        if (inRange(col, geometry.inspector)) return self.focusInspector(ctx);
    }
};

fn rawSideText(value: ?core.merge.SideValue) []const u8 {
    return if (value) |present| present.bytes else "";
}

fn sideText(value: ?core.merge.SideValue) []const u8 {
    const present = value orelse return "";
    return if (present.bytes.len == 0) "<empty>" else present.bytes;
}

fn displaySide(
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    side: core.merge.Side,
    value: ?core.merge.SideValue,
) []const u8 {
    if (documentPreview(plan, operation, side)) |bytes| return bytes;
    if (operation.kind == .prefab_override) {
        if (prefabOverrideRaw(plan, operation, side)) |bytes| return bytes;
    }
    return sideText(value);
}

fn prefabOverrideRaw(
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    side: core.merge.Side,
) ?[]const u8 {
    const file = plan.file(side);
    const target_id = if (operation.identity.item_ref) |reference| reference.file_id else 0;
    for (file.documents) |*document| {
        if (document.file_id != operation.identity.document.file_id) continue;
        const modification = document.body.get("m_Modification") orelse continue;
        if (modification.* != .map) continue;
        const list = modification.get("m_Modifications") orelse continue;
        if (list.* != .seq) continue;
        for (list.seq) |item| {
            const path = core.model.Node.asScalar(item.get("propertyPath")) orelse continue;
            if (!std.mem.eql(u8, path, operation.identity.property_path)) continue;
            if (core.model.Node.asRef(item.get("target"))) |target| {
                if (target.file_id != target_id) continue;
            }
            const raw = file.sequenceItemBytes(item) orelse continue;
            return std.mem.trim(u8, raw, "\r\n");
        }
    }
    return null;
}

fn displayResolution(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) std.mem.Allocator.Error![]const u8 {
    return switch (resolution) {
        .unresolved => "",
        .take => |side| displaySide(plan, operation, side, operation.values.get(side)),
        .remove => "",
        .custom => |value| if (value.len == 0) "" else try customResultDisplay(arena, plan, operation, value),
    };
}

fn customResultDisplay(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const scalar = customScalarText(value) orelse return value;
    if (operation.kind == .prefab_override) {
        if (try patchedPrefabOverrideDisplay(arena, plan, operation, scalar)) |bytes| return bytes;
    }
    if (operation.kind == .field) {
        if (try patchedDictionaryItemDisplay(arena, plan, operation, scalar)) |bytes| return bytes;
    }
    return value;
}

fn customScalarText(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") == null and
        !std.mem.startsWith(u8, std.mem.trimStart(u8, trimmed, " "), "- ") and
        !std.mem.startsWith(u8, trimmed, "{"))
    {
        return trimmed;
    }
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const content = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, content, "value:")) {
            found = std.mem.trim(u8, content["value:".len..], " ");
        }
    }
    return found;
}

fn templateSide(operation: *const core.merge.Operation) ?core.merge.Side {
    if (operation.values.theirs != null) return .theirs;
    if (operation.values.ours != null) return .ours;
    if (operation.values.base != null) return .base;
    return null;
}

fn patchedDictionaryItemDisplay(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    scalar: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const side = templateSide(operation) orelse return null;
    const pair = operation.values.get(side) orelse return null;
    const node = pair.node orelse return null;
    if (node.* != .map) return null;
    const value_node = node.get("value") orelse node.get("second") orelse return null;
    return patchedSequenceItemDisplay(arena, plan.file(side), node, value_node, scalar);
}

fn patchedPrefabOverrideDisplay(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    scalar: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const side = templateSide(operation) orelse return null;
    const value = operation.values.get(side) orelse return null;
    const value_node = value.node orelse return null;
    const file = plan.file(side);
    const target_id = if (operation.identity.item_ref) |reference| reference.file_id else 0;
    for (file.documents) |*document| {
        if (document.file_id != operation.identity.document.file_id) continue;
        const modification = document.body.get("m_Modification") orelse continue;
        if (modification.* != .map) continue;
        const list = modification.get("m_Modifications") orelse continue;
        if (list.* != .seq) continue;
        for (list.seq) |item| {
            const path = core.model.Node.asScalar(item.get("propertyPath")) orelse continue;
            if (!std.mem.eql(u8, path, operation.identity.property_path)) continue;
            if (core.model.Node.asRef(item.get("target"))) |target| {
                if (target.file_id != target_id) continue;
            }
            return patchedSequenceItemDisplay(arena, file, item, value_node, scalar);
        }
    }
    return null;
}

fn patchedSequenceItemDisplay(
    arena: std.mem.Allocator,
    file: core.source.ParsedFile,
    item: *const core.model.Node,
    value_node: *const core.model.Node,
    scalar: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const item_span = file.sequence_item_spans.get(item) orelse return null;
    const value_span = file.node_spans.get(value_node) orelse return null;
    if (value_span.start < item_span.start or value_span.end > item_span.end) return null;
    const patched = try std.mem.concat(arena, u8, &.{
        file.bytes[item_span.start..value_span.start],
        scalar,
        file.bytes[value_span.end..item_span.end],
    });
    return std.mem.trim(u8, patched, "\r\n");
}

fn documentPreview(
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    side: core.merge.Side,
) ?[]const u8 {
    const file_id = switch (operation.kind) {
        .sequence_membership => (operation.identity.item_ref orelse return null).file_id,
        .component, .document, .game_object => operation.identity.document.file_id,
        else => return null,
    };
    const file = plan.file(side);
    for (file.documents, file.document_spans) |document, span| {
        if (document.file_id == file_id) return span.whole.bytes(file.bytes);
    }
    return null;
}

fn connectorText(connector: merge_tree.Connector) []const u8 {
    return switch (connector) {
        .root => "",
        .tee => "├─",
        .elbow => "└─",
        .continuation => "│ ",
    };
}

fn treeRowText(
    arena: std.mem.Allocator,
    row: merge_tree.Row,
    resolved: bool,
) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendNTimes(arena, ' ', @as(usize, row.depth) * 2);
    try text.appendSlice(arena, connectorText(row.connector));
    if (row.connector != .root) try text.append(arena, ' ');
    if (row.kind == .game_object) try text.appendSlice(arena, "◆ ");
    if (row.conflict_index != null) {
        try text.appendSlice(arena, if (resolved) "✓ " else "! ");
    }
    try text.appendSlice(arena, row.label);
    return text.toOwnedSlice(arena);
}

fn treeRowResolved(self: *const View, row: merge_tree.Row) bool {
    const conflict_index = row.conflict_index orelse return false;
    if (conflict_index >= self.state.conflict_indices.len) return false;
    const operation_index = self.state.conflict_indices[conflict_index];
    return self.state.plan.operations[operation_index].resolution != .unresolved;
}

fn selectedComponentName(self: *const View) []const u8 {
    const selected_row = self.tree.rowForConflict(self.state.selected_conflict) orelse return "";
    var index = selected_row + 1;
    while (index > 0) {
        index -= 1;
        const row = self.tree.rows[index];
        if (row.kind == .component) return row.label;
        if (row.kind == .game_object) return row.label;
    }
    return "";
}

fn selectedPropertyName(self: *const View) []const u8 {
    const selected_row = self.tree.rowForConflict(self.state.selected_conflict) orelse return "";
    const row = self.tree.rows[selected_row];
    return if (row.kind == .conflict) row.label else "";
}

fn skipGraphemes(text: []const u8, count: usize) []const u8 {
    var iterator = vaxis.unicode.graphemeIterator(text);
    var skipped: usize = 0;
    var byte_offset: usize = 0;
    while (skipped < count) : (skipped += 1) {
        const grapheme = iterator.next() orelse return text[text.len..];
        byte_offset = grapheme.start + grapheme.len;
    }
    return text[byte_offset..];
}

fn textWidth(text: []const u8) u16 {
    var columns: u16 = 0;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        columns +|= vaxis.gwidth.gwidth(grapheme.bytes(text), .unicode);
    }
    return columns;
}

fn draw(
    userdata: *anyopaque,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const self: *View = @ptrCast(@alignCast(userdata));
    const size: vxfw.Size = .{
        .width = ctx.max.width orelse ctx.min.width,
        .height = ctx.max.height orelse ctx.min.height,
    };
    const size_changed = size.width != self.last_size.width or size.height != self.last_size.height;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    self.last_size = size;
    if (!isUsableSize(size)) {
        writeClipped(
            surface,
            0,
            0,
            size.width,
            "Needs 80 columns and 10 rows. Resize the terminal.",
        );
        if (self.editing) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = vxfw.Surface.empty(self.editor.widget()),
            };
            surface.children = children;
        }
        return surface;
    }

    const geometry = self.valueGeometry(size.width);
    const footer = FooterGeometry.init(size.width, size.height);
    const body = BodyGeometry.init(size.height);
    if (size_changed) self.ensureSelectionVisible(size) else self.clampVerticalOffset(size);
    const selected_index = @intFromEnum(self.selected_value);
    self.column_h[selected_index] = @min(self.column_h[selected_index], self.maxHorizontalOffset(geometry));
    self.horizontal_offset = self.column_h[selected_index];
    const unresolved = try std.fmt.allocPrint(
        ctx.arena,
        "{d} unresolved",
        .{self.state.unresolvedCount()},
    );
    const content_start = geometry.hierarchy.start;
    const content_end = geometry.inspector.end;
    writeClipped(surface, content_start, body.header_row, content_end - content_start - 20, self.path);
    writeClipped(surface, content_end - @as(u16, @intCast(unresolved.len)), body.header_row, @intCast(unresolved.len), unresolved);
    styleRange(
        surface,
        body.header_row,
        .{ .start = content_start, .end = content_end - 20 },
        .{ .bold = true },
    );
    styleRange(
        surface,
        body.header_row,
        .{ .start = content_end - 20, .end = content_end },
        .{ .fg = Palette.conflict },
    );
    const inspector_heading = try std.fmt.allocPrint(
        ctx.arena,
        "{s}{s}{s}",
        .{
            selectedComponentName(self),
            if (selectedPropertyName(self).len == 0) "" else " › ",
            selectedPropertyName(self),
        },
    );
    const heading = self.inspectorHeadingGeometry(size.width);
    writeClipped(
        surface,
        heading.title.start,
        body.inspector_heading_row,
        heading.title.end - heading.title.start,
        inspector_heading,
    );
    styleRange(surface, body.inspector_heading_row, geometry.inspector, .{ .fg = Palette.muted });
    if (heading.raw) |toggle| {
        writeClipped(surface, toggle.start, body.inspector_heading_row, toggle.end - toggle.start, if (self.raw_view) "⇧R Semantic" else "⇧R Raw");
    }
    if (self.usesProperties()) {
        writeClipped(surface, geometry.inspector.start, body.inspector_labels_row, geometry.base.start - geometry.inspector.start, "Property");
        styleRange(
            surface,
            body.inspector_labels_row,
            .{ .start = geometry.inspector.start, .end = geometry.base.start },
            .{ .fg = Palette.muted },
        );
    }
    if (heading.combine) |toggle| {
        writeClipped(surface, toggle.start, body.inspector_heading_row, toggle.end - toggle.start, if (self.combine_mode) "⇧T Both sides" else "⇧T One side");
    }
    inline for (.{
        .{ geometry.base, "Base", ValueColumn.base },
        .{ geometry.ours, "Ours", ValueColumn.ours },
        .{ geometry.theirs, "Theirs", ValueColumn.theirs },
        .{ geometry.result, "Result", ValueColumn.result },
    }) |column| {
        const label = if (self.combinedChoices()) switch (column[2]) {
            .ours => ours_combined_label,
            .theirs => theirs_combined_label,
            .base, .result => column[1],
        } else column[1];
        writeClipped(
            surface,
            column[0].start,
            body.inspector_labels_row,
            column[0].end - column[0].start,
            label,
        );
        styleRange(surface, body.inspector_labels_row, column[0], .{ .fg = Palette.muted });
    }
    for (body.inspector_rows.start..body.inspector_rows.end) |row| {
        styleRange(surface, @intCast(row), geometry.result, .{ .bg = Palette.result_bg });
    }

    for (self.tree.rows[self.vertical_offset..], 0..) |tree_row, visible_index| {
        const row = visible_index + body.hierarchy_rows.start;
        if (row >= body.hierarchy_rows.end) break;
        const selected = tree_row.conflict_index != null and
            tree_row.conflict_index.? == self.state.selected_conflict;
        const label = try treeRowText(ctx.arena, tree_row, treeRowResolved(self, tree_row));
        writeClipped(
            surface,
            geometry.hierarchy.start + 1,
            @intCast(row),
            geometry.hierarchy.end - geometry.hierarchy.start - 1,
            label,
        );
        if (tree_row.kind == .components) {
            styleRange(surface, @intCast(row), geometry.hierarchy, .{ .fg = Palette.muted });
        }
        if (selected) {
            const selected_bg = if (self.focus_area == .hierarchy)
                Palette.focus_bg
            else
                Palette.result_bg;
            styleRange(surface, @intCast(row), geometry.hierarchy, .{ .bg = selected_bg });
            if (self.focus_area == .hierarchy) {
                surface.writeCell(geometry.hierarchy.start, @intCast(row), .{
                    .char = .{ .grapheme = "▌", .width = 1 },
                    .style = .{ .fg = Palette.accent, .bg = Palette.focus_bg },
                });
            }
        }
        const connector_end = @min(
            geometry.hierarchy.end,
            geometry.hierarchy.start + 1 + tree_row.depth * 2 +
                @as(u16, if (tree_row.connector == .root) 0 else 3),
        );
        if (connector_end > geometry.hierarchy.start + 1) {
            styleRange(surface, @intCast(row), .{
                .start = geometry.hierarchy.start + 1,
                .end = connector_end,
            }, .{
                .fg = Palette.muted,
                .bg = if (selected)
                    if (self.focus_area == .hierarchy) Palette.focus_bg else Palette.result_bg
                else
                    .default,
            });
        }
        if (tree_row.conflict_index != null) {
            const marker = if (treeRowResolved(self, tree_row)) "✓" else "!";
            for (geometry.hierarchy.start + 1..geometry.hierarchy.end) |col| {
                var cell = surface.readCell(@intCast(col), @intCast(row));
                if (!std.mem.eql(u8, cell.char.grapheme, marker)) continue;
                cell.style.fg = if (treeRowResolved(self, tree_row)) Palette.theirs else Palette.conflict;
                cell.default = false;
                surface.writeCell(@intCast(col), @intCast(row), cell);
                break;
            }
        }
    }

    if (self.usesProperties()) {
        try paintProperties(self, ctx.arena, surface, size);
    } else if (self.raw_view) {
        try paintUnified(self, ctx.arena, surface, size);
    } else if (self.selectedOperation()) |operation| {
        const columns = .{
            .{ geometry.base, try self.columnText(ctx.arena, operation, .base), ValueColumn.base },
            .{ geometry.ours, try self.columnText(ctx.arena, operation, .ours), ValueColumn.ours },
            .{ geometry.theirs, try self.columnText(ctx.arena, operation, .theirs), ValueColumn.theirs },
            .{ geometry.result, try self.columnText(ctx.arena, operation, .result), ValueColumn.result },
        };
        const indent = commonIndent(&.{ columns[0][1], columns[1][1], columns[2][1] });
        const viewport = body.inspector_rows.end - body.inspector_rows.start;
        var painted_end = [_]u16{body.inspector_rows.start} ** 4;
        inline for (columns, 0..) |column, index| {
            const paint_range = self.prepareColumnScroll(index, column[1], viewport, column[0], indent);
            painted_end[index] = paintColumnValue(
                surface,
                paint_range,
                body.inspector_rows.start,
                body.inspector_rows.end,
                column[1],
                indent,
                valueStyle(column[2]),
                self.column_v[index],
                self.column_h[index],
            );
        }
        if (self.focus_area == .inspector) {
            const selected_range = valueRange(geometry, self.selected_value);
            const focus_end = @max(painted_end[selected_index], body.inspector_rows.start + 1);
            var selected_style = valueStyle(self.selected_value);
            selected_style.bg = Palette.focus_bg;
            var row: u16 = body.inspector_rows.start;
            while (row < focus_end) : (row += 1) {
                styleRange(surface, row, selected_range, selected_style);
                surface.writeCell(selected_range.start, row, .{
                    .char = .{ .grapheme = "▌", .width = 1 },
                    .style = .{ .fg = Palette.accent, .bg = Palette.focus_bg },
                });
            }
        }
        self.paintColumnScrollbars(surface, geometry, body);
    }

    if (self.state.outcome == .ready) {
        writeClipped(
            surface,
            footer.complete.start,
            footer.row,
            footer.complete.end - footer.complete.start,
            "[Complete]",
        );
        var complete_style: vaxis.Style = .{ .fg = Palette.accent };
        complete_style.reverse = self.focus_area == .complete;
        styleRange(surface, footer.row, footer.complete, complete_style);
    }
    writeClipped(
        surface,
        content_start,
        body.status_row,
        content_end - content_start,
        self.state.status,
    );
    if (self.state.status.len != 0) {
        styleRange(
            surface,
            body.status_row,
            .{ .start = content_start, .end = content_end },
            .{ .fg = Palette.error_text },
        );
    }

    if (self.dialog) |kind| {
        const dialog = DialogGeometry.init(size.width, size.height, kind);
        // Styling existing cells leaves the underlying diff visible between the modal's labels.
        for (dialog.top..dialog.bottom) |row| {
            for (dialog.left..dialog.right) |col| {
                surface.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = " ", .width = 1 } });
            }
        }
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.prompt_row,
            dialog.right - dialog.left - 6,
            kind.prompt(),
        );
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.detail_row,
            dialog.right - dialog.left - 6,
            kind.detail(),
        );
        writeClipped(surface, dialog.cancel.start, dialog.buttons_row, 8, "[Cancel]");
        writeClipped(surface, dialog.confirm.start, dialog.buttons_row, @intCast(kind.confirmLabel().len), kind.confirmLabel());
        for (dialog.top..dialog.bottom) |row| {
            styleRange(surface, @intCast(row), .{ .start = dialog.left, .end = dialog.right }, .{ .bg = Palette.focus_bg });
        }
        const border_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        for (dialog.top..dialog.bottom) |row| {
            const top = row == dialog.top;
            const bottom = row == dialog.bottom - 1;
            surface.writeCell(dialog.left, @intCast(row), .{
                .char = .{ .grapheme = if (top) "┌" else if (bottom) "└" else "│", .width = 1 },
                .style = border_style,
            });
            surface.writeCell(dialog.right - 1, @intCast(row), .{
                .char = .{ .grapheme = if (top) "┐" else if (bottom) "┘" else "│", .width = 1 },
                .style = border_style,
            });
            if (top or bottom) {
                for (dialog.left + 1..dialog.right - 1) |col| {
                    surface.writeCell(@intCast(col), @intCast(row), .{
                        .char = .{ .grapheme = "─", .width = 1 },
                        .style = border_style,
                    });
                }
            }
        }
        styleRange(surface, dialog.prompt_row, .{ .start = dialog.left + 3, .end = dialog.right - 3 }, .{
            .bold = true,
            .bg = Palette.focus_bg,
        });
        var cancel_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        var confirm_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        if (self.dialog_choice == .cancel) {
            cancel_style.fg = Palette.accent;
            cancel_style.reverse = true;
        } else {
            confirm_style.fg = Palette.accent;
            confirm_style.reverse = true;
        }
        styleRange(surface, dialog.buttons_row, dialog.cancel, cancel_style);
        styleRange(surface, dialog.buttons_row, dialog.confirm, confirm_style);
    }

    if (self.editing and self.focus_area == .inspector and self.dialog != .empty) {
        const editor_row = self.editorRow(size);
        if (editor_row < body.inspector_rows.end) {
            self.editor.style = .{ .bg = Palette.focus_bg };
            const editor_size: vxfw.Size = .{
                .width = geometry.result.end - geometry.result.start -| 2,
                .height = if (self.editsPropertyCell()) 1 else body.inspector_rows.end - editor_row,
            };
            const child_surface = try result_text.draw(&self.editor, &self.editor_top, self.editorSelection(), ctx.withConstraints(
                editor_size,
                vxfw.MaxSize.fromSize(editor_size),
            ));
            if (!self.editor_changed and self.resultIsRemoval()) {
                styleRange(child_surface, 0, .{ .start = 0, .end = editor_size.width }, self.editor.style);
            }
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{
                    .col = @intCast(geometry.result.start + 2),
                    .row = @intCast(editor_row),
                },
                .surface = child_surface,
            };
            surface.children = children;
        }
    }
    return surface;
}

fn paintUnified(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, size: vxfw.Size) !void {
    const operation = self.selectedOperation() orelse return;
    const geometry = self.valueGeometry(size.width);
    const body = BodyGeometry.init(size.height);
    const base = try self.columnText(arena, operation, .base);
    const columns = .{
        .{ ValueColumn.base, base },
        .{ ValueColumn.ours, try unifiedDiff(arena, "Base", base, "Ours", try self.columnText(arena, operation, .ours)) },
        .{ ValueColumn.theirs, try unifiedDiff(arena, "Base", base, "Theirs", try self.columnText(arena, operation, .theirs)) },
        .{ ValueColumn.result, try self.columnText(arena, operation, .result) },
    };
    const viewport = body.inspector_rows.end - body.inspector_rows.start;
    var painted_end = [_]u16{body.inspector_rows.start} ** 4;
    inline for (columns, 0..) |column, index| {
        const range = valueRange(geometry, column[0]);
        const paint_range = self.prepareColumnScroll(index, column[1], viewport, range, 0);
        painted_end[index] = paintDiffColumn(
            surface,
            paint_range,
            body.inspector_rows.start,
            body.inspector_rows.end,
            column[1],
            column[0],
            self.column_v[index],
            self.column_h[index],
        );
    }
    if (self.focus_area == .inspector) {
        const selected_range = valueRange(geometry, self.selected_value);
        const selected_index: usize = @intFromEnum(self.selected_value);
        const focus_end = @max(painted_end[selected_index], body.inspector_rows.start + 1);
        var row: u16 = body.inspector_rows.start;
        while (row < focus_end) : (row += 1) {
            var selected_style = surface.readCell(selected_range.start + 2, row).style;
            selected_style.bg = Palette.focus_bg;
            styleRange(surface, row, selected_range, selected_style);
            surface.writeCell(selected_range.start, row, .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = Palette.accent, .bg = Palette.focus_bg },
            });
        }
    }
    self.paintColumnScrollbars(surface, geometry, body);
}

fn diffLineStyle(column: ValueColumn, line: []const u8) vaxis.Style {
    var style = valueStyle(column);
    if (column == .result or column == .base) return style;
    if (isUnifiedAddition(line)) {
        style.fg = Palette.theirs;
    } else if (isUnifiedDeletion(line)) {
        style.fg = Palette.ours;
    } else {
        style.fg = Palette.muted;
    }
    return style;
}

fn isUnifiedAddition(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++ ");
}

fn isUnifiedDeletion(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "--- ");
}

fn paintDiffColumn(
    surface: vxfw.Surface,
    range: Range,
    start_row: u16,
    end_row: u16,
    text: []const u8,
    column: ValueColumn,
    visual_skip: usize,
    horizontal: usize,
) u16 {
    const inner_start = range.start + 2;
    const inner_width = range.end - range.start -| 2;
    var row = start_row;
    var skip = visual_skip;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var remaining_lines = std.mem.splitScalar(u8, text, '\n');
    _ = remaining_lines.next();
    while (lines.next()) |raw_line| {
        const more = remaining_lines.next() != null;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!more and line.len == 0) break;
        const style = diffLineStyle(column, line);
        var rest = skipWrappedPrefix(skipGraphemes(line, horizontal), inner_width, &skip);
        if (skip > 0) continue;
        while (row < end_row) {
            if (rest.len == 0) {
                styleRange(surface, row, range, style);
                row += 1;
                break;
            }
            const consumed = writeClippedCount(surface, inner_start, row, inner_width, rest);
            styleRange(surface, row, range, style);
            if (consumed == 0) break;
            rest = rest[consumed..];
            row += 1;
            if (rest.len == 0) break;
        }
        if (row >= end_row) break;
    }
    return row;
}

fn paintProperties(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, size: vxfw.Size) !void {
    const model = try self.propertyModel(arena);
    self.ensurePropertyVisible(size, model.rows.len);
    const geometry = self.valueGeometry(size.width);
    const body = BodyGeometry.init(size.height);
    for (self.property_top..model.rows.len) |index| {
        const row: u16 = @intCast(body.inspector_rows.start + index - self.property_top);
        if (row >= body.inspector_rows.end) break;
        const selected = self.focus_area == .inspector and self.property_row == index;
        writeClipped(surface, geometry.inspector.start, row, geometry.base.start - geometry.inspector.start - 1, model.rows[index].label);
        if (selected) styleRange(surface, row, .{ .start = geometry.inspector.start, .end = geometry.base.start }, .{ .bg = Palette.focus_bg, .bold = true });
        inline for (.{ ValueColumn.base, ValueColumn.ours, ValueColumn.theirs, ValueColumn.result }, 0..) |column, i| {
            const range = valueRange(geometry, column);
            const text = try model.text(arena, index, i);
            var style = valueStyle(column);
            if (selected and self.selected_value == column) style.bg = Palette.focus_bg;
            if (model.rows[index].changed) style.bold = true;
            writeClipped(surface, range.start + 2, row, range.end - range.start -| 2, skipGraphemes(text, self.column_h[i]));
            styleRange(surface, row, range, style);
            if (selected and self.selected_value == column) {
                surface.writeCell(range.start, row, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = Palette.accent, .bg = Palette.focus_bg } });
            }
        }
    }
    if (self.shouldPaintFloatingScrollbar()) {
        paintScrollbar(
            surface,
            geometry.result.end -| 1,
            body.inspector_rows.start,
            body.inspector_rows.end,
            self.property_top,
            model.rows.len,
        );
    }
}

fn submitCustom(
    userdata: ?*anyopaque,
    ctx: *vxfw.EventContext,
    value: []const u8,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata.?));
    if (!self.editing) {
        // A queued Enter can still target the TextField after apply closed it.
        if (self.focus_area == .complete) return self.activate(ctx, self.eventSize());
        return;
    }
    const input = std.mem.trim(u8, value, "\r\n");
    const started_empty = if (self.editor_start_resolution) |resolution| switch (resolution) {
        .custom => |start_value| start_value.len == 0,
        else => false,
    } else false;
    if (!self.editor_changed and self.resultIsRemoval()) return self.applyPendingResult(ctx, self.eventSize());
    if (input.len == 0 and !started_empty) return self.openDialog(ctx, .empty);
    if (self.editor_property != null) return self.submitProperty(ctx, input);
    const payload = try self.customResultInput(input);
    if (self.editor_changed or payload.len == 0) {
        try self.state.handle(.{ .edit_result = payload });
    } else {
        self.state.pending = self.editor_start_resolution;
    }
    try self.applyPendingResult(ctx, self.eventSize());
    if (self.state.status.len != 0) {
        self.editor.clearRetainingCapacity();
        try self.editor.insertSliceAtCursor(value);
    }
}

fn markEditorChanged(
    userdata: ?*anyopaque,
    _: *vxfw.EventContext,
    value: []const u8,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata.?));
    self.editor_changed = true;
    if (value.len == 0 and !self.editsPropertyCell()) {
        try self.state.handle(.reopen_result);
        self.editor_reopened = true;
    }
}

fn hasParsedDocuments(model: inspector.Model) bool {
    for (model.documents) |document| {
        if (document != null) return true;
    }
    return false;
}

fn selectEditableProperty(property_row: *usize, model: inspector.Model) bool {
    if (model.editable(property_row.*)) return true;
    for (model.rows, 0..) |_, i| {
        if (model.editable(i)) {
            property_row.* = i;
            return true;
        }
    }
    return false;
}

fn dictionaryCustom(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    input: []const u8,
) ![]const u8 {
    const template = operation.values.ours orelse operation.values.theirs orelse operation.values.base orelse return input;
    const node = template.node orelse return input;
    if (node.* != .map) return input;
    // Keep the sequence-item indent. Trimming it leaves `value:` nested under `key:`.
    const trimmed = std.mem.trim(u8, input, "\r\n");
    const content = std.mem.trimStart(u8, trimmed, " ");
    if (std.mem.startsWith(u8, content, "- ")) {
        return stripSequenceItemDash(arena, trimmed);
    }
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null or std.mem.startsWith(u8, trimmed, "{")) {
        return trimmed;
    }
    return dictionaryValueCustom(arena, plan, node, trimmed);
}

fn dictionaryValueCustom(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    node: *const core.model.Node,
    input: []const u8,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (node.map, 0..) |entry, i| {
        if (i != 0) try output.append(arena, '\n');
        try output.appendSlice(arena, entry.key);
        try output.appendSlice(arena, ": ");
        const field = if (std.mem.eql(u8, entry.key, "value") or std.mem.eql(u8, entry.key, "second"))
            input
        else
            fieldSourceBytes(plan, entry.value) orelse return input;
        try output.appendSlice(arena, field);
    }
    return output.toOwnedSlice(arena);
}

fn fieldSourceBytes(plan: *const core.merge.MergePlan, node: *const core.model.Node) ?[]const u8 {
    inline for (.{ core.merge.Side.ours, .theirs, .base }) |side| {
        if (plan.file(side).nodeBytes(node)) |bytes| return bytes;
    }
    return switch (node.*) {
        .scalar => |text| text,
        else => null,
    };
}

fn stripSequenceItemDash(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const first_raw = lines.next() orelse return input;
    const first_line = std.mem.trimEnd(u8, first_raw, "\r");
    const first_indent = lineIndent(first_line);
    const rest = first_line[first_indent..];
    if (!std.mem.startsWith(u8, rest, "- ")) return input;
    var body_indent: ?usize = null;
    var preview = lines;
    while (preview.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " ").len == 0) continue;
        const indent = lineIndent(line);
        body_indent = if (body_indent) |current| @min(current, indent) else indent;
    }
    const strip = body_indent orelse first_indent + 2;
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(arena, rest[2..]);
    lines = std.mem.splitScalar(u8, input, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " ").len == 0) continue;
        try output.append(arena, '\n');
        const indent = lineIndent(line);
        if (indent >= strip) {
            try output.appendSlice(arena, line[strip..]);
        } else {
            try output.appendSlice(arena, std.mem.trimStart(u8, line, " "));
        }
    }
    return output.toOwnedSlice(arena);
}

fn extractOverrideValue(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \r\n");
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") == null and !std.mem.startsWith(u8, std.mem.trimStart(u8, trimmed, " "), "- ")) {
        return trimmed;
    }
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const content = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, content, "value:")) {
            found = std.mem.trim(u8, content["value:".len..], " ");
        }
    }
    return found orelse trimmed;
}

fn isPlaceholderValue(text: []const u8) bool {
    return std.mem.eql(u8, text, "<removed>") or std.mem.eql(u8, text, "<empty>");
}

fn lineIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn skipLineIndent(line: []const u8, indent: usize) []const u8 {
    var count: usize = 0;
    while (count < indent and count < line.len and line[count] == ' ') count += 1;
    return line[count..];
}

fn commonIndent(texts: []const []const u8) usize {
    var min_indent: usize = std.math.maxInt(usize);
    var found = false;
    for (texts) |text| {
        if (isPlaceholderValue(text) or text.len == 0) continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const content = std.mem.trimEnd(u8, line, "\r");
            if (content.len == 0) continue;
            min_indent = @min(min_indent, lineIndent(content));
            found = true;
        }
    }
    return if (found) min_indent else 0;
}

fn paintColumnValue(
    surface: vxfw.Surface,
    range: Range,
    start_row: u16,
    end_row: u16,
    text: []const u8,
    indent: usize,
    style: vaxis.Style,
    visual_skip: usize,
    horizontal: usize,
) u16 {
    const inner_start = range.start + 2;
    const inner_width = range.end - range.start -| 2;
    var row = start_row;
    var skip = visual_skip;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var remaining_lines = std.mem.splitScalar(u8, text, '\n');
    _ = remaining_lines.next();
    while (lines.next()) |raw_line| {
        const more = remaining_lines.next() != null;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!more and line.len == 0) break;
        const visible = skipGraphemes(visiblePaintLine(text, line, indent), horizontal);
        var rest = skipWrappedPrefix(visible, inner_width, &skip);
        if (skip > 0) continue;
        while (row < end_row) {
            if (rest.len == 0) {
                styleRange(surface, row, range, style);
                row += 1;
                break;
            }
            const consumed = writeClippedCount(surface, inner_start, row, inner_width, rest);
            styleRange(surface, row, range, style);
            if (consumed == 0) break;
            rest = rest[consumed..];
            row += 1;
            if (rest.len == 0) break;
        }
        if (row >= end_row) break;
    }
    return row;
}

fn unifiedDiff(
    arena: std.mem.Allocator,
    left_name: []const u8,
    left: []const u8,
    right_name: []const u8,
    right: []const u8,
) ![]const u8 {
    const a = try splitDiffLines(arena, left);
    const b = try splitDiffLines(arena, right);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "--- ");
    try out.appendSlice(arena, left_name);
    try out.append(arena, '\n');
    try out.appendSlice(arena, "+++ ");
    try out.appendSlice(arena, right_name);
    try out.append(arena, '\n');
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "@@ -1,{d} +1,{d} @@\n", .{ a.len, b.len }));
    const width = b.len + 1;
    const dp = try arena.alloc(u32, (a.len + 1) * width);
    @memset(dp, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            dp[i * width + j] = if (std.mem.eql(u8, a[i], b[j]))
                dp[(i + 1) * width + (j + 1)] + 1
            else
                @max(dp[(i + 1) * width + j], dp[i * width + (j + 1)]);
        }
    }
    i = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.mem.eql(u8, a[i], b[j])) {
            try out.appendSlice(arena, " ");
            try out.appendSlice(arena, a[i]);
            try out.append(arena, '\n');
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * width + j] >= dp[i * width + (j + 1)]) {
            try out.appendSlice(arena, "-");
            try out.appendSlice(arena, a[i]);
            try out.append(arena, '\n');
            i += 1;
        } else {
            try out.appendSlice(arena, "+");
            try out.appendSlice(arena, b[j]);
            try out.append(arena, '\n');
            j += 1;
        }
    }
    while (i < a.len) : (i += 1) {
        try out.appendSlice(arena, "-");
        try out.appendSlice(arena, a[i]);
        try out.append(arena, '\n');
    }
    while (j < b.len) : (j += 1) {
        try out.appendSlice(arena, "+");
        try out.appendSlice(arena, b[j]);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn splitDiffLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(arena);
}

fn writeClipped(
    surface: vxfw.Surface,
    start: u16,
    row: u16,
    width: u16,
    text: []const u8,
) void {
    _ = writeClippedCount(surface, start, row, width, text);
}

fn writeClippedCount(
    surface: vxfw.Surface,
    start: u16,
    row: u16,
    width: u16,
    text: []const u8,
) usize {
    var col: usize = start;
    const end: usize = @as(usize, start) + width;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    var consumed: usize = 0;
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width = vaxis.gwidth.gwidth(bytes, .unicode);
        if (cell_width == 0) {
            consumed = grapheme.start + grapheme.len;
            continue;
        }
        const next_col = col + cell_width;
        if (next_col > end) break;
        surface.writeCell(@intCast(col), row, .{ .char = .{
            .grapheme = bytes,
            .width = @intCast(cell_width),
        } });
        col = next_col;
        consumed = grapheme.start + grapheme.len;
    }
    return consumed;
}

fn styleRange(surface: vxfw.Surface, row: u16, range: Range, style: vaxis.Style) void {
    for (range.start..range.end) |col| {
        var cell = surface.readCell(col, row);
        cell.style = style;
        cell.default = false;
        surface.writeCell(@intCast(col), row, cell);
    }
}

fn inRange(col: u16, range: Range) bool {
    return col >= range.start and col < range.end;
}

fn captureEvent(
    userdata: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata));
    if (try self.handlePaste(ctx, event)) return;
    if (!isUsableSize(self.eventSize())) switch (event) {
        .key_press, .mouse => ctx.consumeEvent(),
        else => {},
    };
    if (ctx.consume_event) return;
    if (self.dialog == .empty) switch (event) {
        .key_press, .mouse => return self.handleDialog(ctx, event, self.eventSize()),
        else => {},
    };
    switch (event) {
        .key_press => |key| if (self.editing) {
            _ = try self.handleEditorKey(ctx, key);
        },
        .mouse => |mouse| if (self.editing) {
            try self.handleMouseWhileEditing(ctx, mouse, self.eventSize());
        },
        else => {},
    }
}

fn handleEvent(
    userdata: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata));
    if (ctx.phase == .at_target and try self.handlePaste(ctx, event)) return;
    const size = self.eventSize();
    switch (event) {
        .tick => return self.expireScrollbar(ctx),
        .winsize => return ctx.consumeAndRedraw(),
        .key_press, .mouse => {
            if (!isUsableSize(size)) return ctx.consumeEvent();
            if (size.width != self.last_size.width or size.height != self.last_size.height) {
                self.ensureSelectionVisible(size);
            } else {
                self.clampVerticalOffset(size);
            }
        },
        else => {},
    }
    if (self.dialog != null) return self.handleDialog(ctx, event, size);
    if (self.editing) {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    return self.leaveResultForHierarchy(ctx);
                }
                if (try self.handleEditorKey(ctx, key)) return;
            },
            .mouse => |mouse| {
                // Queued input can target the previous surface before the editor is drawn.
                if (ctx.phase == .at_target) return self.handleMouseWhileEditing(ctx, mouse, size);
                if (self.handleHierarchyWheel(ctx, mouse, size)) return;
            },
            else => {},
        }
        if (ctx.phase == .at_target) return self.editor.handleEvent(ctx, event);
        return;
    }

    switch (event) {
        .mouse => |mouse| try self.handleMouse(ctx, mouse, size),
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{})) {
                return switch (self.focus_area) {
                    .hierarchy => try self.openDialog(ctx, .quit),
                    .inspector, .complete => self.focusHierarchy(ctx),
                };
            }
            if (self.focus_area == .inspector and key.matches(vaxis.Key.left, .{ .shift = true }))
                return self.scrollLeft(ctx);
            if (self.focus_area == .inspector and key.matches(vaxis.Key.right, .{ .shift = true }))
                return self.scrollRight(ctx, size);
            if (key.matches(vaxis.Key.left, .{})) return self.moveLeft(ctx);
            if (key.matches(vaxis.Key.right, .{})) return self.moveRight(ctx);
            if (key.matches(vaxis.Key.up, .{})) return self.moveUp(ctx, size);
            if (key.matches(vaxis.Key.down, .{})) return self.moveDown(ctx, size);
            if (key.matches(vaxis.Key.enter, .{})) return self.activate(ctx, size);
            if (key.matches('r', .{ .shift = true })) {
                self.raw_view = !self.raw_view;
                return ctx.consumeAndRedraw();
            }
            if (self.canCombine() and key.matches('t', .{ .shift = true }))
                return self.toggleCombine(ctx);
            if (self.focus_area == .inspector and self.selected_value == .result) {
                if (key.matches('j', .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{ .shift = true })) {
                    try self.beginResultEdit(ctx, self.selectedResultInput());
                    _ = try self.handleEditorKey(ctx, key);
                } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{})) {
                    if (self.usesProperties()) {
                        try self.beginResultEdit(ctx, self.selectedResultInput());
                        if (self.editing) return self.editor.handleEvent(ctx, event);
                        return;
                    }
                    self.horizontal_offset = 0;
                    try self.dispatch(ctx, .reopen_result, size);
                } else if (key.text != null and key.text.?.len != 0) {
                    try self.beginTypedEdit(ctx, key);
                }
            }
        },
        else => {},
    }
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    state: *merge_ui_state.State,
    path: []const u8,
    partial: []const u8,
) !void {
    var tty_buffer: [4096]u8 = undefined;
    var session = try Session.init(io, allocator, env_map, &tty_buffer);
    defer session.deinit();
    try session.present(allocator, state, path, partial);
}

/// One terminal session covers every remaining content conflict in a merge.
pub const Session = struct {
    app: vxfw.App,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        buffer: []u8,
    ) !Session {
        return .{ .app = try vxfw.App.init(io, allocator, env_map, buffer) };
    }

    pub fn deinit(self: *Session) void {
        self.app.deinit();
    }

    pub fn present(
        self: *Session,
        allocator: std.mem.Allocator,
        state: *merge_ui_state.State,
        path: []const u8,
        partial: []const u8,
    ) !void {
        const tree = try merge_tree.buildForState(allocator, partial, state);
        try state.handle(.{ .select_conflict = 0 });
        var view = View.init(allocator, state, path, tree);
        defer view.deinit();
        view.live_screen = &self.app.vx.screen;
        try self.app.run(view.widget(), .{});
        // App.run pushes Kitty keyboard on every file. vaxis deinit pops once.
        try self.app.vx.resetState(self.app.tty.writer());
    }
};

fn screenPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n  m_Drag: 0\n",
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 12\n  m_Drag: 2\n",
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 8\n  m_Drag: 3\n",
    );
}

test "merge TUI: collection toggle retains both orders until Enter applies the focused choice" {
    for ([_]ValueColumn{ .ours, .theirs }) |column| for ([_][]const u8{ "T", "\x1b[116;2u" }) |input| {
        var memory = std.heap.ArenaAllocator.init(testing.allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        var built = try core.merge.build(arena, "--- !u!114 &1\nMonoBehaviour:\n  items: [A]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Ours]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Theirs]\n");
        var state = try merge_ui_state.State.init(arena, &built.plan);
        var view = try viewForTest(arena, &state, "Array.prefab", built.partial);
        defer view.deinit();
        const initial = try drawForTest(arena, view.widget(), 140, 20);
        try testing.expect(std.mem.indexOf(u8, try rowText(arena, initial, BodyGeometry.init(20).inspector_heading_row), "⇧T One side") != null);
        var ctx = eventContext(arena);
        var parser: vaxis.Parser = .{};
        const key = (try parser.parse(input, arena)).event.?.key_press;
        // Mode shortcuts must work from the hierarchy without moving focus or choosing a Result.
        try view.widget().handleEvent(&ctx, .{ .key_press = key });
        try testing.expectEqual(FocusArea.hierarchy, view.focus_area);
        // Terminal modifier reports and focus changes must not undo an explicit toggle.
        try view.widget().handleEvent(&ctx, .{ .key_release = .{ .codepoint = vaxis.Key.left_shift } });
        try view.widget().handleEvent(&ctx, .focus_out);
        for ([_]u16{ 80, 100, 140 }) |width| {
            const surface = try drawForTest(arena, view.widget(), width, 20);
            const heading = try rowText(arena, surface, BodyGeometry.init(20).inspector_heading_row);
            const labels = try rowText(arena, surface, BodyGeometry.init(20).inspector_labels_row);
            try testing.expect(std.mem.indexOf(u8, heading, "⇧T Both sides") != null);
            try testing.expect(std.mem.indexOf(u8, heading, "⇧R Raw") != null);
            try testing.expect(std.mem.indexOf(u8, heading, "MonoBehaviour › Items") != null);
            try testing.expectEqualStrings("1 unresolved", try cellsText(arena, surface, BodyGeometry.init(20).header_row, width - horizontal_padding - 12, 12));
            try testing.expect(std.mem.indexOf(u8, labels, "Ours + Theirs") != null);
            try testing.expect(std.mem.indexOf(u8, labels, "Theirs + Ours") != null);
            try testing.expectEqualStrings("", std.mem.trim(u8, try rowText(arena, surface, BodyGeometry.init(20).status_row), " "));
        }
        // Switching the available choices must not create or apply a Result preview.
        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expect(state.pending == null);
        try pressKeyForTest(&view, &ctx, vaxis.Key.right);
        if (column == .theirs) try pressKeyForTest(&view, &ctx, vaxis.Key.right);
        try testing.expectEqual(column, view.selected_value);
        try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
        try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
        try testing.expect(std.mem.indexOf(u8, try core.merge.finish(arena, &built.plan), if (column == .ours) "[A, Ours, Theirs]" else "[A, Theirs, Ours]") != null);
        const surface = try drawForTest(arena, view.widget(), 140, 20);
        try testing.expectEqualStrings(if (column == .ours) "[Ours, Theirs]" else "[Theirs, Ours]", try cellsText(arena, surface, BodyGeometry.init(20).inspector_rows.start, Geometry.init(140).result.start + 2, 14));
    };
}

test "merge TUI: toggling twice restores the original side without moving columns" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var built = try core.merge.build(arena, "--- !u!114 &1\nMonoBehaviour:\n  items: [A]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Ours]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Theirs]\n");
    var state = try merge_ui_state.State.init(arena, &built.plan);
    var view = try viewForTest(arena, &state, "Array.prefab", built.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    const before = view.valueGeometry(80);
    for (0..2) |_| try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 't', .mods = .{ .shift = true } } });
    const surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualDeep(before, view.valueGeometry(80));
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, BodyGeometry.init(10).inspector_heading_row), "⇧T One side") != null);
    try testing.expect(std.mem.indexOf(u8, try surfaceText(arena, surface), "Ours + Theirs") == null);
    try testing.expect(state.pending == null);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(std.mem.indexOf(u8, try core.merge.finish(arena, &built.plan), "[A, Ours]") != null);
}

fn deleteEditPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n  m_After: keep\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_After: keep\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n  m_After: keep\n",
    );
}

fn prefabOrderPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n";
    const suffix =
        "  m_SourcePrefab: {fileID: 100100000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n";
    const name =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Name\n" ++
        "      value: Root\n" ++
        "      objectReference: {fileID: 0}\n";
    const tag =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_TagString\n" ++
        "      value: Untagged\n" ++
        "      objectReference: {fileID: 0}\n";
    const layer =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Layer\n" ++
        "      value: 0\n" ++
        "      objectReference: {fileID: 0}\n";
    return core.merge.build(
        arena,
        prefix ++ name ++ tag ++ layer ++ suffix,
        prefix ++ tag ++ name ++ layer ++ suffix,
        prefix ++ name ++ layer ++ tag ++ suffix,
    );
}

fn prefabOverrideSpeedPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n" ++
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Name\n" ++
        "      value: Enemy\n" ++
        "    - target: {fileID: 40, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: items.Array.data[0].speed\n" ++
        "      value: ";
    const suffix =
        "\n      objectReference: {fileID: 0}\n" ++
        "  m_SourcePrefab: {fileID: 100100000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n";
    return core.merge.build(arena, prefix ++ "1" ++ suffix, prefix ++ "2" ++ suffix, prefix ++ "3" ++ suffix);
}

fn dictionaryGoblinPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    const prefix = "--- !u!114 &2\nMonoBehaviour:\n  m_Stats:\n";
    return core.merge.build(
        arena,
        prefix ++ "  - key: Goblin\n    value: 1\n",
        prefix ++ "  - key: Goblin\n    value: 2\n",
        prefix ++ "  - key: Goblin\n    value: 3\n",
    );
}

fn dictionaryUnionPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    return core.merge.build(
        arena,
        prefix ++ "  - key: Goblin\n    value: 1\n",
        prefix ++ "  - key: Goblin\n    value: 2\n  - key: Dragon\n    value: 9\n",
        prefix ++ "  - key: Goblin\n    value: 3\n  - key: Slime\n    value: 2\n",
    );
}

const game_object_delete_edit_base =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n";
const game_object_delete_edit_ours =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
const game_object_delete_edit_theirs =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Edited Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n";

fn gameObjectDeleteEditPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(arena, game_object_delete_edit_base, game_object_delete_edit_ours, game_object_delete_edit_theirs);
}

const reparent_cycle_base =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 40}\n  - {fileID: 41}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 40}\n" ++
    "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n";
const reparent_cycle_ours =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 41}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 41}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children:\n  - {fileID: 40}\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 40}\n" ++
    "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n";
const reparent_cycle_theirs =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 41}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 42}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children:\n  - {fileID: 40}\n  m_Father: {fileID: 40}\n" ++
    "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n";

fn reparentCyclePlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(arena, reparent_cycle_base, reparent_cycle_ours, reparent_cycle_theirs);
}

fn componentDeletePlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  m_Name: Root\n--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n",
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n",
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  m_Name: Root\n--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n",
    );
}

fn drawForTest(
    arena: std.mem.Allocator,
    widget: vxfw.Widget,
    width: u16,
    height: u16,
) !vxfw.Surface {
    vxfw.DrawContext.init(.unicode);
    return widget.draw(.{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = height },
        .cell_size = .{ .width = 10, .height = 20 },
    });
}

fn viewForTest(
    arena: std.mem.Allocator,
    state: *merge_ui_state.State,
    path: []const u8,
    partial: []const u8,
) !View {
    const tree = try merge_tree.buildForState(arena, partial, state);
    return View.init(arena, state, path, tree);
}

fn rowText(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..surface.size.width) |col| {
        try out.appendSlice(arena, surface.readCell(col, row).char.grapheme);
    }
    return out.toOwnedSlice(arena);
}

fn cellsText(
    arena: std.mem.Allocator,
    surface: vxfw.Surface,
    row: u16,
    start: u16,
    count: u16,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (start..start + count) |col| {
        try out.appendSlice(arena, surface.readCell(col, row).char.grapheme);
    }
    return out.toOwnedSlice(arena);
}

fn fgOfText(surface: vxfw.Surface, range: Range, row: u16, needle: []const u8) ?vaxis.Color {
    var col = range.start;
    while (col + needle.len <= range.end) : (col += 1) {
        var match = true;
        for (needle, 0..) |byte, offset| {
            const cell = surface.readCell(col + @as(u16, @intCast(offset)), row);
            if (cell.char.grapheme.len != 1 or cell.char.grapheme[0] != byte) {
                match = false;
                break;
            }
        }
        if (match) return surface.readCell(col, row).style.fg;
    }
    return null;
}

fn firstContentFg(surface: vxfw.Surface, range: Range, row: u16) vaxis.Color {
    return surface.readCell(range.start + 2, row).style.fg;
}

fn lineStartFg(
    surface: vxfw.Surface,
    range: Range,
    start_row: u16,
    end_row: u16,
    marker: []const u8,
) ?vaxis.Color {
    var row = start_row;
    while (row < end_row) : (row += 1) {
        const cell = surface.readCell(range.start + 2, row);
        if (!std.mem.eql(u8, cell.char.grapheme, marker)) continue;
        const next = surface.readCell(range.start + 3, row).char.grapheme;
        if (std.mem.eql(u8, next, marker)) continue;
        return cell.style.fg;
    }
    return null;
}

fn rangeText(
    arena: std.mem.Allocator,
    surface: vxfw.Surface,
    range: Range,
    start_row: u16,
    end_row: u16,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (start_row..end_row) |row| {
        const line = std.mem.trim(u8, try cellsText(arena, surface, @intCast(row), range.start, range.end - range.start), " ");
        if (line.len == 0) continue;
        if (out.items.len != 0) try out.append(arena, '\n');
        try out.appendSlice(arena, line);
    }
    return out.toOwnedSlice(arena);
}

fn surfaceText(arena: std.mem.Allocator, surface: vxfw.Surface) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..surface.size.height) |row| {
        try out.appendSlice(arena, try rowText(arena, surface, @intCast(row)));
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn isScrollbarGlyph(grapheme: []const u8) bool {
    return std.mem.eql(u8, grapheme, "▎") or std.mem.eql(u8, grapheme, "█") or std.mem.eql(u8, grapheme, "│");
}

fn scrollbarThumbCell(surface: vxfw.Surface, col: u16, start_row: u16, end_row: u16) ?vaxis.Cell {
    var row = start_row;
    while (row < end_row) : (row += 1) {
        const cell = surface.readCell(col, row);
        if (vaxis.Color.eql(cell.style.bg, Palette.scrollbar)) return cell;
    }
    return null;
}

fn hasScrollbarThumb(surface: vxfw.Surface, col: u16, start_row: u16, end_row: u16) bool {
    return scrollbarThumbCell(surface, col, start_row, end_row) != null;
}

fn eventContext(arena: std.mem.Allocator) vxfw.EventContext {
    return .{ .io = testing.io, .alloc = arena, .cmds = .empty };
}

fn pressKeyForTest(view: *View, ctx: *vxfw.EventContext, codepoint: u21) !void {
    try view.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = codepoint } });
}

fn focusResultForTest(view: *View, ctx: *vxfw.EventContext) !void {
    try pressKeyForTest(view, ctx, vaxis.Key.right);
    try pressKeyForTest(view, ctx, vaxis.Key.right);
    try pressKeyForTest(view, ctx, vaxis.Key.right);
}

fn beginEditingForTest(view: *View, ctx: *vxfw.EventContext) !void {
    try focusResultForTest(view, ctx);
    // Editor tests need a stable setup that does not assign an input event to the behavior under test.
    try view.beginResultEdit(ctx, view.selectedResultInput());
}

fn findFocusedPath(
    arena: std.mem.Allocator,
    surface: vxfw.Surface,
    focused: vxfw.Widget,
    path: *std.ArrayList(vxfw.Widget),
) !bool {
    try path.append(arena, surface.widget);
    if (surface.widget.eql(focused)) return true;
    for (surface.children) |child| {
        if (try findFocusedPath(arena, child.surface, focused, path)) return true;
    }
    _ = path.pop();
    return false;
}

fn routeFocusedEventForTest(
    arena: std.mem.Allocator,
    surface: vxfw.Surface,
    focused: vxfw.Widget,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) !void {
    var path: std.ArrayList(vxfw.Widget) = .empty;
    if (!try findFocusedPath(arena, surface, focused, &path)) return error.FocusPathEmpty;

    ctx.consume_event = false;
    ctx.phase = .capturing;
    for (path.items) |widget| {
        try widget.captureEvent(ctx, event);
        if (ctx.consume_event) return;
    }
    ctx.phase = .at_target;
    try path.getLast().handleEvent(ctx, event);
    if (ctx.consume_event) return;
    ctx.phase = .bubbling;
    var index = path.items.len - 1;
    while (index > 0) {
        index -= 1;
        try path.items[index].handleEvent(ctx, event);
        if (ctx.consume_event) return;
    }
}

test "merge TUI: Escape opens a non-writing quit dialog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.buildForState(arena, fixture.partial, &state);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);

    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    try testing.expect(view.dialog == .quit);
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Quit before completion?") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "PrefabLens will not write this result.") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "[Cancel]") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "[Quit]") != null);
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);

    // Cancel is the safe default. Enter must keep the merge open and unchanged.
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);
}

test "merge TUI: y confirms and n cancels the quit dialog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel_fixture = try screenPlan(arena);
    var cancel_state = try merge_ui_state.State.init(arena, &cancel_fixture.plan);
    var cancel_view = try viewForTest(arena, &cancel_state, "A.prefab", cancel_fixture.partial);
    defer cancel_view.deinit();
    _ = try drawForTest(arena, cancel_view.widget(), 100, 20);
    var cancel_ctx = eventContext(arena);

    try pressKeyForTest(&cancel_view, &cancel_ctx, vaxis.Key.escape);
    try pressKeyForTest(&cancel_view, &cancel_ctx, 'n');
    try testing.expect(cancel_view.dialog != .quit);
    try testing.expectEqual(merge_ui_state.Outcome.active, cancel_state.outcome);
    try testing.expect(!cancel_ctx.quit);

    var quit_fixture = try screenPlan(arena);
    var quit_state = try merge_ui_state.State.init(arena, &quit_fixture.plan);
    var quit_view = try viewForTest(arena, &quit_state, "A.prefab", quit_fixture.partial);
    defer quit_view.deinit();
    _ = try drawForTest(arena, quit_view.widget(), 100, 20);
    var quit_ctx = eventContext(arena);

    try pressKeyForTest(&quit_view, &quit_ctx, vaxis.Key.escape);
    try pressKeyForTest(&quit_view, &quit_ctx, 'y');
    try testing.expectEqual(merge_ui_state.Outcome.aborted, quit_state.outcome);
    try testing.expect(quit_ctx.quit);
}

test "merge TUI: an outside click applies Result input before focus moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const body = BodyGeometry.init(20);
    try beginEditingForTest(&view, &ctx);
    var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '1', .text = "100" } },
    );
    focused_surface = try drawForTest(arena, view.widget(), 100, 20);

    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .mouse = .{
            .col = @intCast(Geometry.init(100).ours.start),
            .row = @intCast(body.inspector_rows.start),
            .button = .left,
            .mods = .{},
            .type = .press,
        } },
    );

    // The click must not discard valid Result input before it changes focus.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    switch (fixture.plan.operations[state.conflict_indices[0]].resolution) {
        .custom => |value| try testing.expectEqualStrings("100", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(state.pending.? == .take and state.pending.?.take == .ours);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .ours);
    try testing.expect(!view.editing);
}

test "merge TUI: an outside click leaves an unchanged Result before focus moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const body = BodyGeometry.init(20);
    try beginEditingForTest(&view, &ctx);
    const focused_surface = try drawForTest(arena, view.widget(), 100, 20);

    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .mouse = .{
            .col = @intCast(Geometry.init(100).ours.start),
            .row = @intCast(body.inspector_rows.start),
            .button = .left,
            .mods = .{},
            .type = .press,
        } },
    );

    // Opening Result alone must not turn a later focus change into an apply attempt.
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expectEqualStrings("", state.status);
    try testing.expect(state.pending.? == .take and state.pending.?.take == .ours);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .ours);
    try testing.expect(!view.editing);
}

test "merge TUI: a mouse click selects Ours without applying it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // A click can inspect a side without moving to the next conflict.
    try testing.expect(state.pending.? == .take and state.pending.?.take == .ours);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
}

test "merge TUI: TextField applies an arbitrary YAML value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // The real TextField must preserve short-lived key text in the applied resolution.
    try beginEditingForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '1', .text = "1.25" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    switch (fixture.plan.operations[state.conflict_indices[0]].resolution) {
        .custom => |value| try testing.expectEqualStrings("1.25", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!view.editing);
    try testing.expect(!ctx.quit);
}

test "merge TUI: Result Enter edits an existing value without replacing it" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try state.handle(.choose_ours);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(view.editing);

    // Cursor movement must edit the chosen value without applying it or replacing the other digit.
    for ([_]vxfw.Event{
        .{ .key_press = .{ .codepoint = vaxis.Key.left } },
        .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
        .{ .key_press = .{ .codepoint = '9', .text = "9" } },
    }) |event| {
        const surface = try drawForTest(arena, view.widget(), 100, 20);
        try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, event);
    }
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("92", fixture.plan.operations[state.conflict_indices[0]].resolution.custom);
}

test "merge TUI: bracketed YAML paste preserves lines until explicit apply" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  items: ";
    var fixture = try core.merge.build(arena, prefix ++ "[A]\n", prefix ++ "[A, Ours]\n", prefix ++ "[A, Theirs]\n");
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "Array.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 140, 20);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);

    // Terminal paste sends ordinary key events between markers, including Enter for CR.
    for ([_]vxfw.Event{
        .paste_start,
        .{ .key_press = .{ .codepoint = ' ', .text = "  - One" } },
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
        .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } },
        .{ .key_press = .{ .codepoint = ' ', .text = "  - Two" } },
        .paste_end,
    }) |event| {
        ctx.consume_event = false;
        try view.widget().handleEvent(&ctx, event);
    }
    try testing.expect(view.editing);
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqualStrings("  - One\n  - Two", try view.editor.buf.dupe());
    const surface = try drawForTest(arena, view.widget(), 140, 20);
    try testing.expect(std.mem.startsWith(u8, try rowText(arena, surface.children[0].surface, 1), "  - Two"));
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings(prefix ++ "[A, One, Two]\n", try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: a copied scalar line applies without its terminal newline" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try focusResultForTest(&view, &ctx);
    // Copying a value line commonly includes its final line ending, which is outside the YAML value span.
    try view.widget().handleEvent(&ctx, .{ .paste = try arena.dupe(u8, "42\r\n") });
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqualStrings("42", fixture.plan.operations[state.conflict_indices[0]].resolution.custom);
}

test "merge TUI: live screen gates queued shrink input before redraw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var edit_fixture = try screenPlan(arena);
    var edit_state = try merge_ui_state.State.init(arena, &edit_fixture.plan);
    const edit_operation_index = edit_state.conflict_indices[0];
    var edit_view = try viewForTest(arena, &edit_state, "A.prefab", edit_fixture.partial);
    defer edit_view.deinit();
    var edit_screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    edit_view.live_screen = &edit_screen;
    _ = try drawForTest(arena, edit_view.widget(), 80, 10);
    var edit_ctx = eventContext(arena);
    try beginEditingForTest(&edit_view, &edit_ctx);
    const focused_surface = try drawForTest(arena, edit_view.widget(), 80, 10);

    // App updates this real Screen during queue drain, before it draws the small surface.
    edit_screen.width = 79;
    edit_screen.height = 9;
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        edit_view.editor.widget(),
        &edit_ctx,
        .{ .key_press = .{ .codepoint = '9', .text = "9" } },
    );

    edit_screen.width = 80;
    edit_screen.height = 10;
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        edit_view.editor.widget(),
        &edit_ctx,
        .{ .key_press = .{ .codepoint = '7', .text = "7" } },
    );
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        edit_view.editor.widget(),
        &edit_ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
    );
    switch (edit_fixture.plan.operations[edit_operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("7", value),
        else => return error.TestUnexpectedResult,
    }

    var action_fixture = try screenPlan(arena);
    var action_state = try merge_ui_state.State.init(arena, &action_fixture.plan);
    var action_view = try viewForTest(arena, &action_state, "A.prefab", action_fixture.partial);
    defer action_view.deinit();
    var action_screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    action_view.live_screen = &action_screen;
    _ = try drawForTest(arena, action_view.widget(), 80, 10);
    var action_ctx = eventContext(arena);
    action_screen.width = 79;
    action_screen.height = 9;

    const blocked_events = [_]vxfw.Event{
        .{ .key_press = .{ .codepoint = vaxis.Key.right } },
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
        .{ .mouse = .{
            .col = 0,
            .row = 3,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } },
    };
    for (blocked_events) |event| {
        action_ctx.consume_event = false;
        try action_view.widget().handleEvent(&action_ctx, event);
    }
    try testing.expectEqual(@as(?core.merge.Resolution, null), action_state.pending);
    try testing.expectEqual(@as(usize, 0), action_state.selected_conflict);
    try testing.expectEqual(merge_ui_state.Outcome.active, action_state.outcome);

    // Recovery also happens before redraw when App drains a later grow event first.
    action_screen.width = 80;
    action_screen.height = 10;
    action_ctx.consume_event = false;
    try pressKeyForTest(&action_view, &action_ctx, vaxis.Key.right);
    try pressKeyForTest(&action_view, &action_ctx, vaxis.Key.enter);
    try testing.expectEqual(@as(usize, 1), action_state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), action_state.selected_conflict);
    action_ctx.consume_event = false;
    try action_view.widget().handleEvent(&action_ctx, .{ .mouse = .{
        .col = 0,
        .row = 3,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), action_state.selected_conflict);
    action_ctx.consume_event = false;
    try pressKeyForTest(&action_view, &action_ctx, vaxis.Key.right);
    try pressKeyForTest(&action_view, &action_ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.ready, action_state.outcome);
    try testing.expect(!action_ctx.quit);
    try pressKeyForTest(&action_view, &action_ctx, vaxis.Key.enter);
    try testing.expect(action_ctx.quit);
}

test "merge TUI: pre-draw and undersized views block all merge actions" {
    const SizeCase = struct {
        width: u16,
        height: u16,
        draw_first: bool,
    };
    const cases = [_]SizeCase{
        .{ .width = 0, .height = 0, .draw_first = false },
        .{ .width = 79, .height = 9, .draw_first = true },
        .{ .width = 79, .height = 10, .draw_first = true },
        .{ .width = 80, .height = 9, .draw_first = true },
    };
    const events = [_]vxfw.Event{
        .{ .key_press = .{ .codepoint = vaxis.Key.right } },
        .{ .key_press = .{ .codepoint = vaxis.Key.down } },
        .{ .key_press = .{ .codepoint = 'o', .text = "o" } },
        .{ .key_press = .{ .codepoint = 't', .text = "t" } },
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
        .{ .key_press = .{ .codepoint = 'a', .text = "a" } },
        .{ .key_press = .{ .codepoint = 'q', .text = "q" } },
        .{ .key_press = .{ .codepoint = vaxis.Key.right, .mods = .{ .shift = true } } },
        .{ .mouse = .{
            .col = 0,
            .row = 3,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } },
        .{ .mouse = .{
            .col = 0,
            .row = 3,
            .button = .wheel_right,
            .mods = .{},
            .type = .press,
        } },
    };

    for (cases) |case| {
        for (events) |event| {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var fixture = try screenPlan(arena);
            var state = try merge_ui_state.State.init(arena, &fixture.plan);
            var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
            defer view.deinit();
            if (case.draw_first) {
                _ = try drawForTest(arena, view.widget(), case.width, case.height);
            }
            var ctx = eventContext(arena);
            ctx.redraw = false;

            try view.widget().handleEvent(&ctx, event);

            // Hidden actions must not alter either merge state or view navigation state.
            try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
            try testing.expectEqual(@as(usize, 0), state.selected_conflict);
            try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
            try testing.expectEqualStrings("", state.status);
            try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
            try testing.expect(!view.editing);
            try testing.expectEqual(@as(usize, 0), view.horizontal_offset);
            try testing.expect(!ctx.quit);
            try testing.expect(!ctx.redraw);
        }
    }
}

test "merge TUI: the final choice focuses Complete before exit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // The first side choice resolves one row but keeps the application open.
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!ctx.quit);

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const footer = FooterGeometry.init(100, 20);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, footer.row), "[Complete]") != null);
    try testing.expect(surface.readCell(footer.complete.start, footer.row).style.reverse);

    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(ctx.quit);
}

test "merge TUI: Up from Complete focuses Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(view.focus_area == .complete);

    // Complete sits under Result. Left and Escape still leave it for the hierarchy.
    try pressKeyForTest(&view, &ctx, vaxis.Key.left);
    try testing.expect(view.focus_area == .hierarchy);
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try testing.expect(view.focus_area == .complete);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    try testing.expect(view.focus_area == .hierarchy);
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try testing.expect(view.focus_area == .complete);

    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try testing.expect(view.focus_area == .inspector);
    try testing.expectEqual(ValueColumn.result, view.selected_value);
}

test "merge TUI: unchanged removed Result stays removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try deleteEditPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.result.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    try testing.expectEqualStrings("", state.status);
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    const result = try core.merge.finish(arena, &fixture.plan);
    try testing.expectEqualStrings(
        "--- !u!114 &1\nMonoBehaviour:\n  m_After: keep\n",
        result,
    );
    try testing.expect(std.mem.indexOf(u8, result, "<removed>") == null);
}

test "merge TUI: input replaces removed Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try deleteEditPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.result.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '0', .text = "0" } });
    const focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
    );

    try testing.expectEqualStrings("", state.status);
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expectEqualStrings(
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 0\n  m_After: keep\n",
        try core.merge.finish(arena, &fixture.plan),
    );
}

test "merge TUI: Enter asks before it applies an empty Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const operation_index = state.conflict_indices[0];
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);
    try testing.expect(!view.editing);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expect(view.dialog == null);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Empty YAML can be intentional, but one key press must not resolve it.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "This field will contain an empty YAML value.") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "[Cancel]") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "[Use Empty]") != null);
}

test "merge TUI: Enter cancels the empty value dialog by default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const operation_index = state.conflict_indices[0];
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Cancel must keep the empty draft available without resolving the conflict.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
    try testing.expect(view.focus_area == .inspector);
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("", value);
    switch (ctx.cmds.items[ctx.cmds.items.len - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.editor.widget())),
        else => return error.TestUnexpectedResult,
    }
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") == null);
}

test "merge TUI: Right and Enter apply an empty Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const operation_index = state.conflict_indices[0];
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Use Empty resolves this conflict and continues the normal merge flow.
    switch (fixture.plan.operations[operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(view.focus_area == .hierarchy);
    try testing.expect(!view.editing);
}

test "merge TUI: a queued Enter after apply completes instead of asking for empty" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try core.merge.build(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n",
    );
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '4', .text = "4" } });
    const surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!view.editing);
    try testing.expect(view.focus_area == .complete);

    // The TextField can still be focused for a queued Enter after apply cleared it.
    try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try testing.expect(view.dialog == null);
    try testing.expect(ctx.quit);
}

test "merge TUI: Enter on Theirs resolves the conflict and selects the next row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const operation_index = state.conflict_indices[0];
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    switch (fixture.plan.operations[operation_index].resolution) {
        .take => |side| try testing.expectEqual(core.merge.Side.theirs, side),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(view.focus_area == .hierarchy);
    try testing.expect(!ctx.quit);
}

test "merge TUI: Result treats Shift+T as a mode shortcut until editing begins" {
    for ([_][]const u8{ "", "[Edited", "[invalid" }) |prefix| {
        var memory = std.heap.ArenaAllocator.init(testing.allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        var built = try core.merge.build(arena, "--- !u!114 &1\nMonoBehaviour:\n  items: [A]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Ours]\n", "--- !u!114 &1\nMonoBehaviour:\n  items: [A, Theirs]\n");
        var state = try merge_ui_state.State.init(arena, &built.plan);
        var view = try viewForTest(arena, &state, "Array.prefab", built.partial);
        defer view.deinit();
        _ = try drawForTest(arena, view.widget(), 100, 20);
        var ctx = eventContext(arena);
        try focusResultForTest(&view, &ctx);
        const heading = try rowText(arena, try drawForTest(arena, view.widget(), 100, 20), BodyGeometry.init(20).inspector_heading_row);
        try testing.expect(std.mem.indexOf(u8, heading, "⇧T One side") != null);
        var parser: vaxis.Parser = .{};
        const event = (try parser.parse("T", arena)).event.?;
        try view.widget().handleEvent(&ctx, .{ .key_press = event.key_press });
        try testing.expect(view.combine_mode);
        try testing.expect(!view.editing);
        try testing.expectEqual(FocusArea.inspector, view.focus_area);
        try testing.expectEqual(ValueColumn.result, view.selected_value);
        try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
        if (prefix.len != 0)
            try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '[', .text = prefix } });
        const surface = try drawForTest(arena, view.widget(), 100, 20);
        try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, BodyGeometry.init(20).inspector_heading_row), "⇧T Both sides") != null);
        try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = event.key_press });
        // A display mode shortcut must not replace or submit a Result draft.
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}T", .{prefix}), try view.editor.toOwnedSlice());
        try testing.expect(state.pending == null);
        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expect(view.editing);
        try testing.expect(view.combine_mode);
    }
}

test "merge TUI: deletion before editing clears Result without entering the editor" {
    for ([_]u21{ vaxis.Key.backspace, vaxis.Key.delete }) |key| {
        for ([_]bool{ false, true }) |applied| {
            var memory = std.heap.ArenaAllocator.init(testing.allocator);
            defer memory.deinit();
            const arena = memory.allocator();
            var fixture = try screenPlan(arena);
            var state = try merge_ui_state.State.init(arena, &fixture.plan);
            try state.handle(.choose_ours);
            if (applied) {
                try state.handle(.apply_result);
                try state.handle(.{ .select_conflict = 0 });
            }
            var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
            defer view.deinit();
            _ = try drawForTest(arena, view.widget(), 100, 20);
            var ctx = eventContext(arena);
            try focusResultForTest(&view, &ctx);
            try pressKeyForTest(&view, &ctx, key);
            // Clearing a preview or accepted result reopens the choice without starting text input.
            try testing.expect(!view.editing);
            try testing.expect(view.focus_area == .inspector);
            try testing.expect(view.selected_value == .result);
            try testing.expectEqualStrings("", view.selectedResultInput());
            try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
            try testing.expect(state.pending == null);
        }
    }
}

test "merge TUI: a retained component can be edited after applying Theirs" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var fixture = try componentDeletePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    try state.handle(.{ .select_conflict = 0 });
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try beginEditingForTest(&view, &ctx);
    const source_text = try view.editor.buf.dupe();
    // The field value is part of the displayed component document, not a standalone scalar.
    const digit = std.mem.indexOf(u8, source_text, "m_Mass: 2").? + "m_Mass: 2".len;
    view.editor.buf.moveGapLeft(view.editor.buf.cursor - digit);
    var surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.backspace } });
    surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = .{ .codepoint = '3', .text = "3" } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    try testing.expect(!view.editing);
    // Reopening the result must use the edited document, not the original side preview.
    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try beginEditingForTest(&view, &ctx);
    try testing.expect(std.mem.indexOf(u8, try view.editor.buf.dupe(), "m_Mass: 3") != null);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqualStrings("", state.status);
    try testing.expect(!view.editing);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: 3"), try core.merge.finish(arena, &fixture.plan));
}

test "merge TUI: a CRLF component stays multiline while editing and keeps CRLF on apply" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const lf = try componentDeletePlan(arena);
    var fixture = try core.merge.build(
        arena,
        try std.mem.replaceOwned(u8, arena, lf.plan.base.bytes, "\n", "\r\n"),
        try std.mem.replaceOwned(u8, arena, lf.plan.ours.bytes, "\n", "\r\n"),
        try std.mem.replaceOwned(u8, arena, lf.plan.theirs.bytes, "\n", "\r\n"),
    );
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    try state.handle(.choose_theirs);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    view.raw_view = true;
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try beginEditingForTest(&view, &ctx);
    // The editor uses logical LF lines; serialization restores the component's existing line ending.
    try testing.expect(std.mem.indexOfScalar(u8, try view.editor.buf.dupe(), '\r') == null);
    var surface = try drawForTest(arena, view.widget(), 100, 20);
    try testing.expect(std.mem.startsWith(u8, try rowText(arena, surface.children[0].surface, 1), "Rigidbody:"));
    for ([_]vaxis.Key{
        .{ .codepoint = vaxis.Key.up },        .{ .codepoint = vaxis.Key.end },
        .{ .codepoint = vaxis.Key.backspace }, .{ .codepoint = '3', .text = "3" },
        .{ .codepoint = vaxis.Key.enter },
    }) |key| {
        try routeFocusedEventForTest(arena, surface, view.editor.widget(), &ctx, .{ .key_press = key });
        surface = try drawForTest(arena, view.widget(), 100, 20);
    }
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, fixture.plan.theirs.bytes, "m_Mass: 2", "m_Mass: 3"), try core.merge.finish(arena, &fixture.plan));
}
