const std = @import("std");
const builtin = @import("builtin");
const t = @import("integration");

pub fn main(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(a);
    try t.require(args.len == 2, "expected the prefablens executable path");
    const prefablens = try cwd.realPathFileAlloc(io, args[1], a);
    const scratch = try t.scratchDirectory(io, a, "keymap space 日本語");
    defer cwd.deleteTree(io, scratch) catch {};

    // Setup must work after installation without a source checkout or Git repository.
    var env = try init.environ_map.clone(a);
    const xdg = try std.fs.path.join(a, &.{ scratch, "xdg" });
    const home = try std.fs.path.join(a, &.{ scratch, "home" });
    const appdata = try std.fs.path.join(a, &.{ scratch, "appdata" });
    try env.put("XDG_CONFIG_HOME", xdg);
    try env.put("HOME", home);
    try env.put("APPDATA", appdata);
    const path = try std.fs.path.join(a, &.{ xdg, "prefablens", "keymap.json" });
    const created = try std.process.run(a, io, .{
        .argv = &.{ prefablens, "setup-keymap" },
        .cwd = .{ .path = scratch },
        .environ_map = &env,
    });
    try t.expectCode(created, 0, "create user keymap");
    try t.require(std.mem.eql(u8, std.mem.trim(u8, created.stdout, "\r\n"), path), "setup did not print the editable keymap path");
    const bytes = try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024));
    const config = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer config.deinit();
    for ([_][]const u8{ "merge", "inspector", "file_choice", "dialog", "editor" }) |context| {
        try t.require(config.value.object.contains(context), "initial keymap omitted a context");
    }

    // Repeating setup during an upgrade must preserve the user's assignments byte for byte.
    const custom = "{\"merge\":{\"toggle_raw_view\":[\"Ctrl+r\"]}}\n";
    try cwd.writeFile(io, .{ .sub_path = path, .data = custom });
    const repeated = try std.process.run(a, io, .{
        .argv = &.{ prefablens, "setup-keymap" },
        .cwd = .{ .path = scratch },
        .environ_map = &env,
    });
    try t.expectCode(repeated, 0, "preserve user keymap");
    try t.require(std.mem.eql(u8, custom, try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024))), "setup overwrote the user's assignments");

    // Empty XDG_CONFIG_HOME must select the same platform path as interactive loading.
    try env.put("XDG_CONFIG_HOME", "");
    const fallback_path = if (builtin.os.tag == .windows)
        try std.fs.path.join(a, &.{ appdata, "prefablens", "keymap.json" })
    else
        try std.fs.path.join(a, &.{ home, ".config", "prefablens", "keymap.json" });
    const fallback = try std.process.run(a, io, .{
        .argv = &.{ prefablens, "setup-keymap" },
        .cwd = .{ .path = scratch },
        .environ_map = &env,
    });
    try t.expectCode(fallback, 0, "create platform keymap");
    try t.require(std.mem.eql(u8, std.mem.trim(u8, fallback.stdout, "\r\n"), fallback_path), "setup ignored the platform configuration directory");
    try t.require(std.mem.eql(u8, bytes, try cwd.readFileAlloc(io, fallback_path, a, .limited(1024 * 1024))), "platform setup did not export the initial keymap");

    // Missing user directories must fail explicitly rather than write into the current directory.
    _ = env.swapRemove("XDG_CONFIG_HOME");
    _ = env.swapRemove("HOME");
    _ = env.swapRemove("APPDATA");
    const missing_home = try std.process.run(a, io, .{
        .argv = &.{ prefablens, "setup-keymap" },
        .cwd = .{ .path = scratch },
        .environ_map = &env,
    });
    try t.expectCode(missing_home, 2, "keymap setup without a user directory");
    try t.require(std.mem.indexOf(u8, missing_home.stderr, "XDG_CONFIG_HOME") != null, "setup omitted configuration directory guidance");

    try env.put("XDG_CONFIG_HOME", xdg);
    const extra = try std.process.run(a, io, .{
        .argv = &.{ prefablens, "setup-keymap", "--force" },
        .cwd = .{ .path = scratch },
        .environ_map = &env,
    });
    try t.expectCode(extra, 2, "reject unsupported setup arguments");
    try t.require(std.mem.eql(u8, custom, try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024))), "invalid setup arguments changed the keymap");

    try std.Io.File.stdout().writeStreamingAll(io, "Keymap setup integration: passed\n");
    return 0;
}
