const std = @import("std");
const keymap = @import("keymap.zig");
const vaxis = @import("vaxis");
const shared = @import("keymap");
const merge_io = @import("merge_io.zig");
const vxfw = vaxis.vxfw;

pub const Choice = enum { keep, delete, ours, theirs, custom, quit };
pub const Paths = struct { base: []const u8, ours: ?[]const u8, theirs: ?[]const u8, paired_meta: bool, unknown_context: bool = false };

/// Selection is separate from Enter so deletion and path changes are confirmed.
/// This screen only records a decision; the caller owns all filesystem writes.
pub fn run(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, paths: Paths, bindings: *const keymap.Bindings) !Choice {
    var view: View = .{
        .paths = paths,
        .bindings = bindings,
        .base = try label(arena, "Base:     ", paths.base),
        .ours = try label(arena, "Current:  ", paths.ours),
        .theirs = try label(arena, "Incoming: ", paths.theirs),
    };
    var buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, arena, env, &buffer);
    defer app.deinit();
    try app.run(view.widget(), .{});
    return view.result;
}

fn label(arena: std.mem.Allocator, prefix: []const u8, path: ?[]const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    try output.writer.writeAll(prefix);
    if (path) |value| try merge_io.writeSafePath(&output.writer, value) else try output.writer.writeAll("(deleted)");
    return output.toOwnedSlice();
}

const View = struct {
    bindings: *const keymap.Bindings,
    paths: Paths,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    selected: ?Choice = null,
    result: Choice = .quit,

    fn widget(self: *View) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(userdata: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *View = @ptrCast(@alignCast(userdata));
        switch (value) {
            .key_press => |key| {
                const action = self.bindings.resolve(&.{.file_choice}, shared.vaxisMatcher(key)) orelse return;
                switch (action) {
                    .quit => {
                        self.result = .quit;
                        ctx.quit = true;
                        return;
                    },
                    .confirm => {
                        if (self.selected) |selected| {
                            self.result = selected;
                            ctx.quit = true;
                        }
                        return;
                    },
                    .edit_custom => if (self.paths.unknown_context) {
                        self.selected = .custom;
                    },
                    .choose_current => if (self.paths.ours != null and self.paths.theirs != null) {
                        self.selected = .ours;
                    },
                    .choose_incoming => if (self.paths.ours != null and self.paths.theirs != null) {
                        self.selected = .theirs;
                    },
                    .keep => if (self.paths.ours == null or self.paths.theirs == null) {
                        self.selected = .keep;
                    },
                    .delete => if (self.paths.ours == null or self.paths.theirs == null) {
                        self.selected = .delete;
                    },
                    else => unreachable,
                }
                ctx.consumeAndRedraw();
            },
            .winsize => ctx.consumeAndRedraw(),
            else => {},
        }
    }

    fn instruction(self: *const View, arena: std.mem.Allocator, output: *std.ArrayList(u8), action: keymap.Action, operation: []const u8) std.mem.Allocator.Error!void {
        const hint = self.bindings.hint(.file_choice, action);
        if (hint.len == 0) return;
        if (output.items.len != 0) try output.appendSlice(arena, "   ");
        try output.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ hint, operation }));
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *View = @ptrCast(@alignCast(userdata));
        const size: vxfw.Size = .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height orelse ctx.min.height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        var instructions: std.ArrayList(u8) = .empty;
        if (self.paths.ours != null and self.paths.theirs != null) {
            try self.instruction(ctx.arena, &instructions, .choose_current, if (self.paths.unknown_context) "Whole current file" else "Use current path");
            try self.instruction(ctx.arena, &instructions, .choose_incoming, if (self.paths.unknown_context) "Whole incoming file" else "Use incoming path");
        } else {
            try self.instruction(ctx.arena, &instructions, .keep, "Keep the file");
            try self.instruction(ctx.arena, &instructions, .delete, "Delete the file");
        }
        if (self.paths.unknown_context) try self.instruction(ctx.arena, &instructions, .edit_custom, "Edit custom file");
        try self.instruction(ctx.arena, &instructions, .quit, "Quit");
        const description = if (self.selected) |selected| switch (selected) {
            .keep => "Keep the file.",
            .delete => "Delete the file.",
            .ours => if (self.paths.unknown_context) "Use the whole current file." else "Use the current path.",
            .theirs => if (self.paths.unknown_context) "Use the whole incoming file." else "Use the incoming path.",
            .custom => "Open the editor with the current file. Save and close to apply.",
            .quit => unreachable,
        } else "Choose an operation.";
        const confirm_key = self.bindings.hint(.file_choice, .confirm);
        const confirmation = if (confirm_key.len == 0) description else try std.fmt.allocPrint(ctx.arena, "{s} Press {s} to confirm.", .{ description, confirm_key });
        const lines: []const []const u8 = &.{ if (self.paths.unknown_context) "Unknown base/context: choose the whole file" else "Unity asset file conflict", "", self.base, self.ours, self.theirs, if (self.paths.paired_meta) "The asset and its matching .meta file are handled together." else "", "", instructions.items, "", confirmation };
        // Wrap full paths so two long names with a shared prefix stay distinguishable.
        var row: u16 = 1;
        for (lines) |line| {
            var column: u16 = 2;
            var graphemes = vaxis.unicode.graphemeIterator(line);
            while (graphemes.next()) |grapheme| {
                const bytes = grapheme.bytes(line);
                const width = vaxis.gwidth.gwidth(bytes, .unicode);
                if (column + width >= size.width) {
                    row += 1;
                    column = 2;
                }
                if (row >= size.height or column + width >= size.width) break;
                surface.writeCell(column, row, .{ .char = .{ .grapheme = bytes, .width = @intCast(width) } });
                column += @intCast(width);
            }
            row += 1;
            if (row >= size.height) break;
        }
        return surface;
    }
};
