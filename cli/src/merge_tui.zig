const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const merge_tree = @import("merge_tree.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const testing = std.testing;
const vxfw = vaxis.vxfw;

const minimum_size: vxfw.Size = .{ .width = 80, .height = 10 };
const horizontal_padding: u16 = 2;
const vertical_padding: u16 = 1;

const Palette = struct {
    const accent: vaxis.Color = .{ .rgb = .{ 176, 169, 255 } };
    const ours: vaxis.Color = .{ .rgb = .{ 255, 112, 122 } };
    const theirs: vaxis.Color = .{ .rgb = .{ 91, 224, 135 } };
    const conflict: vaxis.Color = .{ .rgb = .{ 241, 196, 74 } };
    const muted: vaxis.Color = .{ .rgb = .{ 150, 151, 168 } };
    const error_text: vaxis.Color = .{ .rgb = .{ 245, 92, 92 } };
    const focus_bg: vaxis.Color = .{ .rgb = .{ 48, 46, 68 } };
    const result_bg: vaxis.Color = .{ .rgb = .{ 31, 32, 43 } };
};

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

const QuitDialogGeometry = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,
    prompt_row: u16,
    detail_row: u16,
    buttons_row: u16,
    cancel: Range,
    quit: Range,

    fn init(width: u16, height: u16) QuitDialogGeometry {
        const dialog_width: u16 = 44;
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
            .quit = .{ .start = left + 25, .end = left + 31 },
        };
    }
};

const EmptyDialogGeometry = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,
    prompt_row: u16,
    detail_row: u16,
    buttons_row: u16,
    cancel: Range,
    use_empty: Range,

    fn init(width: u16, height: u16) EmptyDialogGeometry {
        const dialog_width: u16 = 50;
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
            .use_empty = .{ .start = left + 25, .end = left + 36 },
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
const QuitChoice = enum { cancel, quit };
const EmptyChoice = enum { cancel, use_empty };

fn valueRange(geometry: Geometry, column: ValueColumn) Range {
    return switch (column) {
        .base => geometry.base,
        .ours => geometry.ours,
        .theirs => geometry.theirs,
        .result => geometry.result,
    };
}

fn valueStyle(column: ValueColumn) vaxis.Style {
    return switch (column) {
        .base => .{},
        .ours => .{ .fg = Palette.ours },
        .theirs => .{ .fg = Palette.theirs },
        .result => .{ .bg = Palette.result_bg },
    };
}

fn editsOrMovesTextFieldValue(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.left, .{}) or
        key.matches(vaxis.Key.right, .{}) or
        key.matches(vaxis.Key.home, .{}) or
        key.matches(vaxis.Key.end, .{}) or
        key.matches(vaxis.Key.delete, .{}) or
        key.matches('a', .{ .ctrl = true }) or
        key.matches('b', .{ .ctrl = true }) or
        key.matches('d', .{ .ctrl = true }) or
        key.matches('e', .{ .ctrl = true }) or
        key.matches('f', .{ .ctrl = true }) or
        key.matches('k', .{ .ctrl = true }) or
        key.matches('u', .{ .ctrl = true }) or
        key.matches('w', .{ .ctrl = true }) or
        key.matches('b', .{ .alt = true }) or
        key.matches('d', .{ .alt = true }) or
        key.matches('f', .{ .alt = true }) or
        key.matches(vaxis.Key.left, .{ .alt = true }) or
        key.matches(vaxis.Key.right, .{ .alt = true }) or
        key.matches(vaxis.Key.backspace, .{ .alt = true });
}

pub const View = struct {
    state: *merge_ui_state.State,
    path: []const u8,
    tree: merge_tree.Model,
    editor: vxfw.TextField,
    editing: bool = false,
    replace_on_input: bool = false,
    editor_start_resolution: ?core.merge.Resolution = null,
    editor_changed: bool = false,
    editor_reopened: bool = false,
    horizontal_offset: usize = 0,
    vertical_offset: usize = 0,
    focus_area: FocusArea = .hierarchy,
    selected_value: ValueColumn = .ours,
    quit_dialog: bool = false,
    quit_choice: QuitChoice = .cancel,
    empty_dialog: bool = false,
    empty_choice: EmptyChoice = .cancel,
    last_size: vxfw.Size = .{},
    live_screen: ?*const vaxis.Screen = null,

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
        };
        if (state.outcome == .ready) view.focus_area = .complete;
        return view;
    }

    pub fn deinit(self: *View) void {
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
        if (!inRange(@intCast(mouse.col), Geometry.init(size.width).hierarchy)) return false;
        switch (mouse.button) {
            .wheel_up => self.scrollUp(ctx, size),
            .wheel_down => self.scrollDown(ctx, size),
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
        try self.state.handle(action);
        self.ensureSelectionVisible(size);
        const should_quit = action == .abort and self.state.outcome == .aborted;
        if (should_quit) ctx.quit = true;
        ctx.consumeAndRedraw();
    }

    fn beginResultEdit(
        self: *View,
        ctx: *vxfw.EventContext,
        initial: []const u8,
        replace_on_input: bool,
    ) !void {
        self.editor.clearRetainingCapacity();
        try self.editor.insertSliceAtCursor(initial);
        const previous_val = try self.editor.buf.allocator.dupe(u8, initial);
        self.editor.buf.allocator.free(self.editor.previous_val);
        self.editor.previous_val = previous_val;
        self.editing = true;
        self.replace_on_input = replace_on_input;
        self.editor_start_resolution = self.state.pending;
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
        try self.beginResultEdit(ctx, "", false);
        try self.editor.handleEvent(ctx, .{ .key_press = key });
    }

    fn prepareEditorInput(
        self: *View,
        ctx: *vxfw.EventContext,
        key: vaxis.Key,
    ) !bool {
        if (!self.editing or !self.replace_on_input) return false;
        if (key.matches(vaxis.Key.backspace, .{})) {
            try self.clearInitialResult(ctx);
            return true;
        }
        if (editsOrMovesTextFieldValue(key)) {
            self.replace_on_input = false;
        } else if (key.text != null and key.text.?.len != 0) {
            self.editor.clearRetainingCapacity();
            self.replace_on_input = false;
        }
        return false;
    }

    fn clearInitialResult(self: *View, ctx: *vxfw.EventContext) !void {
        self.editor.clearRetainingCapacity();
        self.replace_on_input = false;
        self.editor_changed = true;
        try self.state.handle(.reopen_result);
        self.editor_reopened = true;
        ctx.consumeAndRedraw();
    }

    fn applyPendingResult(
        self: *View,
        ctx: *vxfw.EventContext,
        size: vxfw.Size,
    ) !void {
        if (self.state.selected_conflict >= self.state.conflict_indices.len) return;
        const operation_index = self.state.conflict_indices[self.state.selected_conflict];
        try self.state.handle(.apply_result);
        self.ensureSelectionVisible(size);
        const applied = self.state.status.len == 0 and
            self.state.plan.operations[operation_index].resolution != .unresolved;
        if (applied) {
            self.editor.clearRetainingCapacity();
            self.editing = false;
            self.replace_on_input = false;
            self.editor_start_resolution = null;
            self.editor_changed = false;
            self.editor_reopened = false;
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

    fn focusHierarchy(self: *View, ctx: *vxfw.EventContext) !void {
        self.focus_area = .hierarchy;
        self.horizontal_offset = 0;
        try self.state.handle(.pane_left);
        ctx.consumeAndRedraw();
    }

    fn focusInspector(self: *View, ctx: *vxfw.EventContext) !void {
        self.focus_area = .inspector;
        self.selected_value = .ours;
        self.horizontal_offset = 0;
        try self.state.handle(.pane_right);
        ctx.consumeAndRedraw();
    }

    fn handleMouseWhileEditing(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) !void {
        if (self.handleHierarchyWheel(ctx, mouse, size)) return;
        if (mouse.type != .press or mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const geometry = Geometry.init(size.width);
        const body = BodyGeometry.init(size.height);
        if (row == body.inspector_rows.start and inRange(col, geometry.result)) return;

        if (!try self.finishEditorForNavigation(ctx)) return;
        try self.handleMouse(ctx, mouse, size);
    }

    fn leaveEditorWithoutApply(self: *View, ctx: *vxfw.EventContext) !void {
        self.editor.clearRetainingCapacity();
        self.state.pending = if (self.editor_reopened) null else self.editor_start_resolution;
        self.state.status = "";
        self.editing = false;
        self.replace_on_input = false;
        self.editor_start_resolution = null;
        self.editor_changed = false;
        self.editor_reopened = false;
        self.focus_area = .inspector;
        self.selected_value = .result;
        try ctx.requestFocus(self.widget());
        ctx.consumeAndRedraw();
    }

    fn reopenResult(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        try self.state.handle(.reopen_result);
        self.editor.clearRetainingCapacity();
        self.editing = false;
        self.replace_on_input = false;
        self.editor_start_resolution = null;
        self.editor_changed = false;
        self.editor_reopened = false;
        try self.focusHierarchy(ctx);
        self.ensureSelectionVisible(size);
        try ctx.requestFocus(self.widget());
    }

    fn leaveResultForHierarchy(self: *View, ctx: *vxfw.EventContext) !void {
        if (self.editor_changed) {
            const input = try self.editor.toOwnedSlice();
            defer self.editor.buf.allocator.free(input);
            if (input.len == 0) return self.reopenResult(ctx, self.eventSize());
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
        if (input.len == 0) {
            try self.reopenResult(ctx, self.eventSize());
            return true;
        }
        try submitCustom(self, ctx, input);
        return !self.editing;
    }

    fn applyEditorAndMove(
        self: *View,
        ctx: *vxfw.EventContext,
        key: vaxis.Key,
        size: vxfw.Size,
    ) !void {
        if (!try self.finishEditorForNavigation(ctx)) return;
        if (key.matches(vaxis.Key.left, .{})) return self.moveLeft(ctx);
        if (key.matches(vaxis.Key.right, .{})) return self.moveRight(ctx);
        if (key.matches(vaxis.Key.up, .{})) return self.moveUp(ctx, size);
        if (key.matches(vaxis.Key.down, .{})) return self.moveDown(ctx, size);
    }

    fn focusComplete(self: *View, ctx: *vxfw.EventContext) void {
        self.focus_area = .complete;
        self.horizontal_offset = 0;
        ctx.consumeAndRedraw();
    }

    fn openQuitDialog(self: *View, ctx: *vxfw.EventContext) void {
        self.quit_dialog = true;
        self.quit_choice = .cancel;
        ctx.consumeAndRedraw();
    }

    fn closeQuitDialog(self: *View, ctx: *vxfw.EventContext) void {
        self.quit_dialog = false;
        self.quit_choice = .cancel;
        ctx.consumeAndRedraw();
    }

    fn openEmptyDialog(self: *View, ctx: *vxfw.EventContext) !void {
        self.empty_dialog = true;
        self.empty_choice = .cancel;
        try ctx.requestFocus(self.widget());
        ctx.consumeAndRedraw();
    }

    fn closeEmptyDialog(self: *View, ctx: *vxfw.EventContext) !void {
        self.empty_dialog = false;
        self.empty_choice = .cancel;
        try ctx.requestFocus(self.editor.widget());
        ctx.consumeAndRedraw();
    }

    fn confirmEmpty(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        self.empty_dialog = false;
        self.empty_choice = .cancel;
        try self.state.handle(.{ .edit_result = "" });
        try self.applyPendingResult(ctx, size);
        if (self.editing) try ctx.requestFocus(self.editor.widget());
    }

    fn handleEmptyDialog(
        self: *View,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
        size: vxfw.Size,
    ) !void {
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'y' or key.codepoint == 'Y') {
                    return self.confirmEmpty(ctx, size);
                }
                if (key.codepoint == 'n' or key.codepoint == 'N' or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    return self.closeEmptyDialog(ctx);
                }
                if (key.matches(vaxis.Key.left, .{})) {
                    self.empty_choice = .cancel;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{})) {
                    self.empty_choice = .use_empty;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    return switch (self.empty_choice) {
                        .cancel => self.closeEmptyDialog(ctx),
                        .use_empty => self.confirmEmpty(ctx, size),
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
                const dialog = EmptyDialogGeometry.init(size.width, size.height);
                const col: u16 = @intCast(mouse.col);
                const row: u16 = @intCast(mouse.row);
                if (row == dialog.buttons_row and inRange(col, dialog.cancel)) {
                    return self.closeEmptyDialog(ctx);
                }
                if (row == dialog.buttons_row and inRange(col, dialog.use_empty)) {
                    return self.confirmEmpty(ctx, size);
                }
                ctx.consumeEvent();
            },
            else => ctx.consumeEvent(),
        }
    }

    fn confirmQuit(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        self.quit_dialog = false;
        try self.dispatch(ctx, .abort, size);
    }

    fn handleQuitDialog(
        self: *View,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
        size: vxfw.Size,
    ) !void {
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'y' or key.codepoint == 'Y') {
                    return self.confirmQuit(ctx, size);
                }
                if (key.codepoint == 'n' or key.codepoint == 'N') {
                    return self.closeQuitDialog(ctx);
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    return self.closeQuitDialog(ctx);
                }
                if (key.matches(vaxis.Key.left, .{})) {
                    self.quit_choice = .cancel;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{})) {
                    self.quit_choice = .quit;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    return switch (self.quit_choice) {
                        .cancel => self.closeQuitDialog(ctx),
                        .quit => self.confirmQuit(ctx, size),
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
                const geometry = QuitDialogGeometry.init(size.width, size.height);
                const col: u16 = @intCast(mouse.col);
                const row: u16 = @intCast(mouse.row);
                if (row == geometry.buttons_row and inRange(col, geometry.cancel)) {
                    return self.closeQuitDialog(ctx);
                }
                if (row == geometry.buttons_row and inRange(col, geometry.quit)) {
                    return self.confirmQuit(ctx, size);
                }
                ctx.consumeEvent();
            },
            else => ctx.consumeEvent(),
        }
    }

    fn selectedOperation(self: *const View) ?*const core.merge.Operation {
        if (self.state.selected_conflict >= self.state.conflict_indices.len) return null;
        const operation_index = self.state.conflict_indices[self.state.selected_conflict];
        return &self.state.plan.operations[operation_index];
    }

    fn selectedText(self: *const View) []const u8 {
        const operation = self.selectedOperation() orelse return "";
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

    fn selectedResultInput(self: *const View) []const u8 {
        const operation = self.selectedOperation() orelse return "";
        const resolution = self.state.pending orelse operation.resolution;
        return switch (resolution) {
            .unresolved => "",
            .take => |side| switch (side) {
                .base => rawSideText(operation.values.base),
                .ours => rawSideText(operation.values.ours),
                .theirs => rawSideText(operation.values.theirs),
            },
            .remove => "<removed>",
            .custom => |value| value,
        };
    }

    fn maxHorizontalOffset(self: *const View, geometry: Geometry) usize {
        const text = self.selectedText();
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

    fn moveLeft(self: *View, ctx: *vxfw.EventContext) !void {
        switch (self.focus_area) {
            .hierarchy => ctx.consumeEvent(),
            .inspector => switch (self.selected_value) {
                .base, .ours => try self.focusHierarchy(ctx),
                .theirs => {
                    self.selected_value = .ours;
                    self.horizontal_offset = 0;
                    ctx.consumeAndRedraw();
                },
                .result => {
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
            .inspector => ctx.consumeEvent(),
            .complete => try self.focusHierarchy(ctx),
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
            .inspector => if (self.state.outcome == .ready) self.focusComplete(ctx) else ctx.consumeEvent(),
            .complete => ctx.consumeEvent(),
        }
    }

    fn activateResult(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        const operation = self.selectedOperation() orelse return;
        const confirmed_empty = switch (operation.resolution) {
            .custom => |value| value.len == 0,
            else => false,
        };
        const input = self.selectedResultInput();
        if (input.len == 0 and !confirmed_empty) {
            try self.beginResultEdit(ctx, input, true);
            return self.openEmptyDialog(ctx);
        }
        try self.applyPendingResult(ctx, size);
    }

    fn activate(self: *View, ctx: *vxfw.EventContext, size: vxfw.Size) !void {
        switch (self.focus_area) {
            .hierarchy => try self.focusInspector(ctx),
            .inspector => switch (self.selected_value) {
                .base, .ours => {
                    try self.state.handle(.choose_ours);
                    try self.applyPendingResult(ctx, size);
                },
                .theirs => {
                    try self.state.handle(.choose_theirs);
                    try self.applyPendingResult(ctx, size);
                },
                .result => try self.activateResult(ctx, size),
            },
            .complete => {
                if (self.state.outcome == .ready) ctx.quit = true;
                ctx.consumeEvent();
            },
        }
    }

    fn handleMouse(
        self: *View,
        ctx: *vxfw.EventContext,
        mouse: vaxis.Mouse,
        size: vxfw.Size,
    ) !void {
        if (self.handleHierarchyWheel(ctx, mouse, size)) return;
        if (mouse.type != .press) return;
        const geometry = Geometry.init(size.width);
        if (mouse.button == .wheel_left) return self.scrollLeft(ctx);
        if (mouse.button == .wheel_right) return self.scrollRight(ctx, size);
        if (mouse.button != .left or mouse.col < 0 or mouse.row < 0) return;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        const footer = FooterGeometry.init(size.width, size.height);
        const body = BodyGeometry.init(size.height);
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
        if (row != body.inspector_rows.start or self.selectedOperation() == null) return;
        if (inRange(col, geometry.ours)) {
            self.focus_area = .inspector;
            self.selected_value = .ours;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            return self.dispatch(ctx, .choose_ours, size);
        }
        if (inRange(col, geometry.theirs)) {
            self.focus_area = .inspector;
            self.selected_value = .theirs;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            return self.dispatch(ctx, .choose_theirs, size);
        }
        if (inRange(col, geometry.result)) {
            self.focus_area = .inspector;
            self.selected_value = .result;
            self.horizontal_offset = 0;
            try self.state.handle(.pane_right);
            ctx.consumeAndRedraw();
            return;
        }
        if (inRange(col, geometry.inspector)) return self.focusInspector(ctx);
    }
};

fn rawSideText(value: ?core.merge.SideValue) []const u8 {
    return if (value) |present| present.bytes else "<removed>";
}

fn sideText(value: ?core.merge.SideValue) []const u8 {
    const text = rawSideText(value);
    return if (text.len == 0) "<empty>" else text;
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
        .custom => |value| if (value.len == 0) "<empty>" else value,
    };
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

    const geometry = Geometry.init(size.width);
    const footer = FooterGeometry.init(size.width, size.height);
    const body = BodyGeometry.init(size.height);
    if (size_changed) self.ensureSelectionVisible(size) else self.clampVerticalOffset(size);
    self.horizontal_offset = @min(self.horizontal_offset, self.maxHorizontalOffset(geometry));
    const unresolved = try std.fmt.allocPrint(
        ctx.arena,
        "{d} unresolved",
        .{self.state.unresolvedCount()},
    );
    const content_start = geometry.hierarchy.start;
    const content_end = geometry.inspector.end;
    writeClipped(surface, content_start, body.header_row, content_end - content_start - 20, self.path);
    writeClipped(surface, content_end - 20, body.header_row, 20, unresolved);
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
    writeClipped(
        surface,
        geometry.inspector.start,
        body.inspector_heading_row,
        geometry.inspector.end - geometry.inspector.start,
        inspector_heading,
    );
    styleRange(surface, body.inspector_heading_row, geometry.inspector, .{ .fg = Palette.muted });
    inline for (.{
        .{ geometry.base, "Base", ValueColumn.base },
        .{ geometry.ours, "Ours", ValueColumn.ours },
        .{ geometry.theirs, "Theirs", ValueColumn.theirs },
        .{ geometry.result, "Result", ValueColumn.result },
    }) |column| {
        writeClipped(
            surface,
            column[0].start,
            body.inspector_labels_row,
            column[0].end - column[0].start,
            column[1],
        );
        var heading_style = valueStyle(column[2]);
        heading_style.fg = Palette.muted;
        styleRange(surface, body.inspector_labels_row, column[0], heading_style);
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

    if (self.selectedOperation()) |operation| {
        const row = body.inspector_rows.start;
        const pending = self.state.pending orelse operation.resolution;
        const columns = .{
            .{ geometry.base, sideText(operation.values.base), ValueColumn.base },
            .{ geometry.ours, sideText(operation.values.ours), ValueColumn.ours },
            .{ geometry.theirs, sideText(operation.values.theirs), ValueColumn.theirs },
            .{ geometry.result, resolutionText(operation, pending), ValueColumn.result },
        };
        inline for (columns) |column| {
            const text = if (column[2] == self.selected_value)
                skipGraphemes(column[1], self.horizontal_offset)
            else
                column[1];
            writeClipped(
                surface,
                column[0].start + 2,
                @intCast(row),
                column[0].end - column[0].start -| 2,
                text,
            );
            styleRange(surface, @intCast(row), column[0], valueStyle(column[2]));
        }
        if (self.focus_area == .inspector) {
            var selected_style = valueStyle(self.selected_value);
            selected_style.bg = Palette.focus_bg;
            styleRange(
                surface,
                @intCast(row),
                valueRange(geometry, self.selected_value),
                selected_style,
            );
            const selected_range = valueRange(geometry, self.selected_value);
            surface.writeCell(selected_range.start, @intCast(row), .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = Palette.accent, .bg = Palette.focus_bg },
            });
        }
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

    if (self.quit_dialog) {
        const dialog = QuitDialogGeometry.init(size.width, size.height);
        for (dialog.top..dialog.bottom) |row| {
            styleRange(
                surface,
                @intCast(row),
                .{ .start = dialog.left, .end = dialog.right },
                .{ .bg = Palette.focus_bg },
            );
        }
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.prompt_row,
            dialog.right - dialog.left - 6,
            "Quit before completion?",
        );
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.detail_row,
            dialog.right - dialog.left - 6,
            "PrefabLens will not write this result.",
        );
        writeClipped(surface, dialog.cancel.start, dialog.buttons_row, 8, "[Cancel]");
        writeClipped(surface, dialog.quit.start, dialog.buttons_row, 6, "[Quit]");
        var cancel_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        var quit_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        if (self.quit_choice == .cancel) {
            cancel_style.fg = Palette.accent;
            cancel_style.reverse = true;
        } else {
            quit_style.fg = Palette.accent;
            quit_style.reverse = true;
        }
        styleRange(surface, dialog.buttons_row, dialog.cancel, cancel_style);
        styleRange(surface, dialog.buttons_row, dialog.quit, quit_style);
    }

    if (self.empty_dialog) {
        const dialog = EmptyDialogGeometry.init(size.width, size.height);
        for (dialog.top..dialog.bottom) |row| {
            styleRange(
                surface,
                @intCast(row),
                .{ .start = dialog.left, .end = dialog.right },
                .{ .bg = Palette.focus_bg },
            );
        }
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.prompt_row,
            dialog.right - dialog.left - 6,
            "Use an empty value?",
        );
        writeClipped(
            surface,
            dialog.left + 3,
            dialog.detail_row,
            dialog.right - dialog.left - 6,
            "This field will contain an empty YAML value.",
        );
        writeClipped(surface, dialog.cancel.start, dialog.buttons_row, 8, "[Cancel]");
        writeClipped(surface, dialog.use_empty.start, dialog.buttons_row, 11, "[Use Empty]");
        var cancel_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        var empty_style: vaxis.Style = .{ .fg = Palette.muted, .bg = Palette.focus_bg };
        if (self.empty_choice == .cancel) {
            cancel_style.fg = Palette.accent;
            cancel_style.reverse = true;
        } else {
            empty_style.fg = Palette.accent;
            empty_style.reverse = true;
        }
        styleRange(surface, dialog.buttons_row, dialog.cancel, cancel_style);
        styleRange(surface, dialog.buttons_row, dialog.use_empty, empty_style);
    }

    if (self.editing and self.focus_area == .inspector and !self.empty_dialog) {
        const editor_row = body.inspector_rows.start;
        if (editor_row < body.inspector_rows.end) {
            self.editor.style = .{ .bg = Palette.focus_bg };
            const editor_size: vxfw.Size = .{
                .width = geometry.result.end - geometry.result.start -| 2,
                .height = 1,
            };
            const child_surface = try self.editor.widget().draw(ctx.withConstraints(
                editor_size,
                vxfw.MaxSize.fromSize(editor_size),
            ));
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

fn submitCustom(
    userdata: ?*anyopaque,
    ctx: *vxfw.EventContext,
    value: []const u8,
) !void {
    const self: *View = @ptrCast(@alignCast(userdata.?));
    const started_empty = if (self.editor_start_resolution) |resolution| switch (resolution) {
        .custom => |start_value| start_value.len == 0,
        else => false,
    } else false;
    if (value.len == 0 and !started_empty) return self.openEmptyDialog(ctx);
    if (self.editor_changed or value.len == 0) {
        try self.state.handle(.{ .edit_result = value });
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
    if (value.len == 0) {
        try self.state.handle(.reopen_result);
        self.editor_reopened = true;
    }
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
    if (ctx.consume_event) return;
    if (self.empty_dialog) switch (event) {
        .key_press, .mouse => return self.handleEmptyDialog(ctx, event, self.eventSize()),
        else => {},
    };
    switch (event) {
        .key_press => |key| if (self.editing and
            (key.matches(vaxis.Key.left, .{}) or
                key.matches(vaxis.Key.right, .{}) or
                key.matches(vaxis.Key.up, .{}) or
                key.matches(vaxis.Key.down, .{})))
        {
            try self.applyEditorAndMove(ctx, key, self.eventSize());
        } else {
            if (try self.prepareEditorInput(ctx, key)) return;
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
    const size = self.eventSize();
    switch (event) {
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
    if (self.empty_dialog) return self.handleEmptyDialog(ctx, event, size);
    if (self.quit_dialog) return self.handleQuitDialog(ctx, event, size);
    if (self.editing) {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    return self.leaveResultForHierarchy(ctx);
                }
                if (try self.prepareEditorInput(ctx, key)) return;
            },
            .mouse => |mouse| if (self.handleHierarchyWheel(ctx, mouse, size)) return,
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
                    .hierarchy => self.openQuitDialog(ctx),
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
            if (self.focus_area == .inspector and self.selected_value == .result and
                key.matches(vaxis.Key.backspace, .{}))
            {
                try self.beginResultEdit(ctx, self.selectedResultInput(), true);
                return self.clearInitialResult(ctx);
            }
            if (self.focus_area == .inspector and self.selected_value == .result and
                key.text != null and key.text.?.len != 0)
                return self.beginTypedEdit(ctx, key);
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
    const tree = try merge_tree.build(allocator, partial, state.plan, state.conflict_indices);
    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, env_map, &tty_buffer);
    defer app.deinit();
    var view = View.init(allocator, state, path, tree);
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

fn deleteEditPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    return core.merge.build(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n  m_After: keep\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_After: keep\n",
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n  m_After: keep\n",
    );
}

fn hierarchyPlan(arena: std.mem.Allocator) !core.merge.BuildResult {
    const base =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Name: Player\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "  - component: {fileID: 114}\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "  m_Children: []\n" ++
        "--- !u!114 &114\n" ++
        "MonoBehaviour:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  maxHp: 100\n";
    const ours = try std.mem.replaceOwned(u8, arena, base, "maxHp: 100", "maxHp: 150");
    const theirs = try std.mem.replaceOwned(u8, arena, base, "maxHp: 100", "maxHp: 200");
    return core.merge.build(arena, base, ours, theirs);
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

fn viewForTest(
    arena: std.mem.Allocator,
    state: *merge_ui_state.State,
    path: []const u8,
    partial: []const u8,
) !View {
    const tree = try merge_tree.build(arena, partial, state.plan, state.conflict_indices);
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

fn surfaceText(arena: std.mem.Allocator, surface: vxfw.Surface) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..surface.size.height) |row| {
        try out.appendSlice(arena, try rowText(arena, surface, @intCast(row)));
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn focusedTreeLabel(surface: vxfw.Surface, geometry: Geometry) ?[]const u8 {
    for (0..surface.size.height) |row| {
        if (!std.mem.eql(
            u8,
            surface.readCell(geometry.hierarchy.start, @intCast(row)).char.grapheme,
            "▌",
        )) continue;
        var first: ?[]const u8 = null;
        var last: ?[]const u8 = null;
        for (geometry.hierarchy.start + 1..geometry.hierarchy.end) |col| {
            const grapheme = surface.readCell(@intCast(col), @intCast(row)).char.grapheme;
            if (first == null and (std.mem.eql(u8, grapheme, "!") or std.mem.eql(u8, grapheme, "✓"))) {
                first = grapheme;
            }
            if (first != null and !std.mem.eql(u8, grapheme, " ")) last = grapheme;
        }
        const start = first orelse return null;
        const end = last orelse return null;
        return start.ptr[0 .. (@intFromPtr(end.ptr) + end.len) - @intFromPtr(start.ptr)];
    }
    return null;
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
    try view.beginResultEdit(ctx, view.selectedResultInput(), true);
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

test "merge TUI: draws the full Unity tree and marks only conflict rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try hierarchyPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "Assets/Player.prefab", tree);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const screen = try surfaceText(arena, surface);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    // This test prevents a conflict-only list from replacing the Unity hierarchy.
    try testing.expect(std.mem.indexOf(u8, screen, "◆ Player") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "components (2)") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "Transform") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "MonoBehaviour") != null);
    try testing.expectEqualStrings(
        "! Max Hp",
        focusedTreeLabel(surface, Geometry.init(100)).?,
    );
    // These coordinates keep the tree dense without flattening its Component rows.
    try testing.expectEqualStrings(
        "└",
        surface.readCell(geometry.hierarchy.start + 3, body.hierarchy_rows.start + 1).char.grapheme,
    );
    try testing.expectEqualStrings(
        "├",
        surface.readCell(geometry.hierarchy.start + 5, body.hierarchy_rows.start + 2).char.grapheme,
    );
    try testing.expectEqualStrings(
        "Transform",
        try cellsText(
            arena,
            surface,
            body.hierarchy_rows.start + 2,
            geometry.hierarchy.start + 8,
            "Transform".len,
        ),
    );
    try testing.expect(vaxis.Color.eql(
        surface.readCell(geometry.hierarchy.start + 15, body.hierarchy_rows.start + 4).style.bg,
        Palette.focus_bg,
    ));
    try testing.expect(vaxis.Color.eql(
        surface.readCell(geometry.hierarchy.start + 5, body.hierarchy_rows.start + 2).style.fg,
        Palette.muted,
    ));
}

test "merge TUI: Escape opens a non-writing quit dialog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);

    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    try testing.expect(view.quit_dialog);
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
    try testing.expect(!cancel_view.quit_dialog);
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

test "merge TUI: a mouse click confirms Quit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    const dialog = QuitDialogGeometry.init(100, 20);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(dialog.quit.start),
        .row = @intCast(dialog.buttons_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
}

test "merge TUI: uses an empty pane gutter and no value dividers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    // Empty space separates the work areas without adding table chrome.
    try testing.expectEqualStrings(
        " ",
        surface.readCell(geometry.hierarchy.end, body.inspector_rows.start).char.grapheme,
    );
    inline for (.{ geometry.base.end, geometry.ours.end, geometry.theirs.end }) |column_end| {
        try testing.expect(!std.mem.eql(
            u8,
            "│",
            surface.readCell(column_end, body.inspector_rows.start).char.grapheme,
        ));
    }
    try testing.expect(vaxis.Color.eql(
        surface.readCell(geometry.result.start, body.inspector_rows.start + 1).style.bg,
        Palette.result_bg,
    ));
}

test "merge TUI: hides the Result editor while the tree owns focus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    // This test prevents the Result caret from appearing outside Inspector focus.
    try testing.expectEqual(@as(usize, 0), surface.children.len);
    try testing.expect(view.focus_area == .hierarchy);
}

test "merge TUI: keeps resolved conflicts in the tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try hierarchyPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "Assets/Player.prefab", tree);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try state.handle(.choose_ours);
    try view.dispatch(&ctx, .apply_result, .{ .width = 100, .height = 20 });
    const surface = try drawForTest(arena, view.widget(), 100, 20);

    // This test prevents an applied row from disappearing from the fixed session tree.
    try testing.expectEqualStrings(
        "✓ Max Hp",
        focusedTreeLabel(surface, Geometry.init(100)).?,
    );
}

test "merge TUI: context clicks and hierarchy wheel preserve the selected conflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 2,
        .row = 1,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    for (0..4) |_| {
        try view.widget().handleEvent(&ctx, .{ .mouse = .{
            .col = 2,
            .row = 3,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } });
    }
    _ = try drawForTest(arena, view.widget(), 80, 10);

    // These events must not move conflict selection or Inspector focus.
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expectEqual(@as(usize, 4), view.vertical_offset);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
}

test "merge TUI: hierarchy wheel preserves the focused Result editor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var view = View.init(arena, &state, "A.prefab", tree);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try beginEditingForTest(&view, &ctx);
    const focused_surface = try drawForTest(arena, view.widget(), 80, 10);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = 'a', .text = "abcd" } },
    );
    const caret_before = view.editor.byteOffsetToCursor();
    const focus_commands_before = ctx.cmds.items.len;
    const selected_before = state.selected_conflict;

    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .mouse = .{
            .col = 2,
            .row = 3,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } },
    );

    // This test prevents editor event routing from swallowing a Hierarchy wheel event or moving the caret.
    try testing.expect(ctx.consume_event);
    try testing.expectEqual(@as(usize, 1), view.vertical_offset);
    try testing.expectEqual(selected_before, state.selected_conflict);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
    try testing.expect(view.editing);
    try testing.expectEqual(caret_before, view.editor.byteOffsetToCursor());
    try testing.expectEqual(focus_commands_before, ctx.cmds.items.len);
    switch (ctx.cmds.items[focus_commands_before - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.editor.widget())),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: entering Inspector resets a retained Result selection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try view.focusHierarchy(&ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);

    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .ours);
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

test "merge TUI: an invalid Result blocks an outside click" {
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
    try beginEditingForTest(&view, &ctx);
    var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '{', .text = "{bad" } },
    );
    focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .mouse = .{
            .col = @intCast(geometry.hierarchy.start),
            .row = @intCast(body.hierarchy_rows.start + 1),
            .button = .left,
            .mods = .{},
            .type = .press,
        } },
    );

    try testing.expect(view.editing);
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("{bad", value);
}

test "merge TUI: draws two panes and sparse value columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "Assets/Prefabs/Robot.prefab", fixture.partial);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    const title = try rowText(arena, surface, body.header_row);
    const pane_titles = try rowText(arena, surface, body.inspector_heading_row);

    // These assertions catch drift between the shared column geometry and renderer.
    try testing.expect(std.mem.indexOf(u8, title, "Assets/Prefabs/Robot.prefab") != null);
    try testing.expect(std.mem.indexOf(u8, title, "2 unresolved") != null);
    try testing.expect(std.mem.indexOf(u8, pane_titles, "Hierarchy") == null);
    try testing.expect(std.mem.indexOf(u8, pane_titles, "Inspector") == null);
    try testing.expectEqualStrings("Base", try cellsText(arena, surface, body.inspector_labels_row, geometry.base.start, "Base".len));
    try testing.expectEqualStrings("Ours", try cellsText(arena, surface, body.inspector_labels_row, geometry.ours.start, "Ours".len));
    try testing.expectEqualStrings("Theirs", try cellsText(arena, surface, body.inspector_labels_row, geometry.theirs.start, "Theirs".len));
    try testing.expectEqualStrings("Result", try cellsText(arena, surface, body.inspector_labels_row, geometry.result.start, "Result".len));
    try testing.expect(std.mem.indexOf(u8, pane_titles, "Rigidbody › Mass") != null);
    try testing.expectEqualStrings(
        " ",
        surface.readCell(geometry.hierarchy.end, body.inspector_labels_row).char.grapheme,
    );
}

test "merge TUI: the normal status and footer rows are empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const body = BodyGeometry.init(20);
    const footer = FooterGeometry.init(100, 20);
    const help = try rowText(arena, surface, body.status_row);
    const actions = try rowText(arena, surface, footer.row);

    try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, help, " ").len);
    try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, actions, " ").len);
}

test "merge TUI: side values and primary actions use distinct colors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const surface = try drawForTest(arena, view.widget(), 100, 20);
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    const ours = surface.readCell(geometry.ours.start, body.inspector_rows.start).style.fg;
    const theirs = surface.readCell(geometry.theirs.start, body.inspector_rows.start).style.fg;

    // Distinct colors prevent both sides from becoming one undifferentiated value table.
    try testing.expect(ours != .default);
    try testing.expect(theirs != .default);
    try testing.expect(!vaxis.Color.eql(ours, theirs));
    try testing.expect(surface.readCell(80, body.header_row).style.fg != .default);
}

test "merge TUI: focus styling moves between the tree and values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // Only the active work area receives the strong focus rail and background.
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
    try testing.expect(vaxis.Color.eql(surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).style.bg, Palette.focus_bg));
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
    try testing.expect(!vaxis.Color.eql(surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).style.bg, Palette.focus_bg));
    try testing.expectEqualStrings("▌", surface.readCell(geometry.ours.start, body.inspector_rows.start).char.grapheme);
    try testing.expect(vaxis.Color.eql(surface.readCell(geometry.ours.start, body.inspector_rows.start).style.bg, Palette.focus_bg));
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
}

test "merge TUI: selected row marker follows up and down navigation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);

    // The marker identifies the row that side-selection keys will change.
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 3).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 3).char.grapheme);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
}

test "merge TUI: selected value style follows Ours Theirs and Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.ours.start, body.inspector_rows.start).char.grapheme);
    try testing.expect(vaxis.Color.eql(surface.readCell(geometry.ours.start, body.inspector_rows.start).style.bg, Palette.focus_bg));
    try testing.expect(!vaxis.Color.eql(surface.readCell(geometry.theirs.start, body.inspector_rows.start).style.bg, Palette.focus_bg));

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expect(!vaxis.Color.eql(surface.readCell(geometry.ours.start, body.inspector_rows.start).style.bg, Palette.focus_bg));
    try testing.expectEqualStrings("▌", surface.readCell(geometry.theirs.start, body.inspector_rows.start).char.grapheme);
    try testing.expect(vaxis.Color.eql(surface.readCell(geometry.theirs.start, body.inspector_rows.start).style.bg, Palette.focus_bg));

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.result.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    // Result focus must stay visible before keyboard input starts the editor.
    try testing.expectEqual(@as(usize, 0), surface.children.len);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.result.start, body.inspector_rows.start).char.grapheme);
    try testing.expect(vaxis.Color.eql(surface.readCell(geometry.result.start, body.inspector_rows.start).style.bg, Palette.focus_bg));
}

test "merge TUI: hierarchy movement does not move the inspector cursor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);

    var surface = try drawForTest(arena, view.widget(), 80, 10);
    // The hierarchy owns the initial cursor, so the Inspector has no focus marker.
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.result.start, body.inspector_rows.start).char.grapheme, "▌"));

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    // A hierarchy move can change inspector data, but it cannot move inspector focus.
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.result.start, body.inspector_rows.start).char.grapheme, "▌"));

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.ours.start, body.inspector_rows.start).char.grapheme);
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.result.start, body.inspector_rows.start).char.grapheme, "▌"));
}

test "merge TUI: arrows and Enter apply Ours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    // Enter completes the side choice without a separate Apply action.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(!ctx.quit);

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);
    // The next unresolved conflict receives the hierarchy focus.
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 3).char.grapheme);
}

test "merge TUI: Escape in the inspector returns to the hierarchy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);
}

test "merge TUI: Escape in Result returns to the hierarchy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try testing.expectEqualStrings("▌", surface.readCell(geometry.hierarchy.start, body.hierarchy_rows.start + 2).char.grapheme);
    try testing.expect(!view.editing);
}

test "merge TUI: letter shortcuts do not decide a merge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const keys = "otaq";

    for (keys) |key| {
        var fixture = try screenPlan(arena);
        var state = try merge_ui_state.State.init(arena, &fixture.plan);
        var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
        defer view.deinit();
        _ = try drawForTest(arena, view.widget(), 80, 10);
        var ctx = eventContext(arena);

        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = key } });

        // Letter keys cannot bypass the visible controls and their Enter action.
        try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
        try testing.expectEqualStrings("", state.status);
        try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
        try testing.expect(!ctx.quit);
    }
}

test "merge TUI: inspector shows only the selected conflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);

    var surface = try drawForTest(arena, view.widget(), 100, 20);
    // The inspector is a detail view, so the second hierarchy row has no second detail row.
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.inspector_heading_row), "Rigidbody › Mass") != null);
    try testing.expectEqualStrings("      ", try cellsText(arena, surface, body.inspector_rows.start + 1, geometry.inspector.start, "m_Drag".len));

    var ctx = eventContext(arena);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try drawForTest(arena, view.widget(), 100, 20);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.inspector_heading_row), "Rigidbody › Drag") != null);
}

test "merge TUI: clips a long value before the next column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
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
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    const surface = try vxfw.Surface.init(arena, view.widget(), .{ .width = 65535, .height = 1 });
    surface.writeCell(65534, 0, .{ .char = .{ .grapheme = "│", .width = 1 } });

    // A two-cell grapheme cannot fit in the final cell and must not overflow u16.
    writeClipped(surface, 65534, 0, 1, "🙂");

    try testing.expectEqualStrings("│", surface.readCell(65534, 0).char.grapheme);
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

test "merge TUI: keyboard moves panes and rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // Arrow navigation keeps the state pane aligned with the visible focus area.
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try testing.expectEqual(merge_ui_state.Pane.inspector, state.pane);
    try pressKeyForTest(&view, &ctx, vaxis.Key.left);
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expect(!ctx.quit);
}

test "merge TUI: mouse keeps hierarchy selection independent from inspector focus" {
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

    // A hierarchy click selects the detail source without activating an inspector value.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.hierarchy.start),
        .row = @intCast(body.hierarchy_rows.start + 3),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(merge_ui_state.Pane.hierarchy, state.pane);
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.inspector.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(merge_ui_state.Pane.inspector, state.pane);
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
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

test "merge TUI: typing in Result replaces the current value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '1',
        .text = "100",
    } });

    // Direct input must replace the displayed Result without a separate editor action.
    try testing.expect(view.editing);
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("100", value);
}

test "merge TUI: Enter in Result applies the pending value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try state.handle(.choose_ours);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Result Enter must apply the choice instead of opening an editor.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(view.focus_area == .hierarchy);
}

test "merge TUI: submitted custom text applies in one Enter action" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '1',
        .text = "100",
    } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // A TextField submit must edit and apply without a second Enter action.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(view.focus_area == .hierarchy);
}

test "merge TUI: invalid Result stays editable after Enter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '{',
        .text = "{bad",
    } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Invalid YAML must keep the submitted buffer and Result focus for correction.
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    try testing.expect(view.editing);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("{bad", value);
}

test "merge TUI: Escape keeps the pending value that existed before editing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try state.handle(.choose_theirs);
    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '{',
        .text = "{bad",
    } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);

    // Escape must discard an invalid custom value and restore the earlier side choice.
    try testing.expect(state.pending.? == .take);
    try testing.expect(state.pending.?.take == .theirs);
    try testing.expectEqualStrings("", state.status);
    try testing.expect(!view.editing);
    try testing.expect(view.focus_area == .hierarchy);
    try testing.expect(view.selected_value == .result);
}

test "merge TUI: Enter can replace a resolved choice" {
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
    try state.handle(.{ .select_conflict = 0 });
    try focusResultForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '1',
        .text = "100",
    } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Reapplying a resolved row must close the editor when the count cannot decrease.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(!view.editing);
    try testing.expect(view.focus_area == .hierarchy);
    switch (fixture.plan.operations[operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("100", value),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: draws the active TextField in the Result cell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '1', .text = "1.25" } });
    const surface = try drawForTest(arena, view.widget(), 100, 20);

    // Omitting the TextField child would leave editing invisible to the user.
    try testing.expectEqual(@as(usize, 1), surface.children.len);
    try testing.expectEqual(@as(i17, Geometry.init(100).result.start + 2), surface.children[0].origin.col);
    try testing.expectEqual(@as(i17, BodyGeometry.init(20).inspector_rows.start), surface.children[0].origin.row);
    try testing.expect(std.mem.startsWith(u8, try rowText(arena, surface.children[0].surface, 0), "1.25"));
}

test "merge TUI: Escape cancels TextField input and restores root focus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    const focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '9', .text = "99" } },
    );
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.escape } },
    );

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
    const operation_index = state.conflict_indices[0];
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    var ctx = eventContext(arena);

    _ = try drawForTest(arena, view.widget(), 80, 10);
    try beginEditingForTest(&view, &ctx);
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
    switch (fixture.plan.operations[operation_index].resolution) {
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

test "merge TUI: root delegates an unconsumed editor event only as target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    try beginEditingForTest(&view, &ctx);

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
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
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
    try beginEditingForTest(&view, &ctx);

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);
    const selected_tree_row = view.tree.rowForConflict(state.selected_conflict).?;
    const selected_screen_row = body.hierarchy_rows.start + selected_tree_row - view.vertical_offset;
    try testing.expectEqual(@as(usize, 6), state.selected_conflict);
    try testing.expectEqual(@as(usize, 4), view.vertical_offset);
    try testing.expectEqualStrings(" ", surface.readCell(geometry.hierarchy.start, @intCast(selected_screen_row)).char.grapheme);
    try testing.expect(vaxis.Color.eql(
        surface.readCell(geometry.hierarchy.start, @intCast(selected_screen_row)).style.bg,
        Palette.result_bg,
    ));
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.inspector_heading_row), "F6") != null);
    try testing.expectEqual(@as(usize, 1), surface.children.len);
    try testing.expect(surface.children[0].surface.widget.eql(view.editor.widget()));
    try testing.expectEqual(@as(i17, body.inspector_rows.start), surface.children[0].origin.row);
}

test "merge TUI: queued height shrink does not expose a hidden footer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
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

    // The normal footer is empty, so a stale bottom-row click cannot change the merge.
    try testing.expectEqual(merge_ui_state.Outcome.active, state.outcome);
    try testing.expect(!ctx.quit);
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expect(!view.editing);
}

test "merge TUI: queued height grow normalizes the body hit offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 80, .height = 10 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try testing.expectEqual(@as(usize, 5), view.vertical_offset);

    screen.height = 20;
    ctx.consume_event = false;
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(20);
    const first_conflict_row = view.tree.rowForConflict(0).?;
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.hierarchy.start),
        .row = @intCast(body.hierarchy_rows.start + first_conflict_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // The grown body shows every tree row, so the first conflict is directly selectable.
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);
}

test "merge TUI: queued width change sets the horizontal wheel bound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try longValuePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    var screen: vaxis.Screen = .{ .width = 100, .height = 20 };
    view.live_screen = &screen;
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);

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

    // The 20-cell Ours value has a 9-grapheme bound in the 11-cell content area.
    try testing.expectEqual(@as(usize, 9), view.horizontal_offset);
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

test "merge TUI: the exact 80x10 boundary accepts merge actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // Enter actions and wheel scrolling become active at the full boundary.
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 0,
        .row = 3,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!ctx.quit);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
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
    var key_view = try viewForTest(arena, &key_state, "A.prefab", key_fixture.partial);
    defer key_view.deinit();
    var mouse_view = try viewForTest(arena, &mouse_state, "A.prefab", mouse_fixture.partial);
    defer mouse_view.deinit();
    _ = try drawForTest(arena, key_view.widget(), 100, 20);
    _ = try drawForTest(arena, mouse_view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&key_view, &ctx, vaxis.Key.right);
    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.right,
        .mods = .{ .shift = true },
    } });
    const geometry = Geometry.init(100);
    const body = BodyGeometry.init(20);
    try mouse_view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.ours.start),
        .row = @intCast(body.inspector_rows.start),
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
    try testing.expectEqualStrings("BC", try cellsText(arena, surface, body.inspector_rows.start, geometry.ours.start + 2, 2));
    try testing.expectEqualStrings("AB", try cellsText(arena, surface, body.inspector_rows.start, geometry.theirs.start + 2, 2));

    try key_view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = vaxis.Key.left,
        .mods = .{ .shift = true },
    } });
    try testing.expectEqual(@as(usize, 0), key_view.horizontal_offset);
}

test "merge TUI: Unicode value scrolling clamps and preserves value boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try unicodeValuePlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    var surface = try drawForTest(arena, view.widget(), 80, 10);
    // Wide and combining graphemes occupy real cells without crossing a value boundary.
    try testing.expectEqualStrings("漢", surface.readCell(geometry.ours.start + 2, body.inspector_rows.start).char.grapheme);
    try testing.expectEqual(@as(u8, 2), surface.readCell(geometry.ours.start + 2, body.inspector_rows.start).char.width);
    try testing.expectEqualStrings("字", surface.readCell(geometry.ours.start + 4, body.inspector_rows.start).char.grapheme);
    try testing.expectEqualStrings("e\u{301}", surface.readCell(geometry.ours.start + 6, body.inspector_rows.start).char.grapheme);
    try testing.expectEqual(@as(u8, 1), surface.readCell(geometry.ours.start + 6, body.inspector_rows.start).char.width);
    try testing.expectEqualStrings("🙂", surface.readCell(geometry.ours.start + 7, body.inspector_rows.start).char.grapheme);
    try testing.expectEqual(@as(u8, 2), surface.readCell(geometry.ours.start + 7, body.inspector_rows.start).char.width);
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.ours.end, body.inspector_rows.start).char.grapheme, "│"));
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.theirs.end, body.inspector_rows.start).char.grapheme, "│"));

    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{
            .codepoint = vaxis.Key.right,
            .mods = .{ .shift = true },
        } });
    }
    // Skipping one grapheme exposes a suffix that fits the content area.
    try testing.expectEqual(@as(usize, 1), view.horizontal_offset);
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("字", surface.readCell(geometry.ours.start + 2, body.inspector_rows.start).char.grapheme);
    try testing.expectEqualStrings("S", surface.readCell(geometry.ours.end - 1, body.inspector_rows.start).char.grapheme);
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.ours.end, body.inspector_rows.start).char.grapheme, "│"));

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
    try testing.expectEqual(@as(usize, 1), view.horizontal_offset);
    for (0..100) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{
            .codepoint = vaxis.Key.left,
            .mods = .{ .shift = true },
        } });
    }
    try testing.expectEqual(@as(usize, 0), view.horizontal_offset);
    surface = try drawForTest(arena, view.widget(), 80, 10);
    try testing.expectEqualStrings("漢", surface.readCell(geometry.ours.start + 2, body.inspector_rows.start).char.grapheme);
    try testing.expect(!std.mem.eql(u8, surface.readCell(geometry.ours.end, body.inspector_rows.start).char.grapheme, "│"));
}

test "merge TUI: wheel moves the display offset and resize requests redraw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    // Real wheel and winsize events must stay inside the event loop.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = 2,
        .row = 3,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expectEqual(@as(usize, 1), view.vertical_offset);
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
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 10);
    var ctx = eventContext(arena);

    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    const surface = try drawForTest(arena, view.widget(), 100, 10);
    const body = BodyGeometry.init(10);

    // The status row stays separate, so f7 must remain on the last hierarchy row.
    try testing.expectEqual(@as(usize, 5), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.hierarchy_rows.end - 1), "F7") != null);
}

test "merge TUI: drawing a resized body normalizes selection visibility" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    for (0..7) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);

    var surface = try drawForTest(arena, view.widget(), 100, 10);
    const small_body = BodyGeometry.init(10);
    // A resize with no later input must still place f7 on the final body row.
    try testing.expectEqual(@as(usize, 5), view.vertical_offset);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, small_body.hierarchy_rows.end - 1), "F7") != null);

    surface = try drawForTest(arena, view.widget(), 100, 20);
    const large_body = BodyGeometry.init(20);
    const selected_tree_row = view.tree.rowForConflict(7).?;
    // Growing enough to show every conflict clamps the obsolete scroll offset to zero.
    try testing.expectEqual(@as(usize, 0), view.vertical_offset);
    try testing.expect(std.mem.indexOf(
        u8,
        try rowText(arena, surface, @intCast(large_body.hierarchy_rows.start + selected_tree_row)),
        "F7",
    ) != null);
}

test "merge TUI: status keeps the selected conflict visible and is not selectable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try tallPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 80, 10);
    var ctx = eventContext(arena);

    for (0..5) |_| {
        try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    }
    try beginEditingForTest(&view, &ctx);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '{', .text = "{bad" } });
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try pressKeyForTest(&view, &ctx, vaxis.Key.down);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    const surface = try drawForTest(arena, view.widget(), 80, 10);
    const geometry = Geometry.init(80);
    const body = BodyGeometry.init(10);
    const selected_tree_row = view.tree.rowForConflict(5).?;
    const selected_screen_row = body.hierarchy_rows.start + selected_tree_row - view.vertical_offset;
    // The Inspector and selected tree item stay visible above the separate status row.
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.inspector_heading_row), "F5") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, @intCast(selected_screen_row)), "F5") != null);
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, body.status_row), "not valid Unity YAML") != null);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.inspector.start),
        .row = @intCast(body.status_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expectEqual(@as(usize, 5), state.selected_conflict);
    try testing.expect(view.editing);
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

test "merge TUI: the normal screen has no action footer or key help" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();

    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    inline for (.{ "Apply result", "Quit", "Move", "Actions", "Enter Apply", "Type Result" }) |text| {
        try testing.expect(std.mem.indexOf(u8, screen, text) == null);
    }
}

test "merge TUI: conflict markers use status colors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try hierarchyPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();

    var surface = try drawForTest(arena, view.widget(), 100, 20);
    var conflict_color: ?vaxis.Color = null;
    for (0..surface.size.height) |row| {
        for (0..Geometry.init(100).hierarchy.end) |col| {
            if (std.mem.eql(u8, surface.readCell(@intCast(col), @intCast(row)).char.grapheme, "!")) {
                conflict_color = surface.readCell(@intCast(col), @intCast(row)).style.fg;
            }
        }
    }
    try testing.expect(conflict_color != null);
    try testing.expect(vaxis.Color.eql(conflict_color.?, Palette.conflict));

    var ctx = eventContext(arena);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    surface = try drawForTest(arena, view.widget(), 100, 20);
    var resolved_color: ?vaxis.Color = null;
    for (0..surface.size.height) |row| {
        for (0..Geometry.init(100).hierarchy.end) |col| {
            if (std.mem.eql(u8, surface.readCell(@intCast(col), @intCast(row)).char.grapheme, "✓")) {
                resolved_color = surface.readCell(@intCast(col), @intCast(row)).style.fg;
            }
        }
    }
    try testing.expect(resolved_color != null);
    try testing.expect(vaxis.Color.eql(resolved_color.?, Palette.theirs));
}

test "merge TUI: navigation does not exit a ready view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const yaml = "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n";
    var fixture = try core.merge.build(arena, yaml, yaml, yaml);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    // A ready model can still receive navigation. Only Complete or Quit stops the loop.
    try view.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!ctx.quit);
}

test "merge TUI: arrows and Enter select Quit in the dialog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try pressKeyForTest(&view, &ctx, vaxis.Key.escape);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Quit restores the initial resolutions before it terminates the event loop.
    try testing.expectEqual(merge_ui_state.Outcome.aborted, state.outcome);
    try testing.expect(ctx.quit);
}

test "merge TUI: mouse clicks Complete to exit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);
    const footer = FooterGeometry.init(100, 20);

    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, vaxis.Key.right);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try testing.expectEqual(merge_ui_state.Outcome.ready, state.outcome);
    try testing.expect(!ctx.quit);

    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(footer.complete.start),
        .row = @intCast(footer.row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expect(ctx.quit);
}

test "merge TUI: clicking Result focuses it without editing" {
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

    // A mouse click must move focus without showing the text cursor.
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(Geometry.init(100).result.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    const surface = try drawForTest(arena, view.widget(), 100, 20);

    try testing.expectEqual(merge_ui_state.Pane.inspector, state.pane);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
    try testing.expect(!view.editing);
    try testing.expectEqual(@as(usize, 0), surface.children.len);
    try testing.expect(ctx.consume_event);
    try testing.expect(ctx.redraw);
}

test "merge TUI: failed Result start keeps editor valid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const tree = try merge_tree.build(arena, fixture.partial, &fixture.plan, state.conflict_indices);
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var view = View.init(failing_allocator.allocator(), &state, "A.prefab", tree);
    defer view.deinit();
    view.editor.previous_val = try view.editor.buf.allocator.dupe(u8, "old");
    try view.editor.insertSliceAtCursor("capacity");
    view.editor.clearRetainingCapacity();
    var ctx = eventContext(arena);

    // The old value must keep its allocation until the replacement allocation succeeds.
    try testing.expectError(error.OutOfMemory, view.beginResultEdit(&ctx, "new", true));
    try testing.expect(failing_allocator.has_induced_failure);
    try testing.expectEqualStrings("old", view.editor.previous_val);
    try testing.expect(!view.editing);
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

test "merge TUI: typing after a Result click replaces the displayed value" {
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

    try state.handle(.choose_ours);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(geometry.result.start),
        .row = @intCast(body.inspector_rows.start),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try testing.expect(!view.editing);
    try view.widget().handleEvent(&ctx, .{ .key_press = .{
        .codepoint = '1',
        .text = "100",
    } });

    // Keyboard input must start editing and replace the value that the mouse focused.
    try testing.expect(view.editing);
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("100", value);
}

test "merge TUI: focused Result input replaces the displayed value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try state.handle(.choose_ours);
    try beginEditingForTest(&view, &ctx);
    const focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '1', .text = "100" } },
    );

    // This test prevents the focused TextField from appending input before the parent can replace its value.
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("100", value);
}

test "merge TUI: an arrow applies Result input before navigation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

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
        .{ .key_press = .{ .codepoint = vaxis.Key.right } },
    );

    // One arrow applies the current value and then performs normal navigation.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    switch (fixture.plan.operations[state.conflict_indices[0]].resolution) {
        .custom => |value| try testing.expectEqualStrings("100", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!view.editing);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .ours);
}

test "merge TUI: clearing Result and moving reopens the conflict" {
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
    try state.handle(.{ .select_conflict = 0 });
    try beginEditingForTest(&view, &ctx);
    var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    for (0..2) |_| {
        try routeFocusedEventForTest(
            arena,
            focused_surface,
            view.editor.widget(),
            &ctx,
            .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
        );
        focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    }
    // The hierarchy must show the new unresolved state before focus moves away.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.left } },
    );

    // A cleared draft means that the user wants to decide this conflict later.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expect(view.focus_area == .hierarchy);
}

test "merge TUI: clearing Result and pressing Escape reopens the conflict" {
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
    try state.handle(.{ .select_conflict = 0 });
    try beginEditingForTest(&view, &ctx);
    var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    for (0..2) |_| {
        try routeFocusedEventForTest(
            arena,
            focused_surface,
            view.editor.widget(),
            &ctx,
            .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
        );
        focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    }
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.escape } },
    );

    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.focus_area == .hierarchy);
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

test "merge TUI: the empty value dialog owns keyboard focus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Dialog focus keeps its keys away from the hidden Result editor.
    try testing.expect(ctx.cmds.items.len != 0);
    switch (ctx.cmds.items[ctx.cmds.items.len - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.widget())),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: the empty value dialog handles captured keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    const dialog_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        dialog_surface,
        view.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.right } },
    );

    // The modal must handle capture before Result navigation handles the key.
    try testing.expect(view.empty_choice == .use_empty);
    try testing.expect(view.empty_dialog);
    try testing.expect(view.editing);
}

test "merge TUI: the empty value dialog redraws after a resize" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    const dialog_surface = try drawForTest(arena, view.widget(), 100, 20);
    ctx.redraw = false;
    try routeFocusedEventForTest(
        arena,
        dialog_surface,
        view.widget(),
        &ctx,
        .{ .winsize = .{ .rows = 24, .cols = 100, .x_pixel = 0, .y_pixel = 0 } },
    );

    // Resize must reach the root draw path while the modal is open.
    try testing.expect(ctx.redraw);
    try testing.expect(view.empty_dialog);
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

test "merge TUI: n and Escape cancel the empty value dialog" {
    const cancel_keys = [_]u21{ 'n', vaxis.Key.escape };
    for (cancel_keys) |cancel_key| {
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
        try pressKeyForTest(&view, &ctx, cancel_key);

        // Both keys must return to the draft without resolving the conflict.
        try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
        try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
        try testing.expect(view.editing);
        const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
        try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") == null);
    }
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

test "merge TUI: Left returns the empty value dialog to Cancel" {
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
    try pressKeyForTest(&view, &ctx, vaxis.Key.left);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Left must restore the safe action before Enter applies a choice.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
}

test "merge TUI: y applies an empty Result" {
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
    try pressKeyForTest(&view, &ctx, 'y');

    switch (fixture.plan.operations[operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(!view.editing);
}

test "merge TUI: a rejected empty Result restores editor focus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const first_operation = fixture.plan.operations[state.conflict_indices[0]];
    const dependency_id = fixture.plan.operations[state.conflict_indices[1]].atomic_id;
    for (fixture.plan.atomic_operations) |*atomic| {
        if (atomic.id == first_operation.atomic_id) {
            atomic.dependencies = try arena.dupe(u32, &.{dependency_id});
            break;
        }
    }
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);
    try pressKeyForTest(&view, &ctx, 'y');

    // A failed apply must restore the Result editor after the modal closes.
    try testing.expectEqualStrings("Resolve dependent conflicts first.", state.status);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
    switch (ctx.cmds.items[ctx.cmds.items.len - 1]) {
        .request_focus => |widget| try testing.expect(widget.eql(view.editor.widget())),
        else => return error.TestUnexpectedResult,
    }
}

test "merge TUI: a mouse click applies an empty Result" {
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
    const dialog = EmptyDialogGeometry.init(100, 20);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(dialog.use_empty.start),
        .row = @intCast(dialog.buttons_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    switch (fixture.plan.operations[operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expect(!view.editing);
}

test "merge TUI: a mouse click cancels the empty value dialog" {
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
    const dialog = EmptyDialogGeometry.init(100, 20);
    try view.widget().handleEvent(&ctx, .{ .mouse = .{
        .col = @intCast(dialog.cancel.start),
        .row = @intCast(dialog.buttons_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // Cancel must close the dialog and keep the conflict unresolved.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") == null);
}

test "merge TUI: Enter asks when the focused Result is empty" {
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

    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // Result focus must not bypass the empty value confirmation.
    try testing.expect(fixture.plan.operations[operation_index].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(view.editing);
    try testing.expect(view.focus_area == .inspector);
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") != null);
}

test "merge TUI: Enter does not ask again for a confirmed empty Result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    const operation_index = state.conflict_indices[0];
    try state.handle(.{ .edit_result = "" });
    try state.handle(.apply_result);
    try state.handle(.{ .select_conflict = 0 });
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    // A confirmed empty value does not need a second confirmation.
    switch (fixture.plan.operations[operation_index].resolution) {
        .custom => |value| try testing.expectEqualStrings("", value),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(view.focus_area == .hierarchy);
    try testing.expect(!view.editing);
    const screen = try surfaceText(arena, try drawForTest(arena, view.widget(), 100, 20));
    try testing.expect(std.mem.indexOf(u8, screen, "Use an empty value?") == null);
}

test "merge TUI: invalid Result input blocks arrow navigation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

    try beginEditingForTest(&view, &ctx);
    var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = '{', .text = "{bad" } },
    );
    focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.right } },
    );

    // Invalid YAML keeps Result active so the user can correct the value.
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    try testing.expect(view.editing);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
}

test "merge TUI: Enter on Ours resolves the conflict and selects the next row" {
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

    // This choice is a complete decision. A second Apply action is not necessary.
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(view.focus_area == .hierarchy);
    try testing.expect(!ctx.quit);
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

test "merge TUI: the first Backspace clears a prefilled Result" {
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
    try state.handle(.{ .select_conflict = 0 });
    try beginEditingForTest(&view, &ctx);
    const focused_surface = try drawForTest(arena, view.widget(), 100, 20);
    try routeFocusedEventForTest(
        arena,
        focused_surface,
        view.editor.widget(),
        &ctx,
        .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
    );

    // Result starts as one selected value, so one Backspace must clear all of it.
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("", value);
    try testing.expect(fixture.plan.operations[state.conflict_indices[0]].resolution == .unresolved);
}

test "merge TUI: Backspace clears a focused Result before editing" {
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
    try pressKeyForTest(&view, &ctx, vaxis.Key.up);
    try focusResultForTest(&view, &ctx);
    try pressKeyForTest(&view, &ctx, vaxis.Key.backspace);

    // Keyboard focus must let Backspace clear the value without a mouse edit transition.
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("", value);
    try testing.expect(view.editing);
    try testing.expect(view.focus_area == .inspector);
    try testing.expect(view.selected_value == .result);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expect(fixture.plan.operations[state.conflict_indices[0]].resolution == .unresolved);
}

test "merge TUI: Backspace edits typed Result text one character at a time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();
    _ = try drawForTest(arena, view.widget(), 100, 20);
    var ctx = eventContext(arena);

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
        .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
    );

    // Once typing starts, Result must keep the TextField deletion behavior.
    const value = try view.editor.toOwnedSlice();
    defer arena.free(value);
    try testing.expectEqualStrings("10", value);
}

test "merge TUI: TextField navigation makes Backspace delete normally" {
    const navigation_keys = [_]vaxis.Key{
        .{ .codepoint = 'a', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'e', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'b', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'f', .mods = .{ .ctrl = true } },
        .{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } },
        .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } },
    };

    for (navigation_keys) |navigation_key| {
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
        try state.handle(.{ .select_conflict = 0 });
        try beginEditingForTest(&view, &ctx);
        var focused_surface = try drawForTest(arena, view.widget(), 100, 20);
        try routeFocusedEventForTest(
            arena,
            focused_surface,
            view.editor.widget(),
            &ctx,
            .{ .key_press = navigation_key },
        );
        focused_surface = try drawForTest(arena, view.widget(), 100, 20);
        try routeFocusedEventForTest(
            arena,
            focused_surface,
            view.editor.widget(),
            &ctx,
            .{ .key_press = .{ .codepoint = vaxis.Key.backspace } },
        );

        // Navigation cancels whole-value replacement before TextField handles Backspace.
        const value = try view.editor.toOwnedSlice();
        defer arena.free(value);
        try testing.expect(value.len != 0);
        try testing.expect(fixture.plan.operations[state.conflict_indices[0]].resolution != .unresolved);
    }
}

test "merge TUI: screen content keeps an outer margin" {
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
    try pressKeyForTest(&view, &ctx, vaxis.Key.enter);

    const surface = try drawForTest(arena, view.widget(), 100, 20);
    // The terminal edge must not touch headers, work areas, or the final action.
    for (0..100) |col| {
        try testing.expectEqualStrings(" ", surface.readCell(@intCast(col), 0).char.grapheme);
        try testing.expectEqualStrings(" ", surface.readCell(@intCast(col), 19).char.grapheme);
    }
    for (0..20) |row| {
        inline for (.{ 0, 1, 98, 99 }) |col| {
            try testing.expectEqualStrings(" ", surface.readCell(col, @intCast(row)).char.grapheme);
        }
    }
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 18), "[Complete]") != null);
}

test "merge TUI: a small terminal reports its required size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try screenPlan(arena);
    var state = try merge_ui_state.State.init(arena, &fixture.plan);
    var view = try viewForTest(arena, &state, "A.prefab", fixture.partial);
    defer view.deinit();

    const surface = try drawForTest(arena, view.widget(), 79, 9);

    // The minimum-size branch must avoid geometry underflow and show one concise line.
    try testing.expect(std.mem.indexOf(u8, try rowText(arena, surface, 0), "Needs 80 columns and 10 rows") != null);
    try testing.expectEqual(@as(usize, 0), surface.children.len);
}
