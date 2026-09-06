const std = @import("std");
const vaxis = @import("vaxis");
const merge_io = @import("merge_io.zig");
const vxfw = vaxis.vxfw;

pub const Choice = enum { keep, delete, ours, theirs, custom, quit };
pub const Paths = struct { base: []const u8, ours: ?[]const u8, theirs: ?[]const u8, paired_meta: bool, unknown_context: bool = false };

/// Selection is separate from Enter so deletion and path changes are confirmed.
/// This screen only records a decision; the caller owns all filesystem writes.
pub fn run(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, paths: Paths) !Choice {
    var view: View = .{
        .paths = paths,
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
                if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                    self.result = .quit;
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.selected) |selected| {
                        self.result = selected;
                        ctx.quit = true;
                    }
                    return;
                }
                if (self.paths.unknown_context and key.matches('e', .{})) self.selected = .custom;
                if (self.paths.ours != null and self.paths.theirs != null) {
                    if (key.matches('a', .{})) self.selected = .ours;
                    if (key.matches('b', .{})) self.selected = .theirs;
                } else {
                    if (key.matches('k', .{})) self.selected = .keep;
                    if (key.matches('d', .{})) self.selected = .delete;
                }
                ctx.consumeAndRedraw();
            },
            .winsize => ctx.consumeAndRedraw(),
            else => {},
        }
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *View = @ptrCast(@alignCast(userdata));
        const size: vxfw.Size = .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height orelse ctx.min.height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        const instructions = if (self.paths.unknown_context)
            "a: Whole current file   b: Whole incoming file   e: Edit custom file   q: Quit"
        else if (self.paths.ours != null and self.paths.theirs != null)
            "a: Use current path    b: Use incoming path    q: Quit"
        else
            "k: Keep the file    d: Delete the file    q: Quit";
        const confirmation = if (self.selected) |selected| switch (selected) {
            .keep => "Keep the file. Press Enter to confirm.",
            .delete => "Delete the file. Press Enter to confirm.",
            .ours => if (self.paths.unknown_context) "Use the whole current file. Press Enter to confirm." else "Use the current path. Press Enter to confirm.",
            .theirs => if (self.paths.unknown_context) "Use the whole incoming file. Press Enter to confirm." else "Use the incoming path. Press Enter to confirm.",
            .custom => "Open the editor with the current file. Save and close to apply.",
            .quit => unreachable,
        } else "Choose an operation, then press Enter to confirm.";
        const lines: []const []const u8 = &.{ if (self.paths.unknown_context) "Unknown base/context: choose the whole file" else "Unity asset file conflict", "", self.base, self.ours, self.theirs, if (self.paths.paired_meta) "The asset and its matching .meta file are handled together." else "", "", instructions, "", confirmation };
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
