const std = @import("std");
const core = @import("core");
const testing = std.testing;

/// guid -> asset path. Same type as core.json.Resolver, so it can be passed through directly.
pub const Index = core.json.Resolver;

pub fn buildIndex(io: std.Io, arena: std.mem.Allocator, project_root: []const u8) !Index {
    var index = Index.init(arena);
    var dir = try std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".meta")) continue;

        const meta_bytes = dir.readFileAlloc(io, entry.path, arena, .limited(1 * 1024 * 1024)) catch continue;
        const guid = parseGuid(meta_bytes) orelse continue;

        // Asset path = the .meta path without the trailing ".meta", made absolute.
        const asset_rel = entry.path[0 .. entry.path.len - ".meta".len];
        const asset_abs = try std.fs.path.join(arena, &.{ project_root, asset_rel });
        // Store an owned copy of the guid key (slice into meta_bytes is fine since arena-lived).
        try index.put(try arena.dupe(u8, guid), asset_abs);
    }
    return index;
}

fn parseGuid(meta: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, meta, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, trimmed, "guid:")) {
            return std.mem.trim(u8, trimmed["guid:".len..], " \r");
        }
    }
    return null;
}

test "buildIndex maps guid to asset path from .meta files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "Assets/Scripts");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Scripts/Player.cs", .data = "// code" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Scripts/Player.cs.meta", .data =
        \\fileFormatVersion: 2
        \\guid: 1234567890abcdef1234567890abcdef
        \\MonoImporter:
        \\  serializedVersion: 2
    });

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var index = try buildIndex(testing.io, arena, root);
    const path = index.get("1234567890abcdef1234567890abcdef").?;
    // Windows's walker/join returns `\`-separated paths, so build the expected value with native separators too.
    const want = try std.fs.path.join(arena, &.{ "Assets", "Scripts", "Player.cs" });
    try testing.expect(std.mem.endsWith(u8, path, want));
}
