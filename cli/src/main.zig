const std = @import("std");
const command = @import("command.zig");
const diff = @import("diff.zig");
const diff_driver = @import("diff_driver.zig");
const diff_setup = @import("diff_setup.zig");
const merge_driver = @import("merge_driver.zig");
const mergetool = @import("mergetool.zig");
const merge_strategy = @import("git_merge_strategy.zig");
const merge_setup = @import("merge_setup.zig");
const installation = @import("installation.zig");
const version = @import("build_options").version;

test {
    std.testing.refAllDecls(@This());
    _ = command;
    _ = diff;
    _ = diff_driver;
    _ = diff_setup;
    _ = merge_driver;
    _ = mergetool;
    _ = merge_strategy;
    _ = @import("atomic_file.zig");
    _ = @import("merge_io.zig");
    _ = @import("merge_tree.zig");
    _ = @import("merge_tui.zig");
    _ = @import("merge_ui_state.zig");
    _ = @import("resolve.zig");
    _ = @import("input.zig");
    _ = @import("display.zig");
    _ = @import("render_tree.zig");
    _ = @import("render_html.zig");
    _ = @import("unity_path.zig");
    _ = @import("builtin_refs.zig");
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const user_args = if (args.len > 1) args[1..] else args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const color = std.Io.File.stdout().isTty(init.io) catch false;

    const parsed = command.parse(user_args) catch {
        try stderr.writeAll("prefablens: Invalid command arguments.\n");
        try stderr.flush();
        return 2;
    };
    const code = switch (parsed) {
        .merge_strategy => |strategy_args| blk: {
            if (strategy_args.len == 1 and std.mem.eql(u8, strategy_args[0], "--version")) {
                try stdout.writeAll("prefablens merge-strategy " ++ version ++ "\n");
                break :blk @as(u8, 0);
            }
            break :blk merge_strategy.run(init.io, arena, strategy_args, init.environ_map, stderr) catch |err| {
                if (!try installation.writeError(stderr, err))
                    try stderr.print("prefablens: Merge strategy failed: {s}.\n", .{@errorName(err)});
                break :blk @as(u8, 2);
            };
        },
        .setup_merge => |setup_args| blk: {
            merge_setup.run(init.io, arena, setup_args, init.environ_map, stdout) catch |err| {
                if (!try installation.writeError(stderr, err)) switch (err) {
                    error.Git239Required => try stderr.writeAll("prefablens: Automatic merge needs Git 2.39 or later.\n"),
                    error.InvalidSetupArguments => try stderr.writeAll("usage: " ++ merge_setup.usage ++ "\n"),
                    error.SetupRequiresRepository => try stderr.writeAll("prefablens: Merge setup requires a Git working tree.\nRun this command inside a repository, or use: prefablens setup-merge --user\n"),
                    error.InvalidUserAttributesPath => try stderr.writeAll("prefablens: Global core.attributesFile must name an absolute path or start with ~/.\nSet it with git config --global core.attributesFile <path>, then run setup again.\n"),
                    else => try stderr.print("prefablens: Merge setup failed: {s}.\n", .{@errorName(err)}),
                };
                break :blk @as(u8, 2);
            };
            break :blk @as(u8, 0);
        },
        .setup_diff => |setup_args| blk: {
            diff_setup.run(init.io, arena, setup_args, init.environ_map, stdout) catch |err| switch (err) {
                error.InvalidSetupArguments => {
                    try stderr.writeAll("usage: " ++ diff_setup.usage ++ "\n");
                    break :blk @as(u8, 2);
                },
                error.SetupRequiresRepository => {
                    try stderr.writeAll("prefablens: Diff setup requires a Git working tree.\nRun this command inside a repository, or use: prefablens setup-diff --user\n");
                    break :blk @as(u8, 2);
                },
                error.InvalidUserAttributesPath => {
                    try stderr.writeAll("prefablens: Global core.attributesFile must name an absolute path or start with ~/.\nSet it with git config --global core.attributesFile <path>, then run setup again.\n");
                    break :blk @as(u8, 2);
                },
                else => {
                    try stderr.print("prefablens: Diff setup failed: {s}.\n", .{@errorName(err)});
                    break :blk @as(u8, 2);
                },
            };
            break :blk @as(u8, 0);
        },
        .diff => |diff_args| try diff.run(
            init.io,
            arena,
            diff_args,
            stdout,
            stderr,
            color,
            init.environ_map,
        ),
        .diff_driver => |driver_args| try diff_driver.run(
            init.io,
            arena,
            driver_args,
            stdout,
            stderr,
            init.environ_map,
        ),
        .merge_driver => |driver_args| try merge_driver.runWithGit(
            init.io,
            arena,
            driver_args,
            .{ .io = init.io, .arena = arena, .env = init.environ_map },
            stderr,
        ),
        .mergetool => |tool_args| blk: {
            const stdin_tty = std.Io.File.stdin().isTty(init.io) catch false;
            const stdout_tty = std.Io.File.stdout().isTty(init.io) catch false;
            break :blk try mergetool.run(
                init.io,
                arena,
                tool_args,
                init.environ_map,
                stdin_tty,
                stdout_tty,
                stderr,
            );
        },
    };
    try stdout.flush();
    try stderr.flush();
    return code;
}
