const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const merge_ui_state = @import("merge_ui_state.zig");
const testing = std.testing;
const vxfw = vaxis.vxfw;

const minimum_size: vxfw.Size = .{ .width = 80, .height = 10 };

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

const BodyGeometry = struct {
    rows: Range,
    status_row: u16,

    fn init(height: u16) BodyGeometry {
        const status_row = height - 2;
        return .{
            .rows = .{ .start = 3, .end = status_row },
            .status_row = status_row,
        };
    }

    fn visibleRows(self: BodyGeometry) usize {
        return self.rows.end - self.rows.start;
    }
};

const ValueColumn = enum { base, ours, theirs, result };

fn valueRange(geometry: Geometry, column: ValueColumn) Range {
    return switch (column) {
        .base => geometry.base,
        .ours => geometry.ours,
        .theirs => geometry.theirs,
        .result => geometry.result,
    };
}

pub const View = struct {
    state: *merge_ui_state.State,
    path: []const u8,
    editor: vxfw.TextField,
    editing: bool = false,
    horizontal_offset: usize = 0,
    vertical_offset: usize = 0,
    selected_value: ValueColumn = .result,
    last_size: vxfw.Size = .{},
    live_screen: ?*const vaxis.Screen = null,

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
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = draw,
        };
    }

    fn eventSize(self: *const View) vxfw.Size {
        const screen = self.live_screen orelse return self.last_size;
        return .{ .width = screen.width, .height = screen.height };
    }

    fn ensureSelectionVisible(self: *View, size: vxfw.Size) void {
        if (!isUsableSize(size)) return;
        const visible_rows = BodyGeometry.init(size.height).visibleRows();
        const max_offset = self.state.conflict_indices.len -| visible_rows;
        self.vertical_offset = @min(self.vertical_offset, max_offset);
        if (self.state.selected_conflict < self.vertical_offset) {
            self.vertical_offset = self.state.selected_conflict;
        } else if (self.state.selected_conflict - self.vertical_offset >= visible_rows) {
            self.vertical_offset = self.state.selected_conflict - visible_rows + 1;
        }
        self.vertical_offset = @min(self.vertical_offset, max_offset);
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
        try self.state.handle(action);
        self.ensureSelectionVisible(size);
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

    fn selectedText(self: *const View) []const u8 {
        if (self.state.selected_conflict >= self.state.conflict_indices.len) return "";
        const operation_index = self.state.conflict_indices[self.state.selected_conflict];
        const operation = &self.state.plan.operations[operation_index];
        return switch (self.selected_value) {
            .base => sideText(operation.values.base),
            .ours => sideText(operation.values.ours),
            .theirs => sideText(operation.values.theirs),
            .result => resolutionText(
                operation,
                self.state.pending orelse operation.resolution,
            ),
        };
    }

    fn maxHorizontalOffset(self: *const View, geometry: Geometry) usize {
        const text = self.selectedText();
        const selected_range = valueRange(geometry, self.selected_value);
        const viewport_width: usize = selected_range.end - selected_range.start;
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
        self.horizontal_offset -|= 1;
        ctx.consumeAndRedraw();
    }

    fn scrollRight(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) void {
        const geometry = Geometry.init(size.width);
        self.horizontal_offset = @min(
            self.horizontal_offset +| 1,
            self.maxHorizontalOffset(geometry),
        );
        ctx.consumeAndRedraw();
    }

    fn handleMouse(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) !void {
        if (mouse.type != .press) return;
        if (mouse.button == .wheel_up) return self.dispatch(ctx, .move_up, size);
        if (mouse.button == .wheel_down) return self.dispatch(ctx, .move_down, size);
        if (mouse.button == .wheel_left) return self.scrollLeft(ctx);
        if (mouse.button == .wheel_right) return self.scrollRight(ctx, size);
        if (mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const geometry = Geometry.init(size.width);
        const footer = FooterGeometry.init(size.width, size.height);
        const body = BodyGeometry.init(size.height);
        if (row == footer.row and inRange(col, footer.apply)) {
            return self.dispatch(ctx, .apply_result, size);
        }
        if (row == footer.row and inRange(col, footer.abort)) {
            return self.dispatch(ctx, .abort, size);
        }
        if (row < body.rows.start or row >= body.rows.end) return;

        const conflict_index = self.vertical_offset + row - body.rows.start;
        if (conflict_index >= self.state.conflict_indices.len) return;
        try self.dispatch(ctx, .{ .select_conflict = conflict_index }, size);
        if (inRange(col, geometry.ours)) {
            self.selected_value = .ours;
            self.horizontal_offset = 0;
            return self.dispatch(ctx, .choose_ours, size);
        }
        if (inRange(col, geometry.theirs)) {
            self.selected_value = .theirs;
            self.horizontal_offset = 0;
            return self.dispatch(ctx, .choose_theirs, size);
        }
        if (inRange(col, geometry.result)) {
            self.selected_value = .result;
            self.horizontal_offset = 0;
            return self.beginEditing(ctx);
        }
        if (inRange(col, geometry.hierarchy)) return self.dispatch(ctx, .pane_left, size);
        return self.dispatch(ctx, .pane_right, size);
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

    const geometry = Geometry.init(size.width);
    const footer = FooterGeometry.init(size.width, size.height);
    const body = BodyGeometry.init(size.height);
    self.ensureSelectionVisible(size);
    self.horizontal_offset = @min(self.horizontal_offset, self.maxHorizontalOffset(geometry));
    const unresolved = try std.fmt.allocPrint(
        ctx.arena,
        "{d} unresolved",
        .{self.state.unresolvedCount()},
    );
    writeClipped(surface, 0, 0, size.width - 20, self.path);
    writeClipped(surface, size.width - 20, 0, 20, unresolved);
    writeClipped(
        surface,
        0,
        1,
        geometry.hierarchy.end,
        if (self.state.pane == .hierarchy) "> Hierarchy" else "  Hierarchy",
    );
    writeClipped(
        surface,
        geometry.inspector.start,
        1,
        geometry.inspector.end - geometry.inspector.start,
        if (self.state.pane == .inspector) "> Inspector" else "  Inspector",
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
        const row = visible_index + body.rows.start;
        if (row >= body.rows.end) break;
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
            2,
            if (index == self.state.selected_conflict) "> " else "  ",
        );
        writeClipped(
            surface,
            geometry.hierarchy.start + 2,
            @intCast(row),
            geometry.hierarchy.end - geometry.hierarchy.start - 2,
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
        if (index == self.state.selected_conflict) {
            styleRange(surface, @intCast(row), valueRange(geometry, self.selected_value), .{
                .reverse = true,
            });
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
        writeClipped(surface, 0, body.status_row, size.width, self.state.status);
    }

    if (self.editing and self.state.selected_conflict >= self.vertical_offset) {
        const visible_index = self.state.selected_conflict - self.vertical_offset;
        const editor_row = visible_index + body.rows.start;
        if (editor_row < body.rows.end) {
            self.editor.style = .{ .reverse = true };
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
    var col: usize = start;
    const end: usize = @as(usize, start) + width;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width = vaxis.gwidth.gwidth(bytes, .unicode);
        const next_col = col + cell_width;
        if (next_col > end) break;
        surface.writeCell(@intCast(col), row, .{ .char = .{
            .grapheme = bytes,
            .width = @intCast(cell_width),
        } });
        col = next_col;
    }
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
    if (!isUsableSize(self.eventSize())) switch (event) {
        .key_press, .mouse => ctx.consumeEvent(),
        else => {},
    };
}

fn handleEvent(
    userdata: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata));
    const size = self.eventSize();
    switch (event) {
        .winsize => return ctx.consumeAndRedraw(),
        .key_press, .mouse => {
            if (!isUsableSize(size)) return ctx.consumeEvent();
            self.ensureSelectionVisible(size);
        },
        else => {},
    }
    if (self.editing) {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.editor.clearRetainingCapacity();
                    self.editing = false;
                    try ctx.requestFocus(self.widget());
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
        if (ctx.phase == .at_target) return self.editor.handleEvent(ctx, event);
        return;
    }

    switch (event) {
        .mouse => |mouse| try self.handleMouse(ctx, mouse, size),
        .key_press => |key| {
            if (key.matches(vaxis.Key.left, .{ .shift = true })) return self.scrollLeft(ctx);
            if (key.matches(vaxis.Key.right, .{ .shift = true })) return self.scrollRight(ctx, size);
            if (key.matches(vaxis.Key.left, .{})) return self.dispatch(ctx, .pane_left, size);
            if (key.matches(vaxis.Key.right, .{})) return self.dispatch(ctx, .pane_right, size);
            if (key.matches(vaxis.Key.tab, .{})) {
                return self.dispatch(
                    ctx,
                    if (self.state.pane == .hierarchy) .pane_right else .pane_left,
                    size,
                );
            }
            if (key.matches(vaxis.Key.up, .{})) return self.dispatch(ctx, .move_up, size);
            if (key.matches(vaxis.Key.down, .{})) return self.dispatch(ctx, .move_down, size);
            if (key.matches('o', .{})) {
                self.selected_value = .ours;
                self.horizontal_offset = 0;
                return self.dispatch(ctx, .choose_ours, size);
            }
            if (key.matches('t', .{})) {
                self.selected_value = .theirs;
                self.horizontal_offset = 0;
                return self.dispatch(ctx, .choose_theirs, size);
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                self.selected_value = .result;
                self.horizontal_offset = 0;
                return self.beginEditing(ctx);
            }
            if (key.matches('a', .{})) return self.dispatch(ctx, .apply_result, size);
            if (key.matches('q', .{})) return self.dispatch(ctx, .abort, size);
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
    view.live_screen = &app.vx.screen;
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

fn unicodeValuePlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!54 &54\nRigidbody:\n  m_Label: 漢字e\u{301}🙂終BASE\n",
        "--- !u!54 &54\nRigidbody:\n  m_Label: 漢字e\u{301}🙂終OURS\n",
        "--- !u!54 &54\nRigidbody:\n  m_Label: 漢字e\u{301}🙂終THEIRS\n",
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

test "merge TUI: active pane marker follows left and right navigation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    const geometry = Geometry.init(80);
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // A one-cell marker keeps pane focus visible without decorative chrome.
    try testing.expectEqualStrings(">", surface.readCell(geometry.hierarchy.start, 1).char.grapheme);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.inspector.start, 1).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.hierarchy.start, 1).char.grapheme);
    try testing.expectEqualStrings(">", surface.readCell(geometry.inspector.start, 1).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(">", surface.readCell(geometry.hierarchy.start, 1).char.grapheme);
}

test "merge TUI: selected row marker follows up and down navigation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // The marker identifies the row that side-selection keys will change.
    try testing.expectEqualStrings(">", surface.readCell(0, 3).char.grapheme);
    try testing.expectEqualStrings(" ", surface.readCell(0, 4).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(" ", surface.readCell(0, 3).char.grapheme);
    try testing.expectEqualStrings(">", surface.readCell(0, 4).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(">", surface.readCell(0, 3).char.grapheme);
}

test "merge TUI: selected value style follows Ours Theirs and Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expect(surface.readCell(geometry.ours.start, 3).style.reverse);
    try testing.expect(!surface.readCell(geometry.theirs.start, 3).style.reverse);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 't', .text = "t" } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expect(!surface.readCell(geometry.ours.start, 3).style.reverse);
    try testing.expect(surface.readCell(geometry.theirs.start, 3).style.reverse);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    // The editor child is the visible Result cell while it owns focus.
    try testing.expectEqual(@as(usize, 1), surface.children.len);
    try testing.expect(surface.children[0].surface.readCell(0, 0).style.reverse);
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

test "merge TUI: clips a wide grapheme at the maximum terminal boundary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    const surface = try vxfw.Surface.init(arena, view.widget(), .{ .width = 65535, .height = 1 });
    surface.writeCell(65534, 0, .{ .char = .{ .grapheme = "│", .width = 1 } });

    // A two-cell grapheme cannot fit in the final cell and must not overflow u16.
    writeClipped(surface, 65534, 0, 1, "🙂");

    try testing.expectEqualStrings("│", surface.readCell(65534, 0).char.grapheme);
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
    _ = try drawForTest(arena, key_view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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

test "merge TUI: focused editor survives a small resize without accepting hidden input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var ctx = eventContext(arena);

    _ = try drawForTest(arena, view.widget(), 80, 10);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    const small = try drawForTest(arena, view.widget(), 79, 9);

    // The pinned App rebuilds this real widget path after every draw.
    try routeFocusedEventForTest(
        arena,
        small,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '9', .text = "9" } },
    );

    const restored = try drawForTest(arena, view.widget(), 80, 10);
    try routeFocusedEventForTest(
        arena,
        restored,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '7', .text = "7" } },
    );
    try routeFocusedEventForTest(
        arena,
        restored,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
    );

    // If the hidden key reached TextField, the submitted value would be "97".
    switch (state.pending.?) {
        .custom => |value| try testing.expectEqualStrings("7", value),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: live screen gates queued shrink input before redraw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var edit_fixture = try screenPlan(arena);
    var edit_state = try merge_ui_state.State.init(arena, &edit_fixture.plan);
    var edit_view = View.init(arena, &edit_state, "A.prefab");
    defer edit_view.deinit();
    var edit_screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    edit_view.live_screen = &edit_screen;
    _ = try drawForTest(arena, edit_view.widget(), 80, 10);
    var edit_ctx = eventContext(arena);
    try edit_view.widget().handleEvent(&edit_ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
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
    switch (edit_state.pending.?) {
        .custom => |value| try testing.expectEqualStrings("7", value),
        else => return error.TestUnexpectedResult,
    }

    var action_fixture = try screenPlan(arena);
    var action_state = try merge_ui_state.State.init(arena, &action_fixture.plan);
    var action_view = View.init(arena, &action_state, "A.prefab");
    defer action_view.deinit();
    var action_screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    action_view.live_screen = &action_screen;
    _ = try drawForTest(arena, action_view.widget(), 80, 10);
    var action_ctx = eventContext(arena);
    action_screen.width = 79;
    action_screen.height = 9;

    const blocked_events = [_]vxfw.Event{
        .{ .key_press = .{ .codepoint = 'o', .text = "o" } },
        .{ .mouse = .{
            .col = 0,
            .row = 3,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } },
        .{ .key_press = .{ .codepoint = 'q', .text = "q" } },
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
    try action_view.widget().handleEvent(&action_ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try testing.expect(action_state.pending.? == .take and action_state.pending.?.take == .ours);
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
    try action_view.widget().handleEvent(&action_ctx, .{ .key_press = .{ .codepoint = 'q', .text = "q" } });
    try testing.expectEqual(merge_ui_state.Outcome.aborted, action_state.outcome);
}

test "merge TUI: root delegates an unconsumed editor event only as target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });

    // Before App settles the focus request, root is the target and must delegate once.
    ctx.phase = .at_target;
    ctx.consume_event = false;
    ctx.redraw = false;
    try view.widget().handleEvent(&ctx, .focus_in);
    try testing.expect(!ctx.consume_event);
    try testing.expect(ctx.redraw);

    // After focus settles, the real TextField receives this unconsumed event at target.
    ctx.phase = .at_target;
    ctx.consume_event = false;
    ctx.redraw = false;
    try view.editor.widget().handleEvent(&ctx, .focus_in);
    try testing.expect(!ctx.consume_event);
    try testing.expect(ctx.redraw);

    // App then bubbles to root. A second TextField delivery would set redraw again.
    ctx.phase = .bubbling;
    ctx.redraw = false;
    try view.widget().handleEvent(&ctx, .focus_in);
    try testing.expect(!ctx.consume_event);
    try testing.expect(!ctx.redraw);
}

test "merge TUI: queued grow keeps a navigated editor in the next surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 79, .height = 9 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 79, 9);
    var ctx = eventContext(arena);

    // App accepts these events from the grown live Screen before it performs layout.
    screen.width = 80;
    screen.height = 10;
    for (0..6) |_| {
        ctx.consume_event = false;
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    ctx.consume_event = false;
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    try testing.expectEqual(@as(usize, 6), state.selected_conflict);
    try testing.expectEqual(@as(usize, 2), view.vertical_offset);
    try testing.expectEqualStrings(">", surface.readCell(0, 7).char.grapheme);
    try testing.expectEqualStrings("f6", try cellsText(arena, surface, 7, geometry.property.start, 2));
    try testing.expectEqual(@as(usize, 1), surface.children.len);
    try testing.expect(surface.children[0].surface.widget.eql(view.editor.widget()));
    try testing.expectEqual(@as(i17, 7), surface.children[0].origin.row);
}

test "merge TUI: queued height shrink uses the new footer hit range" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 80, .height = 20 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 80, 20);
    var ctx = eventContext(arena);

    screen.height = 10;
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 75,
        .row = 9,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // At 80x10, row 9 and column 75 are Abort, not conflict 6's Result cell.
    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expect(!view.editing);
}

test "merge TUI: queued height grow normalizes the body hit offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try testing.expectEqual(@as(usize, 3), view.vertical_offset);

    screen.height = 20;
    ctx.consume_event = false;
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 0,
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // The grown body shows every conflict, so its first row must select f0.
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);
}

test "merge TUI: queued width change sets the horizontal wheel bound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try longValuePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 100, .height = 20 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });

    screen.width = 80;
    for (0..100) |_| {
        ctx.consume_event = false;
        try view.widget().handleEvent(&ctx, .{ .mouse = .{
            .col = 0,
            .row = 3,
            .button = .wheel_right,
            .mods = .{},
            .type = .press,
        } });
    }

    // The 20-cell Ours value has a 12-grapheme bound in the new 8-cell column.
    try testing.expectEqual(@as(usize, 12), view.horizontal_offset);
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
            var view = View.init(arena, &state, "A.prefab");
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

test "merge TUI: the exact 80x10 boundary accepts merge actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // Both semantic keys and wheel navigation become active at the full boundary.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try testing.expect(state.pending.? == .take and state.pending.?.take == .ours);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 0,
        .row = 3,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'q', .text = "q" } });
    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
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
    _ = try drawForTest(arena, key_view.widget(), 100, 20);
    _ = try drawForTest(arena, mouse_view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.right,
        .mods = .{ .shift = true },
    } });
    const geometry = Geometry.init(100);
    try mouse_view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
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
    // Scrolling Ours must not shift the unselected Theirs value.
    try testing.expectEqualStrings("BC", try cellsText(arena, surface, 3, geometry.ours.start, 2));
    try testing.expectEqualStrings("AB", try cellsText(arena, surface, 3, geometry.theirs.start, 2));

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.left,
        .mods = .{ .shift = true },
    } });
    try testing.expectEqual(@as(usize, 0), key_view.horizontal_offset);
}

test "merge TUI: Unicode value scrolling clamps and preserves separators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try unicodeValuePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    // Wide and combining graphemes occupy real cells without crossing the separator.
    try testing.expectEqualStrings("漢", surface.readCell(geometry.ours.start, 3).char.grapheme);
    try testing.expectEqual(@as(u8, 2), surface.readCell(geometry.ours.start, 3).char.width);
    try testing.expectEqualStrings("字", surface.readCell(geometry.ours.start + 2, 3).char.grapheme);
    try testing.expectEqualStrings("e\u{301}", surface.readCell(geometry.ours.start + 4, 3).char.grapheme);
    try testing.expectEqual(@as(u8, 1), surface.readCell(geometry.ours.start + 4, 3).char.width);
    try testing.expectEqualStrings("🙂", surface.readCell(geometry.ours.start + 5, 3).char.grapheme);
    try testing.expectEqual(@as(u8, 2), surface.readCell(geometry.ours.start + 5, 3).char.width);
    try testing.expectEqualStrings("│", surface.readCell(geometry.ours.end, 3).char.grapheme);
    try testing.expectEqualStrings("│", surface.readCell(geometry.theirs.end, 3).char.grapheme);

    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{
            .codepoint = vaxis.Key.right,
            .mods = .{ .shift = true },
        } });
    }
    // Skipping three graphemes exposes an exact 8-cell suffix: 🙂終OURS.
    try testing.expectEqual(@as(usize, 3), view.horizontal_offset);
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("🙂", surface.readCell(geometry.ours.start, 3).char.grapheme);
    try testing.expectEqualStrings("S", surface.readCell(geometry.ours.end - 1, 3).char.grapheme);
    try testing.expectEqualStrings("│", surface.readCell(geometry.ours.end, 3).char.grapheme);

    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .mouse = .{
            .col = @intCast(geometry.ours.start),
            .row = 3,
            .button = .wheel_left,
            .mods = .{},
            .type = .press,
        } });
    }
    try testing.expectEqual(@as(usize, 0), view.horizontal_offset);
    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .mouse = .{
            .col = @intCast(geometry.ours.start),
            .row = 3,
            .button = .wheel_right,
            .mods = .{},
            .type = .press,
        } });
    }
    try testing.expectEqual(@as(usize, 3), view.horizontal_offset);
    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{
            .codepoint = vaxis.Key.left,
            .mods = .{ .shift = true },
        } });
    }
    try testing.expectEqual(@as(usize, 0), view.horizontal_offset);
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("漢", surface.readCell(geometry.ours.start, 3).char.grapheme);
    try testing.expectEqualStrings("│", surface.readCell(geometry.ours.end, 3).char.grapheme);
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

    // Row 8 is reserved for status, so f7 must remain on the last body row.
    try testing.expectEqual(@as(usize, 3), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 7), "f7") != null);
}

test "merge TUI: drawing a resized body normalizes selection visibility" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);

    var surface = try drawForTest(arena, view.widget(), 100, 10);
    // A resize with no later input must still place f7 on the final body row.
    try testing.expectEqual(@as(usize, 3), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 7), "f7") != null);

    surface = try drawForTest(arena, view.widget(), 100, 20);
    // Growing enough to show every conflict clamps the obsolete scroll offset to zero.
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 10), "f7") != null);
}

test "merge TUI: status keeps the selected conflict visible and is not selectable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    for (0..5) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '{', .text = "{bad" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    // The five body rows are 3...7; status has its own non-overlapping row 8.
    try testing.expectEqualStrings("f5", try cellsText(arena, surface, 7, geometry.property.start, 2));
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 8), "not valid Unity YAML") != null);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try testing.expectEqual(@as(usize, 4), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.property.start),
        .row = 8,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 4), state.selected_conflict);
}

test "merge TUI: apply quits only after every conflict is ready" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = View.init(arena, &state, "A.prefab");
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
    _ = try drawForTest(arena, view.widget(), 100, 20);
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
