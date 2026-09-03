const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const merge_ui_state = @import("merge_ui_state.zig");
const testing = std.testing;
const vxfw = vaxis.vxfw;

const Range = struct {
    start: u16,
    end: u16,
};

const Geometry = struct {
    hierarchy: Range,
    inspector: Range,
    property: Range,
    base: Range,
    ours: Range,
    theirs: Range,
    result: Range,

    fn init(width: u16) Geometry {
        const split = @max(@as(u16, 24), width / 3);
        const inspector_width = width - split - 1;
        const property_width = @max(@as(u16, 14), inspector_width / 3);
        const value_width = (inspector_width - property_width - 4) / 4;
        const property_start = split + 1;
        const base_start = property_start + property_width + 1;
        const ours_start = base_start + value_width + 1;
        const theirs_start = ours_start + value_width + 1;
        const result_start = theirs_start + value_width + 1;
        return .{
            .hierarchy = .{ .start = 0, .end = split },
            .inspector = .{ .start = property_start, .end = width },
            .property = .{ .start = property_start, .end = base_start - 1 },
            .base = .{ .start = base_start, .end = ours_start - 1 },
            .ours = .{ .start = ours_start, .end = theirs_start - 1 },
            .theirs = .{ .start = theirs_start, .end = result_start - 1 },
            .result = .{ .start = result_start, .end = width },
        };
    }
};

const FooterGeometry = struct {
    row: u16,
    apply: Range,
    abort: Range,

    fn init(width: u16, height: u16) FooterGeometry {
        return .{
            .row = height - 1,
            .apply = .{ .start = width - 24, .end = width - 9 },
            .abort = .{ .start = width - 8, .end = width },
        };
    }
};

const ValueColumn = enum { base, ours, theirs, result };

pub const View = struct {
    state: *merge_ui_state.State,
    path: []const u8,
    editor: vxfw.TextField,
    editing: bool = false,
    horizontal_offset: usize = 0,
    vertical_offset: usize = 0,
    selected_value: ValueColumn = .result,
    last_size: vxfw.Size = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        state: *merge_ui_state.State,
        path: []const u8,
    ) View {
        return .{
            .state = state,
            .path = path,
            .editor = vxfw.TextField.init(allocator),
        };
    }

    pub fn deinit(self: *View) void {
        self.editor.deinit();
    }

    pub fn widget(self: *View) vxfw.Widget {
        self.editor.userdata = self;
        self.editor.onSubmit = submitCustom;
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = draw,
        };
    }

    fn dispatch(self: *View, ctx: *vxfw.EventContext, action: merge_ui_state.Action) !void {
        switch (action) {
            .move_up, .move_down, .select_conflict => self.horizontal_offset = 0,
            else => {},
        }
        try self.state.handle(action);
        if (self.last_size.height >= 10) {
            const visible_rows: usize = self.last_size.height - 4;
            if (self.state.selected_conflict < self.vertical_offset) {
                self.vertical_offset = self.state.selected_conflict;
            } else if (self.state.selected_conflict >= self.vertical_offset + visible_rows) {
                self.vertical_offset = self.state.selected_conflict - visible_rows + 1;
            }
        }
        const should_quit = switch (action) {
            .apply_result => self.state.outcome == .ready,
            .abort => self.state.outcome == .aborted,
            else => false,
        };
        if (should_quit) ctx.quit = true;
        ctx.consumeAndRedraw();
    }

    fn beginEditing(self: *View, ctx: *vxfw.EventContext) !void {
        self.editor.clearRetainingCapacity();
        if (self.state.pending) |pending| switch (pending) {
            .custom => |value| try self.editor.insertSliceAtCursor(value),
            else => {},
        };
        self.editing = true;
        try ctx.requestFocus(self.editor.widget());
        ctx.consumeAndRedraw();
    }

    fn handleMouse(self: *View, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) !void {
        if (mouse.type != .press) return;
        if (mouse.button == .wheel_up) return self.dispatch(ctx, .move_up);
        if (mouse.button == .wheel_down) return self.dispatch(ctx, .move_down);
        if (mouse.button == .wheel_left) {
            self.horizontal_offset -|= 1;
            return ctx.consumeAndRedraw();
        }
        if (mouse.button == .wheel_right) {
            self.horizontal_offset += 1;
            return ctx.consumeAndRedraw();
        }
        if (mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        if (self.last_size.width < 80 or self.last_size.height < 10) return;

        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const geometry = Geometry.init(self.last_size.width);
        const footer = FooterGeometry.init(self.last_size.width, self.last_size.height);
        if (row == footer.row and inRange(col, footer.apply)) {
            return self.dispatch(ctx, .apply_result);
        }
        if (row == footer.row and inRange(col, footer.abort)) {
            return self.dispatch(ctx, .abort);
        }
        if (row < 3) return;

        const conflict_index = self.vertical_offset + row - 3;
        if (conflict_index >= self.state.conflict_indices.len) return;
        try self.dispatch(ctx, .{ .select_conflict = conflict_index });
        if (inRange(col, geometry.ours)) {
            self.selected_value = .ours;
            self.horizontal_offset = 0;
            return self.dispatch(ctx, .choose_ours);
        }
        if (inRange(col, geometry.theirs)) {
            self.selected_value = .theirs;
            self.horizontal_offset = 0;
            return self.dispatch(ctx, .choose_theirs);
        }
        if (inRange(col, geometry.result)) {
            self.selected_value = .result;
            self.horizontal_offset = 0;
            return self.beginEditing(ctx);
        }
        if (inRange(col, geometry.hierarchy)) return self.dispatch(ctx, .pane_left);
        return self.dispatch(ctx, .pane_right);
    }
};

fn sideText(value: ?core.merge.SideValue) []const u8 {
    return if (value) |present| present.bytes else "<removed>";
}

fn resolutionText(
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) []const u8 {
    return switch (resolution) {
        .unresolved => "",
        .take => |side| switch (side) {
            .base => sideText(operation.values.base),
            .ours => sideText(operation.values.ours),
            .theirs => sideText(operation.values.theirs),
        },
        .remove => "<removed>",
        .custom => |value| value,
    };
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

fn draw(
    userdata: *anyopaque,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const self: *View = @ptrCast(@alignCast(userdata));
    const size: vxfw.Size = .{
        .width = ctx.max.width orelse ctx.min.width,
        .height = ctx.max.height orelse ctx.min.height,
    };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    self.last_size = size;
    if (size.width < 80 or size.height < 10) {
        writeClipped(
            surface,
            0,
            0,
            size.width,
            "Needs 80 columns and 10 rows. Resize the terminal.",
        );
        return surface;
    }

    const geometry = Geometry.init(size.width);
    const footer = FooterGeometry.init(size.width, size.height);
    const unresolved = try std.fmt.allocPrint(
        ctx.arena,
        "{d} unresolved",
        .{self.state.unresolvedCount()},
    );
    writeClipped(surface, 0, 0, size.width - 20, self.path);
    writeClipped(surface, size.width - 20, 0, 20, unresolved);
    writeClipped(surface, 0, 1, geometry.hierarchy.end, "Hierarchy");
    writeClipped(
        surface,
        geometry.inspector.start,
        1,
        geometry.inspector.end - geometry.inspector.start,
        "Inspector",
    );
    inline for (.{
        .{ geometry.property, "Property" },
        .{ geometry.base, "Base" },
        .{ geometry.ours, "Ours" },
        .{ geometry.theirs, "Theirs" },
        .{ geometry.result, "Result" },
    }) |column| {
        writeClipped(
            surface,
            column[0].start,
            2,
            column[0].end - column[0].start,
            column[1],
        );
    }

    for (1..footer.row) |row| {
        inline for (.{
            geometry.hierarchy.end,
            geometry.property.end,
            geometry.base.end,
            geometry.ours.end,
            geometry.theirs.end,
        }) |separator| {
            surface.writeCell(separator, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
            });
        }
    }
    for (self.state.conflict_indices[self.vertical_offset..], 0..) |operation_index, visible_index| {
        const index = self.vertical_offset + visible_index;
        const row = visible_index + 3;
        if (row >= footer.row) break;
        const operation = &self.state.plan.operations[operation_index];
        const pending = if (index == self.state.selected_conflict)
            self.state.pending orelse operation.resolution
        else
            operation.resolution;
        const columns = .{
            .{ geometry.base, sideText(operation.values.base), ValueColumn.base },
            .{ geometry.ours, sideText(operation.values.ours), ValueColumn.ours },
            .{ geometry.theirs, sideText(operation.values.theirs), ValueColumn.theirs },
            .{ geometry.result, resolutionText(operation, pending), ValueColumn.result },
        };
        writeClipped(
            surface,
            geometry.hierarchy.start,
            @intCast(row),
            geometry.hierarchy.end - geometry.hierarchy.start,
            operation.hierarchy_path,
        );
        writeClipped(
            surface,
            geometry.property.start,
            @intCast(row),
            geometry.property.end - geometry.property.start,
            operation.property_path,
        );
        inline for (columns) |column| {
            const text = if (index == self.state.selected_conflict and
                column[2] == self.selected_value)
                skipGraphemes(column[1], self.horizontal_offset)
            else
                column[1];
            writeClipped(
                surface,
                column[0].start,
                @intCast(row),
                column[0].end - column[0].start,
                text,
            );
        }
    }

    writeClipped(
        surface,
        0,
        footer.row,
        footer.apply.start,
        "↑↓ move  ←→ pane  Enter edit  o ours  t theirs",
    );
    writeClipped(
        surface,
        footer.apply.start,
        footer.row,
        footer.apply.end - footer.apply.start,
        "a Apply result",
    );
    writeClipped(
        surface,
        footer.abort.start,
        footer.row,
        footer.abort.end - footer.abort.start,
        "q Abort",
    );
    if (self.state.status.len != 0) {
        writeClipped(surface, 0, footer.row - 1, size.width, self.state.status);
    }

    if (self.editing and self.state.selected_conflict >= self.vertical_offset) {
        const visible_index = self.state.selected_conflict - self.vertical_offset;
        const editor_row = visible_index + 3;
        if (editor_row < footer.row) {
            const editor_size: vxfw.Size = .{
                .width = geometry.result.end - geometry.result.start,
                .height = 1,
            };
            const child_surface = try self.editor.widget().draw(ctx.withConstraints(
                editor_size,
                vxfw.MaxSize.fromSize(editor_size),
            ));
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{
                    .col = @intCast(geometry.result.start),
                    .row = @intCast(editor_row),
                },
                .surface = child_surface,
            };
            surface.children = children;
        }
    }
    return surface;
}

fn submitCustom(
    userdata: ?*anyopaque,
    ctx: *vxfw.EventContext,
    value: []const u8,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata.?));
    try self.state.handle(.{ .edit_result = value });
    self.editing = false;
    try ctx.requestFocus(self.widget());
}

fn writeClipped(
    surface: vxfw.Surface,
    start: u16,
    row: u16,
    width: u16,
    text: []const u8,
) void {
    var col = start;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width = vaxis.gwidth.gwidth(bytes, .unicode);
        if (col + cell_width > start + width) break;
        surface.writeCell(col, row, .{ .char = .{
            .grapheme = bytes,
            .width = @intCast(cell_width),
        } });
        col += cell_width;
    }
}

fn inRange(col: u16, range: Range) bool {
    return col >= range.start and col < range.end;
}

fn handleEvent(
    userdata: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata));
    if (self.editing) switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.editor.clearRetainingCapacity();
                self.editing = false;
                try ctx.requestFocus(self.widget());
                return ctx.consumeAndRedraw();
            }
            return self.editor.handleEvent(ctx, event);
        },
        else => return self.editor.handleEvent(ctx, event),
    };

    switch (event) {
        .winsize => ctx.consumeAndRedraw(),
        .mouse => |mouse| try self.handleMouse(ctx, mouse),
        .key_press => |key| {
            if (key.matches(vaxis.Key.left, .{ .shift = true })) {
                self.horizontal_offset -|= 1;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.right, .{ .shift = true })) {
                self.horizontal_offset += 1;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.left, .{})) return self.dispatch(ctx, .pane_left);
            if (key.matches(vaxis.Key.right, .{})) return self.dispatch(ctx, .pane_right);
            if (key.matches(vaxis.Key.tab, .{})) {
                return self.dispatch(
                    ctx,
                    if (self.state.pane == .hierarchy) .pane_right else .pane_left,
                );
            }
            if (key.matches(vaxis.Key.up, .{})) return self.dispatch(ctx, .move_up);
            if (key.matches(vaxis.Key.down, .{})) return self.dispatch(ctx, .move_down);
            if (key.matches('o', .{})) {
                self.selected_value = .ours;
                self.horizontal_offset = 0;
                return self.dispatch(ctx, .choose_ours);
            }
            if (key.matches('t', .{})) {
                self.selected_value = .theirs;
                self.horizontal_offset = 0;
                return self.dispatch(ctx, .choose_theirs);
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                self.selected_value = .result;
                self.horizontal_offset = 0;
                return self.beginEditing(ctx);
            }
            if (key.matches('a', .{})) return self.dispatch(ctx, .apply_result);
            if (key.matches('q', .{})) return self.dispatch(ctx, .abort);
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
) !void {
    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, env_map, &tty_buffer);
    defer app.deinit();
    var view = View.init(allocator, state, path);
    defer view.deinit();
    try app.run(view.widget(), .{});
}

fn screenPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n  m_Drag: 0\n",
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 12\n  m_Drag: 2\n",
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 8\n  m_Drag: 3\n",
    );
}

fn longValuePlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!54 &54\nRigidbody:\n  m_Label: ABCDEFGHIJKLMNO-base\n",
        "--- !u!54 &54\nRigidbody:\n  m_Label: ABCDEFGHIJKLMNO-ours\n",
        "--- !u!54 &54\nRigidbody:\n  m_Label: ABCDEFGHIJKLMNO-theirs\n",
    );
}

fn tallPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!54 &54\nRigidbody:\n  f0: 0\n  f1: 0\n  f2: 0\n  f3: 0\n  f4: 0\n  f5: 0\n  f6: 0\n  f7: 0\n",
        "--- !u!54 &54\nRigidbody:\n  f0: 1\n  f1: 1\n  f2: 1\n  f3: 1\n  f4: 1\n  f5: 1\n  f6: 1\n  f7: 1\n",
        "--- !u!54 &54\nRigidbody:\n  f0: 2\n  f1: 2\n  f2: 2\n  f3: 2\n  f4: 2\n  f5: 2\n  f6: 2\n  f7: 2\n",
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

fn eventContext(arena: std.mem.Allocator) vxfw.EventContext {
    return .{ .io = testing.io, .alloc = arena, .cmds = .empty };
}

test "merge TUI: draws two panes and aligned value columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "Assets/Prefabs/Robot.prefab");
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const title = try rowText(arena, surface, 0);
    const pane_titles = try rowText(arena, surface, 1);
    const geometry = Geometry.init(100);

    // These assertions catch drift between the shared column geometry and renderer.
    try testing.expect(std.mem.indexOf(u8, title, "Assets/Prefabs/Robot.prefab") != null);
    try testing.expect(std.mem.indexOf(u8, title, "2 unresolved") != null);
    try testing.expect(std.mem.indexOf(u8, pane_titles, "Hierarchy") != null);
    try testing.expect(std.mem.indexOf(u8, pane_titles, "Inspector") != null);
    try testing.expectEqualStrings("Property", try cellsText(arena, surface, 2, geometry.property.start, "Property".len));
    try testing.expectEqualStrings("Base", try cellsText(arena, surface, 2, geometry.base.start, "Base".len));
    try testing.expectEqualStrings("Ours", try cellsText(arena, surface, 2, geometry.ours.start, "Ours".len));
    try testing.expectEqualStrings("Theirs", try cellsText(arena, surface, 2, geometry.theirs.start, "Theirs".len));
    try testing.expectEqualStrings("Result", try cellsText(arena, surface, 2, geometry.result.start, "Result".len));
    try testing.expectEqualStrings("m_Mass", try cellsText(arena, surface, 3, geometry.property.start, "m_Mass".len));
    for ([_]u16{
        geometry.hierarchy.end,
        geometry.property.end,
        geometry.base.end,
        geometry.ours.end,
        geometry.theirs.end,
    }) |separator| {
        try testing.expectEqualStrings("│", surface.readCell(separator, 2).char.grapheme);
    }
}

test "merge TUI: clips a long value before the next column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    const surface = try vxfw.Surface.init(arena, view.widget(), .{ .width = 12, .height = 1 });

    // A missing clip guard would overwrite the separator cell at column 6.
    writeClipped(surface, 1, 0, 5, "123456789");
    try testing.expectEqualStrings(" 12345 ", (try rowText(arena, surface, 0))[0..7]);
}

test "merge TUI: keyboard and mouse choose ours through the same state action" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var key_fixture = try screenPlan(arena);
    var mouse_fixture = try screenPlan(arena);
    var key_state = try merge_ui_state.State.init(arena, &key_fixture.plan);
    var mouse_state = try merge_ui_state.State.init(arena, &mouse_fixture.plan);
    var key_view = View.init(arena, &key_state, "A.prefab");
    defer key_view.deinit();
    var mouse_view = View.init(arena, &mouse_state, "A.prefab");
    defer mouse_view.deinit();
    _ = try drawForTest(arena, mouse_view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    const geometry = Geometry.init(100);
    try mouse_view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // A mouse-only branch would make these pending resolutions differ.
    try testing.expectEqualDeep(key_state.pending, mouse_state.pending);
}

test "merge TUI: keyboard moves panes and rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    // Each key must map to State.handle rather than changing view-only state.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try testing.expectEqual(merge_ui_state.Pane.inspector, state.pane);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab } });
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expect(!ctx.quit);
}

test "merge TUI: mouse clicks move panes and rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(100);

    // Hit testing must use the same pane and row geometry as drawing.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.property.start),
        .row = 4,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(merge_ui_state.Pane.inspector, state.pane);
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 1,
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
}

test "merge TUI: TextField submits an arbitrary YAML value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    // The real TextField must feed State.handle so the short-lived key text is copied.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '1', .text = "1.25" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    switch (state.pending.?) {
        .custom => |value| try testing.expectEqualStrings("1.25", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!view.editing);
    try testing.expect(!ctx.quit);
}

test "merge TUI: draws the active TextField in the Result cell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '1', .text = "1.25" } });
    const surface = try drawForTest(arena, view.widget(), 100, 20);

    // Omitting the TextField child would leave editing invisible to the user.
    try testing.expectEqual(@as(usize, 1), surface.children.len);
    try testing.expectEqual(@as(i17, Geometry.init(100).result.start), surface.children[0].origin.col);
    try testing.expectEqual(@as(i17, 3), surface.children[0].origin.row);
    try testing.expect(std.mem.startsWith(u8, try rowText(arena, surface.children[0].surface, 0), "1.25"));
}

test "merge TUI: Escape cancels TextField input and restores root focus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '9', .text = "99" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    // Escape must not leak the editor buffer into the merge plan.
    try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
    try testing.expect(!view.editing);
    try testing.expect(ctx.cmds.items.len >= 2);
    switch (ctx.cmds.items[ctx.cmds.items.len - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.widget())),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: keyboard and horizontal wheel scroll only the selected value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var key_fixture = try longValuePlan(arena);
    var mouse_fixture = try longValuePlan(arena);
    var key_state = try merge_ui_state.State.init(arena, &key_fixture.plan);
    var mouse_state = try merge_ui_state.State.init(arena, &mouse_fixture.plan);
    var key_view = View.init(arena, &key_state, "A.prefab");
    defer key_view.deinit();
    var mouse_view = View.init(arena, &mouse_state, "A.prefab");
    defer mouse_view.deinit();
    _ = try drawForTest(arena, mouse_view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.right,
        .mods = .{ .shift = true },
    } });
    try mouse_view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 0,
        .row = 3,
        .button = .wheel_right,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(key_view.horizontal_offset, mouse_view.horizontal_offset);

    const surface = try drawForTest(arena, key_view.widget(), 100, 20);
    const geometry = Geometry.init(100);
    // Scrolling Ours must not shift the unselected Theirs value.
    try testing.expectEqualStrings("BC", try cellsText(arena, surface, 3, geometry.ours.start, 2));
    try testing.expectEqualStrings("AB", try cellsText(arena, surface, 3, geometry.theirs.start, 2));

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.left,
        .mods = .{ .shift = true },
    } });
    try testing.expectEqual(@as(usize, 0), key_view.horizontal_offset);
}

test "merge TUI: wheel moves the selection and resize requests redraw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // Real wheel and winsize events must stay inside the running event loop.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 2,
        .row = 3,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    ctx.redraw = false;
    try view.widget().handleEvent(&ctx, .{ .winsize = .{
        .rows = 24,
        .cols = 100,
        .x_pixel = 0,
        .y_pixel = 0,
    } });
    try testing.expect(ctx.redraw);
    try testing.expect(!ctx.quit);
}

test "merge TUI: moving down keeps the selected row visible" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 10);
    var ctx = eventContext(arena);

    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    const surface = try drawForTest(arena, view.widget(), 100, 10);

    // Without vertical offset updates, f7 would be below the footer.
    try testing.expectEqual(@as(usize, 2), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 8), "f7") != null);
}

test "merge TUI: apply quits only after every conflict is ready" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    // The first apply resolves one row but must keep the application open.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 't', .text = "t" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(ctx.quit);
}

test "merge TUI: non-apply actions do not quit a ready view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const yaml = "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n";
    var fixture = try core.merge.build(arena, yaml, yaml, yaml);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    // A ready model can still receive navigation; only Apply or Abort may stop the loop.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!ctx.quit);
}

test "merge TUI: q aborts and quits through a real key event" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    // Abort must update the model before it terminates the event loop.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'q', .text = "q" } });
    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
}

test "merge TUI: mouse applies a result and aborts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(100);
    const footer = FooterGeometry.init(100, 20);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(footer.apply.start),
        .row = @intCast(footer.row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    // Apply resolves memory only and keeps the loop alive while one row remains.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(!ctx.quit);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(footer.abort.start),
        .row = @intCast(footer.row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
}

test "merge TUI: clicking Result starts TextField editing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // Result clicks and Enter must share the same editor path.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(Geometry.init(100).result.start),
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expect(view.editing);
    try testing.expect(ctx.cmds.items.len != 0);
    switch (ctx.cmds.items[ctx.cmds.items.len - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.editor.widget())),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: a small terminal reports its required size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 79, 9);

    // The minimum-size branch must avoid geometry underflow and show one concise line.
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 0), "Needs 80 columns and 10 rows") != null);
    try testing.expectEqual(@as(usize, 0), surface.children.len);
}
