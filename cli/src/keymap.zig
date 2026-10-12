const std = @import("std");
const builtin = @import("builtin");
const shared = @import("keymap");
const vaxis = @import("vaxis");

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
    cursor_up,
    cursor_down,
    line_start,
    line_end,
};
const Input = shared.Bindings(Context, Action);
pub const initial_json = @embedFile("keymap.json");

fn supportsAction(context: Context, action: Action) bool {
    return switch (action) {
        .back,
        .move_left,
        .move_right,
        .move_up,
        .move_down,
        .activate,
        .toggle_raw_view,
        .toggle_file_view,
        .toggle_result_preview,
        .toggle_combine,
        => context == .merge,
        .pan_left, .pan_right => context == .inspector,
        .quit, .choose_current, .choose_incoming, .keep, .delete, .edit_custom => context == .file_choice,
        .confirm => context == .file_choice or context == .dialog,
        .cancel => context == .dialog or context == .editor,
        .choose_cancel, .choose_confirm, .activate_choice => context == .dialog,
        .submit, .copy_selection, .insert_newline, .cursor_up, .cursor_down, .line_start, .line_end => context == .editor,
    };
}

pub const Bindings = struct {
    input: Input,
    arena: std.heap.ArenaAllocator,
    config: std.json.Value,

    pub const LoadResult = union(enum) { bindings: Bindings, invalid: shared.Diagnostic };

    pub fn load(allocator: std.mem.Allocator, json: []const u8) !LoadResult {
        var input = switch (try Input.load(allocator, json)) {
            .bindings => |value| value,
            .invalid => |diagnostic| return .{ .invalid = diagnostic },
        };
        var retained = false;
        defer if (!retained) input.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer if (!retained) arena.deinit();
        // Hints must outlive the configuration file buffer.
        const config = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{ .allocate = .alloc_always });
        for (config.object.keys(), config.object.values()) |context_name, actions| {
            const context = std.meta.stringToEnum(Context, context_name).?;
            for (actions.object.keys()) |action_name| {
                const action = std.meta.stringToEnum(Action, action_name).?;
                if (!supportsAction(context, action)) return .{ .invalid = .{
                    .kind = .unknown_action,
                    .message = try std.fmt.allocPrint(allocator, "Unsupported action '{s}.{s}'", .{ context_name, action_name }),
                    .allocator = allocator,
                } };
            }
        }
        retained = true;
        return .{ .bindings = .{ .input = input, .arena = arena, .config = config } };
    }

    pub fn deinit(self: *Bindings) void {
        self.input.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn receive(self: *Bindings, active_contexts: []const Context, key: vaxis.Key) Input.Result {
        return self.input.receive(active_contexts, shared.libvaxisMatcher(key));
    }

    pub fn cancel(self: *Bindings) void {
        self.input.cancel();
    }

    pub fn hint(self: *const Bindings, context: Context, action: Action) []const u8 {
        if (self.config.object.get(@tagName(context))) |actions| {
            if (actions.object.get(@tagName(action))) |keys| {
                return if (keys.array.items.len == 0) "" else keys.array.items[0].string;
            }
        }
        return "";
    }

    pub fn label(self: *const Bindings, allocator: std.mem.Allocator, context: Context, action: Action, operation: []const u8) ![]const u8 {
        const text = self.hint(context, action);
        if (text.len == 0) return allocator.dupe(u8, operation);
        const key = shared.KeyPress.parse(text) catch return std.fmt.allocPrint(allocator, "{s} {s}", .{ text, operation });
        if (key.key == .character and key.key.character < 128 and
            std.ascii.isAlphabetic(@intCast(key.key.character)) and std.meta.eql(key.modifiers, shared.Modifiers{ .shift = true }))
        {
            return std.fmt.allocPrint(allocator, "⇧{c} {s}", .{ std.ascii.toUpper(@intCast(key.key.character)), operation });
        }
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ text, operation });
    }
};

pub fn loadUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) !Bindings {
    const xdg = env.get("XDG_CONFIG_HOME");
    const base = if (xdg != null and xdg.?.len != 0)
        xdg.?
    else if (builtin.os.tag == .windows)
        env.get("APPDATA") orelse return (try Bindings.load(allocator, initial_json)).bindings
    else
        try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return (try Bindings.load(allocator, initial_json)).bindings, ".config" });
    defer if (xdg == null or xdg.?.len == 0) {
        if (builtin.os.tag != .windows) allocator.free(base);
    };
    if (base.len == 0) return (try Bindings.load(allocator, initial_json)).bindings;
    const path = try std.fs.path.join(allocator, &.{ base, "prefablens", "keymap.json" });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return (try Bindings.load(allocator, initial_json)).bindings,
        error.OutOfMemory => return err,
        else => {
            try stderr.print("{s}: {s}\n", .{ path, @errorName(err) });
            return error.InvalidKeymap;
        },
    };
    defer allocator.free(text);
    return switch (try Bindings.load(allocator, text)) {
        .bindings => |value| value,
        .invalid => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            if (diagnostic.position) |position| {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, position.line, position.column, diagnostic.message });
            } else {
                try stderr.print("{s}: {s}\n", .{ path, diagnostic.message });
            }
            return error.InvalidKeymap;
        },
    };
}

test "keymap: omitted actions leave initial shortcuts unbound" {
    // A custom file must not silently restore actions the user omitted.
    var bindings = (try Bindings.load(std.testing.allocator,
        \\{"merge": {"toggle_raw_view": ["Ctrl+r"]}}
    )).bindings;
    defer bindings.deinit();
    try std.testing.expectEqual(.none, bindings.receive(&.{.merge}, .{ .codepoint = vaxis.Key.up }));
    try std.testing.expectEqualStrings("", bindings.hint(.merge, .move_up));
}

test "keymap: actions from another context are rejected" {
    // Handlers dispatch only their supported actions, even when an action exists in another context.
    const cases = [_]struct { json: []const u8, entry: []const u8 }{
        .{ .json = "{\"merge\": {\"quit\": [\"q\"]}}", .entry = "merge.quit" },
        .{ .json = "{\"inspector\": {\"submit\": [\"Enter\"]}}", .entry = "inspector.submit" },
        .{ .json = "{\"file_choice\": {\"back\": [\"Escape\"]}}", .entry = "file_choice.back" },
        .{ .json = "{\"dialog\": {\"move_up\": []}}", .entry = "dialog.move_up" },
        .{ .json = "{\"editor\": {\"move_up\": [\"Up\"]}}", .entry = "editor.move_up" },
    };
    for (cases) |case| {
        switch (try Bindings.load(std.testing.allocator, case.json)) {
            .bindings => |value| {
                var bindings = value;
                bindings.deinit();
                return error.TestUnexpectedResult;
            },
            .invalid => |value| {
                var diagnostic = value;
                defer diagnostic.deinit();
                try std.testing.expectEqual(shared.Diagnostic.Kind.unknown_action, diagnostic.kind);
                try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, case.entry) != null);
            },
        }
    }
}
