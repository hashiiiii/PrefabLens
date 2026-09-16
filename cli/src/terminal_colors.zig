const std = @import("std");
const vaxis = @import("vaxis");

pub const Mode = enum {
    indexed,
    rgb,

    pub fn configure(vx: *vaxis.Vaxis) Mode {
        const mode = detect(vx.env_map);
        // Older terminals accept semicolon SGR parameters but may ignore colon parameters.
        if (mode == .indexed) vx.sgr = .legacy;
        return mode;
    }

    fn detect(env: *const std.process.Environ.Map) Mode {
        if (env.get("COLORTERM")) |value| {
            if (std.ascii.eqlIgnoreCase(value, "truecolor") or std.ascii.eqlIgnoreCase(value, "24bit")) return .rgb;
        }
        if (env.get("WT_SESSION")) |value| {
            if (value.len != 0) return .rgb;
        }
        if (env.get("TERM")) |value| {
            if (std.mem.endsWith(u8, value, "-direct")) return .rgb;
        }
        return .indexed;
    }

    pub fn apply(self: Mode, surface: vaxis.vxfw.Surface) void {
        if (self == .rgb) return;
        for (surface.buffer) |*cell| {
            cell.style.fg = indexed(cell.style.fg);
            cell.style.bg = indexed(cell.style.bg);
            cell.style.ul = indexed(cell.style.ul);
        }
        for (surface.children) |child| self.apply(child.surface);
    }
};

fn indexed(color: vaxis.Color) vaxis.Color {
    const rgb = switch (color) {
        .rgb => |value| value,
        else => return color,
    };
    var best: u8 = 16;
    var distance: u32 = std.math.maxInt(u32);
    // The first 16 colors are user-configurable; the cube and grayscale ramp have fixed RGB values.
    for (16..256) |index| {
        const candidate = paletteRgb(@intCast(index));
        var squared: u32 = 0;
        for (rgb, candidate) |a, b| {
            const delta = @as(i32, a) - b;
            squared += @intCast(delta * delta);
        }
        if (squared < distance) {
            distance = squared;
            best = @intCast(index);
        }
    }
    return .{ .index = best };
}

fn paletteRgb(index: u8) [3]u8 {
    if (index >= 232) return @splat(8 + (index - 232) * 10);
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    const offset = index - 16;
    return .{ levels[offset / 36], levels[(offset / 6) % 6], levels[offset % 6] };
}

test "merge TUI: terminal color output respects RGB support and NO_COLOR" {
    const t = std.testing;
    const cases = [_]struct {
        key: []const u8,
        value: []const u8,
        expected: []const u8,
        no_color: bool = false,
    }{
        .{ .key = "TERM_PROGRAM", .value = "Apple_Terminal", .expected = "\x1b[38;5;196m" },
        .{ .key = "TERM", .value = "xterm-256color", .expected = "\x1b[38;5;196m" },
        .{ .key = "COLORTERM", .value = "truecolor", .expected = "\x1b[38:2:255:0:0m" },
        .{ .key = "COLORTERM", .value = "24bit", .expected = "\x1b[38:2:255:0:0m" },
        .{ .key = "WT_SESSION", .value = "test-session", .expected = "\x1b[38:2:255:0:0m" },
        .{ .key = "TERM", .value = "xterm-direct", .expected = "\x1b[38:2:255:0:0m" },
        .{ .key = "NO_COLOR", .value = "1", .expected = "", .no_color = true },
    };
    for (cases) |case| {
        var env = std.process.Environ.Map.init(t.allocator);
        defer env.deinit();
        try env.put(case.key, case.value);
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        var vx = try vaxis.init(t.io, t.allocator, &env, .{});
        defer vx.deinit(t.allocator, &output.writer);
        const mode = Mode.configure(&vx);
        try vx.enableDetectedFeatures(&output.writer);
        try vx.resize(t.allocator, &output.writer, .{ .cols = 1, .rows = 1, .x_pixel = 0, .y_pixel = 0 });
        const color: vaxis.Color = .{ .rgb = .{ 255, 0, 0 } };
        vx.screen.buf[0] = .{ .char = .{ .grapheme = "X", .width = 1 }, .style = .{ .fg = if (mode == .indexed) indexed(color) else color } };
        try vx.render(&output.writer);
        const bytes = output.written();
        if (case.no_color) {
            try t.expect(std.mem.indexOf(u8, bytes, "\x1b[38") == null);
        } else {
            // This checks the real renderer's wire format, including the legacy terminal separator.
            const expected = if (@import("builtin").os.tag == .windows and mode == .rgb) "\x1b[38;2;255;0;0m" else case.expected;
            try t.expect(std.mem.indexOf(u8, bytes, expected) != null);
        }
    }
}

test "merge TUI: indexed palette preserves cube colors and grayscale contrast" {
    const t = std.testing;
    try t.expectEqual(vaxis.Color{ .index = 67 }, indexed(.{ .rgb = .{ 95, 135, 175 } }));
    try t.expectEqual(vaxis.Color{ .index = 244 }, indexed(.{ .rgb = .{ 128, 128, 128 } }));
    try t.expectEqual(vaxis.Color{ .index = 16 }, indexed(.{ .rgb = .{ 0, 0, 0 } }));
    try t.expectEqual(vaxis.Color{ .index = 231 }, indexed(.{ .rgb = .{ 255, 255, 255 } }));
}
