const std = @import("std");
const builtin = @import("builtin");
const shared = @import("keymap");
const vaxis = @import("vaxis");

pub const Context = enum { global, tree, content, dialog };
pub const Action = enum {
    back,
    complete,
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
    confirm,
    choose_current,
    choose_incoming,
    keep,
    delete,
    edit_custom,
    cancel,
    copy_selection,
    insert_newline,
    line_start,
    line_end,
};
const Input = shared.Bindings(Context, Action);
pub const initial_json = @embedFile("keymap.json");

fn supportsAction(context: Context, action: Action) bool {
    return switch (action) {
        .complete,
        .toggle_raw_view,
        .toggle_file_view,
        .toggle_result_preview,
        .toggle_combine,
        => context == .global,
        .back => context == .global or context == .content,
        .move_left, .move_right, .activate => context == .tree or context == .content or context == .dialog,
        .move_up, .move_down => context == .tree or context == .content,
        .pan_left, .pan_right, .copy_selection, .insert_newline, .line_start, .line_end => context == .content,
        .confirm, .cancel, .choose_current, .choose_incoming, .keep, .delete, .edit_custom => context == .dialog,
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

fn userPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return try std.fs.path.join(allocator, &.{ xdg, "prefablens", "keymap.json" });
    }
    const home = env.get(if (builtin.os.tag == .windows) "APPDATA" else "HOME") orelse return null;
    if (home.len == 0) return null;
    if (builtin.os.tag == .windows) return try std.fs.path.join(allocator, &.{ home, "prefablens", "keymap.json" });
    return try std.fs.path.join(allocator, &.{ home, ".config", "prefablens", "keymap.json" });
}

pub fn setupUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stdout: *std.Io.Writer) !void {
    const path = try userPath(allocator, env) orelse return error.ConfigHomeUnavailable;
    defer allocator.free(path);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    {
        const file = cwd.createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try stdout.print("{s}\n", .{path});
                return;
            },
            else => return err,
        };
        // A partial keymap would prevent later interactive sessions from starting.
        errdefer cwd.deleteFile(io, path) catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, initial_json);
    }
    try stdout.print("{s}\n", .{path});
}

pub fn loadUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) !Bindings {
    const path = try userPath(allocator, env) orelse return (try Bindings.load(allocator, initial_json)).bindings;
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
        \\{"global": {"toggle_raw_view": ["Ctrl+r"]}}
    )).bindings;
    defer bindings.deinit();
    try std.testing.expectEqual(.none, bindings.receive(&.{ .tree, .global }, .{ .codepoint = vaxis.Key.up }));
    try std.testing.expectEqualStrings("", bindings.hint(.tree, .move_up));
}

test "keymap: actions from another context are rejected" {
    // Handlers dispatch only their supported actions, even when an action exists in another context.
    switch (try Bindings.load(std.testing.allocator,
        \\{"tree": {"copy_selection": ["Ctrl+c"]}}
    )) {
        .bindings => |value| {
            var bindings = value;
            bindings.deinit();
            return error.TestUnexpectedResult;
        },
        .invalid => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expectEqual(shared.Diagnostic.Kind.unknown_action, diagnostic.kind);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "tree.copy_selection") != null);
        },
    }
}
