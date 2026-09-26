const std = @import("std");
const builtin = @import("builtin");
const shared = @import("keymap");

pub const Context = enum { merge, inspector, file_choice, dialog, editor };
pub const Action = enum {
    back,
    move_left,
    move_right,
    move_up,
    move_down,
    activate,
    toggle_raw_view,
    toggle_file_view,
    toggle_result_preview,
    toggle_combine,
    pan_left,
    pan_right,
    quit,
    confirm,
    choose_current,
    choose_incoming,
    keep,
    delete,
    edit_custom,
    cancel,
    choose_cancel,
    choose_confirm,
    activate_choice,
    submit,
    copy_selection,
    insert_newline,
    line_start,
    line_end,
};
pub const Bindings = shared.Keymap(Context, Action);
pub const specification: Bindings.Specification = .{
    .defaults = &.{
        .{ .context = .merge, .action = .back, .keys = &.{"Escape"} },
        .{ .context = .merge, .action = .move_left, .keys = &.{"Left"} },
        .{ .context = .merge, .action = .move_right, .keys = &.{"Right"} },
        .{ .context = .merge, .action = .move_up, .keys = &.{"Up"} },
        .{ .context = .merge, .action = .move_down, .keys = &.{"Down"} },
        .{ .context = .merge, .action = .toggle_result_preview, .keys = &.{ "Shift+v", "V" } },
        .{ .context = .merge, .action = .activate, .keys = &.{"Enter"} },
        .{ .context = .merge, .action = .toggle_raw_view, .keys = &.{"Shift+r"} },
        .{ .context = .merge, .action = .toggle_file_view, .keys = &.{ "Shift+e", "E" } },
        .{ .context = .merge, .action = .toggle_combine, .keys = &.{"Shift+t"} },
        .{ .context = .inspector, .action = .pan_left, .keys = &.{"Shift+Left"} },
        .{ .context = .inspector, .action = .pan_right, .keys = &.{"Shift+Right"} },
        .{ .context = .file_choice, .action = .quit, .keys = &.{ "q", "Escape", "Ctrl+c" } },
        .{ .context = .file_choice, .action = .confirm, .keys = &.{"Enter"} },
        .{ .context = .file_choice, .action = .choose_current, .keys = &.{"a"} },
        .{ .context = .file_choice, .action = .choose_incoming, .keys = &.{"b"} },
        .{ .context = .file_choice, .action = .keep, .keys = &.{"k"} },
        .{ .context = .file_choice, .action = .delete, .keys = &.{"d"} },
        .{ .context = .file_choice, .action = .edit_custom, .keys = &.{"e"} },
        .{ .context = .dialog, .action = .confirm, .keys = &.{ "y", "Y" } },
        .{ .context = .dialog, .action = .cancel, .keys = &.{ "n", "N", "Escape" } },
        .{ .context = .dialog, .action = .choose_cancel, .keys = &.{"Left"} },
        .{ .context = .dialog, .action = .choose_confirm, .keys = &.{"Right"} },
        .{ .context = .dialog, .action = .activate_choice, .keys = &.{"Enter"} },
        .{ .context = .editor, .action = .submit, .keys = &.{"Enter"} },
        .{ .context = .editor, .action = .cancel, .keys = &.{"Escape"} },
        .{ .context = .editor, .action = .copy_selection, .keys = &.{ "Super+c", "Ctrl+c" } },
        .{ .context = .editor, .action = .insert_newline, .keys = &.{ "Ctrl+j", "Shift+Enter" } },
        .{ .context = .editor, .action = .move_up, .keys = &.{"Up"} },
        .{ .context = .editor, .action = .move_down, .keys = &.{"Down"} },
        .{ .context = .editor, .action = .line_start, .keys = &.{ "Home", "Ctrl+a" } },
        .{ .context = .editor, .action = .line_end, .keys = &.{ "End", "Ctrl+e" } },
    },
    .active_contexts = &.{ &.{ .merge, .inspector }, &.{.file_choice}, &.{.dialog}, &.{.editor} },
};

pub fn defaults(allocator: std.mem.Allocator) !Bindings {
    return switch (try Bindings.load(allocator, specification, null)) {
        .bindings => |bindings| bindings,
        .invalid => unreachable,
    };
}

pub const Label = struct {
    buffer: [128]u8 = undefined,
    length: usize,

    pub fn init(bindings: *const Bindings, context: Context, action: Action, operation: []const u8) Label {
        var result: Label = .{ .length = 0 };
        const keys = bindings.keys(context, action);
        const hint = bindings.hint(context, action);
        const formatted = if (keys.len != 0 and keys[0].key == .character and keys[0].key.character < 128 and
            std.ascii.isAlphabetic(@intCast(keys[0].key.character)) and std.meta.eql(keys[0].modifiers, shared.Modifiers{ .shift = true }))
            std.fmt.bufPrint(&result.buffer, "⇧{c} {s}", .{ std.ascii.toUpper(@intCast(keys[0].key.character)), operation }) catch unreachable
        else if (hint.len != 0)
            std.fmt.bufPrint(&result.buffer, "{s} {s}", .{ hint, operation }) catch unreachable
        else
            std.fmt.bufPrint(&result.buffer, "{s}", .{operation}) catch unreachable;
        result.length = formatted.len;
        return result;
    }

    pub fn text(self: *const Label) []const u8 {
        return self.buffer[0..self.length];
    }
};

pub fn loadUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) !Bindings {
    const xdg = env.get("XDG_CONFIG_HOME");
    const base = if (xdg != null and xdg.?.len != 0)
        xdg.?
    else if (builtin.os.tag == .windows)
        env.get("APPDATA") orelse return defaults(allocator)
    else
        try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return defaults(allocator), ".config" });
    defer if (xdg == null or xdg.?.len == 0) {
        if (builtin.os.tag != .windows) allocator.free(base);
    };
    if (base.len == 0) return defaults(allocator);
    const path = try std.fs.path.join(allocator, &.{ base, "prefablens", "keymap.toml" });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return defaults(allocator),
        else => {
            try stderr.print("{s}: {s}\n", .{ path, @errorName(err) });
            return error.InvalidKeymap;
        },
    };
    defer allocator.free(text);
    return switch (try Bindings.load(allocator, specification, text)) {
        .bindings => |bindings| bindings,
        .invalid => |diagnostic| {
            if (diagnostic.line) |line| {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, line, diagnostic.column orelse 1, diagnostic.message() });
            } else try stderr.print("{s}: {s}\n", .{ path, diagnostic.message() });
            return error.InvalidKeymap;
        },
    };
}
