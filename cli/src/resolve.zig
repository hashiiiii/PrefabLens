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

        // Asset path = the .meta path without the trailing ".meta".
        const asset_rel = entry.path[0 .. entry.path.len - ".meta".len];
        // Store an owned copy of the guid key (slice into meta_bytes is fine since arena-lived).
        try index.put(try arena.dupe(u8, guid), try assetPath(arena, project_root, asset_rel));
    }
    return index;
}

/// Display path for a resolved asset: prefixed with the project root, except a
/// "." root stays project-relative ("Assets/...") — the form Unity users read
/// and the extension shows.
fn assetPath(arena: std.mem.Allocator, project_root: []const u8, asset_rel: []const u8) ![]const u8 {
    if (std.mem.eql(u8, project_root, ".")) return arena.dupe(u8, asset_rel);
    return std.fs.path.join(arena, &.{ project_root, asset_rel });
}

test "assetPath keeps a '.' root project-relative and joins real roots" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "." would only prepend noise ("./Assets/...") to every displayed path.
    try testing.expectEqualStrings("Assets/S/P.cs", try assetPath(arena, ".", "Assets/S/P.cs"));
    // Any other root still prefixes, so out-of-cwd projects resolve to real locations.
    const joined = try assetPath(arena, "/proj", "Assets/S/P.cs");
    const want = try std.fs.path.join(arena, &.{ "/proj", "Assets/S/P.cs" });
    try testing.expectEqualStrings(want, joined);
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
