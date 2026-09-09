const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Position = struct { row: usize = 0, col: usize = 0 };
pub const Selection = struct { start: usize, end: usize };

pub fn normalizeNewlines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const normalized = try std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
    for (normalized) |*byte| if (byte.* == '\r') {
        byte.* = '\n';
    };
    return normalized;
}

fn advance(position: *Position, text: []const u8, width: usize) void {
    if (std.mem.eql(u8, text, "\n")) {
        position.row += 1;
        position.col = 0;
        return;
    }
    const cells = vaxis.gwidth.gwidth(text, .unicode);
    if (position.col + cells > width) {
        position.row += 1;
        position.col = 0;
    }
    position.col += cells;
}

pub fn draw(editor: *vxfw.TextField, top: *usize, selection: ?Selection, ctx: vxfw.DrawContext) !vxfw.Surface {
    const size = vxfw.Size{ .width = ctx.max.width.?, .height = ctx.max.height.? };
    var surface = try vxfw.Surface.init(ctx.arena, editor.widget(), size);
    @memset(surface.buffer, .{ .style = editor.style });
    if (size.width == 0 or size.height == 0) return surface;
    const text = try editor.buf.dupe();
    defer editor.buf.allocator.free(text);
    var cursor: Position = .{};
    var before = vaxis.unicode.graphemeIterator(text[0..editor.buf.cursor]);
    while (before.next()) |g| advance(&cursor, g.bytes(text), size.width);
    if (cursor.col == size.width) {
        cursor.row += 1;
        cursor.col = 0;
    }
    if (cursor.row < top.*) top.* = cursor.row;
    if (cursor.row >= top.* + size.height) top.* = cursor.row - size.height + 1;
    surface.cursor = .{ .row = @intCast(cursor.row - top.*), .col = @intCast(cursor.col) };

    var position: Position = .{};
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        var style = editor.style;
        if (selection) |range| style.reverse = g.start >= range.start and g.start < range.end;
        if (std.mem.eql(u8, bytes, "\n")) {
            if (style.reverse and position.row >= top.* and position.row < top.* + size.height) {
                for (position.col..size.width) |col| {
                    surface.writeCell(@intCast(col), @intCast(position.row - top.*), .{ .style = style });
                }
            }
            advance(&position, bytes, size.width);
            continue;
        }
        const cells = vaxis.gwidth.gwidth(bytes, .unicode);
        if (position.col + cells > size.width) {
            position.row += 1;
            position.col = 0;
        }
        if (position.row >= top.* + size.height) break;
        if (cells > 0 and cells <= size.width and position.row >= top.*) {
            surface.writeCell(@intCast(position.col), @intCast(position.row - top.*), .{
                .char = .{ .grapheme = try ctx.arena.dupe(u8, bytes), .width = @intCast(cells) },
                .style = style,
            });
        }
        position.col += cells;
    }
    return surface;
}

pub fn moveLine(editor: *vxfw.TextField, key: vaxis.Key) !bool {
    const up = key.matches(vaxis.Key.up, .{});
    const down = key.matches(vaxis.Key.down, .{});
    const home = key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true });
    const end = key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true });
    if (!up and !down and !home and !end) return false;
    const text = try editor.buf.dupe();
    defer editor.buf.allocator.free(text);
    const cursor = editor.buf.cursor;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..cursor], '\n')) |at| at + 1 else 0;
    const stop = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
    const target = if (home) start else if (end) stop else blk: {
        if ((up and start == 0) or (down and stop == text.len)) return true;
        const next_start = if (up)
            (if (std.mem.lastIndexOfScalar(u8, text[0 .. start - 1], '\n')) |at| at + 1 else 0)
        else
            stop + 1;
        const next_end = if (up) start - 1 else std.mem.indexOfScalarPos(u8, text, next_start, '\n') orelse text.len;
        var column: usize = 0;
        var before = vaxis.unicode.graphemeIterator(text[start..cursor]);
        while (before.next()) |g| column += vaxis.gwidth.gwidth(g.bytes(text[start..cursor]), .unicode);
        var next = vaxis.unicode.graphemeIterator(text[next_start..next_end]);
        var offset = next_start;
        var width: usize = 0;
        while (next.next()) |g| {
            width += vaxis.gwidth.gwidth(g.bytes(text[next_start..next_end]), .unicode);
            if (width > column) break;
            offset = next_start + g.start + g.len;
        }
        break :blk offset;
    };
    if (target < cursor) editor.buf.moveGapLeft(cursor - target) else editor.buf.moveGapRight(target - cursor);
    return true;
}

pub fn cellAt(editor: *vxfw.TextField, width: usize, row: usize, col: usize) !Selection {
    const text = try editor.buf.dupe();
    defer editor.buf.allocator.free(text);
    var position: Position = .{};
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const newline = std.mem.eql(u8, bytes, "\n");
        const cells = vaxis.gwidth.gwidth(bytes, .unicode);
        if (!newline and position.col + cells > width) {
            position.row += 1;
            position.col = 0;
        }
        // Hit testing must use the same wrapping and grapheme boundaries as drawing.
        if (position.row > row) return .{ .start = g.start, .end = g.start };
        if (position.row == row and (newline or col < position.col + cells))
            return .{ .start = g.start, .end = g.start + if (newline) @as(usize, 0) else g.len };
        advance(&position, bytes, width);
    }
    return .{ .start = text.len, .end = text.len };
}

pub fn setCursor(editor: *vxfw.TextField, target: usize) void {
    const cursor = editor.buf.cursor;
    if (target < cursor) editor.buf.moveGapLeft(cursor - target) else editor.buf.moveGapRight(target - cursor);
}
