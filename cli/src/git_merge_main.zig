const std = @import("std");
const strategy = @import("git_merge_strategy.zig");
const installation = @import("installation.zig");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stderr(), init.io, &buffer);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "git-merge-prefablens " ++ @import("build_options").version ++ "\n");
        return 0;
    }
    const code = strategy.run(init.io, arena, args[1..], init.environ_map, &writer.interface) catch |err| blk: {
        if (!try installation.writeError(&writer.interface, err))
            try writer.interface.print("prefablens: Merge strategy failed: {s}.\n", .{@errorName(err)});
        break :blk @as(u8, 2);
    };
    try writer.interface.flush();
    return code;
}
