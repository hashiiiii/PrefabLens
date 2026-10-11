const std = @import("std");
const core = @import("core");
const testing = std.testing;

/// Maps GUIDs to project-relative asset paths, such as "Assets/...", matching Unity and extension displays.
/// This is core.json.Resolver, so callers can pass it directly. Join paths with the project root to open files.
pub const Index = core.json.Resolver;

/// Unity puts "guid:" on the second line of each .meta file. Reading the first 4 KiB covers importer headers without loading entire files.
const meta_head_bytes = 4096;

/// On a 50,000-file .meta tree on macOS/ARM, 2-4 readers took about 350 ms; serial reads took about 700 ms.
/// Eight or more readers were slower than serial reads on APFS, so concurrency is capped rather than scaled to CPU count.
const max_readers = 4;

/// Indexes every .meta file under project_root for explicit --project resolution.
/// An unreadable root returns an error, reported by the caller as "cannot read project directory".
pub fn buildIndex(io: std.Io, arena: std.mem.Allocator, project_root: []const u8) !Index {
    return scan(io, arena, project_root, &.{""}, &.{});
}

/// Default resolution scans Assets/ and Packages/, skipping directories that do not exist.
/// It stops once every GUID in wanted, deduplicated by the caller, has been found.
pub fn buildIndexFor(io: std.Io, arena: std.mem.Allocator, project_root: []const u8, wanted: []const []const u8) !Index {
    return scan(io, arena, project_root, &.{ "Assets", "Packages" }, wanted);
}

/// Fixed storage avoids allocating from the shared arena, which is not thread-safe. Unity GUIDs contain 32 hexadecimal characters.
const FoundGuid = struct {
    len: u8 = 0,
    buf: [64]u8 = undefined,
};

const Scan = struct {
    io: std.Io,
    dir: std.Io.Dir,
    /// .meta paths relative to the project root; slot i's guid lands in results[i].
    paths: []const []const u8,
    results: []FoundGuid,
    cursor: std.atomic.Value(usize) = .init(0),
    /// Early exit: guid -> claims slot; remaining counts unclaimed wanted guids.
    /// Read-only during the scan (built before workers start), so lock-free.
    wanted: std.StringHashMapUnmanaged(usize) = .empty,
    claims: []std.atomic.Value(bool) = &.{},
    remaining: std.atomic.Value(isize) = .init(0),

    fn done(s: *const Scan) bool {
        return s.wanted.size != 0 and s.remaining.load(.monotonic) <= 0;
    }

    fn worker(s: *Scan) void {
        var buf: [meta_head_bytes]u8 = undefined;
        while (!s.done()) {
            const i = s.cursor.fetchAdd(1, .monotonic);
            if (i >= s.paths.len) return;
            // An unreadable .meta degrades to that one guid staying unresolved.
            const head = s.dir.readFile(s.io, s.paths[i], &buf) catch continue;
            const guid = parseGuid(head) orelse continue;
            if (guid.len > s.results[i].buf.len) continue;
            @memcpy(s.results[i].buf[0..guid.len], guid);
            s.results[i].len = @intCast(guid.len);
            if (s.wanted.get(guid)) |slot| {
                // swap dedups double-claims (e.g. a copied .meta repeating a guid).
                if (!s.claims[slot].swap(true, .monotonic)) {
                    _ = s.remaining.fetchSub(1, .monotonic);
                }
            }
        }
    }
};

fn scan(
    io: std.Io,
    arena: std.mem.Allocator,
    project_root: []const u8,
    subroots: []const []const u8,
    wanted: []const []const u8,
) !Index {
    var index = Index.init(arena);
    var root = try std.Io.Dir.cwd().openDir(io, project_root, .{});
    defer root.close(io);

    // Walking 50,000 files took about 20 ms. Opening and reading each file costs more, so only those reads are parallel.
    var paths: std.ArrayList([]const u8) = .empty;
    for (subroots) |sub| {
        var dir = if (sub.len == 0)
            try root.openDir(io, ".", .{ .iterate = true })
        else
            // A named subroot is optional: not every project has Packages/.
            root.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".meta")) continue;
            const rel = if (sub.len == 0)
                try arena.dupe(u8, entry.path)
            else
                try std.fs.path.join(arena, &.{ sub, entry.path });
            try paths.append(arena, rel);
        }
    }
    if (paths.items.len == 0) return index;

    var state: Scan = .{
        .io = io,
        .dir = root,
        .paths = paths.items,
        .results = try arena.alloc(FoundGuid, paths.items.len),
    };
    @memset(state.results, .{});
    if (wanted.len != 0) {
        state.claims = try arena.alloc(std.atomic.Value(bool), wanted.len);
        @memset(state.claims, std.atomic.Value(bool).init(false));
        var unique: isize = 0;
        for (wanted, 0..) |g, slot| {
            const gop = try state.wanted.getOrPut(arena, g);
            if (gop.found_existing) continue;
            gop.value_ptr.* = slot;
            unique += 1;
        }
        state.remaining.store(unique, .monotonic);
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    const readers = @max(1, @min(max_readers, cpus));
    var group: std.Io.Group = .init;
    for (0..readers) |_| group.async(io, Scan.worker, .{&state});
    try group.await(io);

    for (state.paths, state.results) |path, found| {
        if (found.len == 0) continue;
        // Asset path = the .meta path without the trailing ".meta".
        try index.put(try arena.dupe(u8, found.buf[0..found.len]), path[0 .. path.len - ".meta".len]);
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

test "buildIndex maps guid to a project-relative asset path" {
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
    // Display paths must stay project-relative. Native path joining accounts for Windows directory separators.
    const want = try std.fs.path.join(arena, &.{ "Assets", "Scripts", "Player.cs" });
    try testing.expectEqualStrings(want, path);
}

test "buildIndexFor scans only Assets and Packages and skips missing subroots" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A project without Packages/ must still resolve references from Assets/.
    try tmp.dir.createDirPath(testing.io, "Assets");
    try tmp.dir.createDirPath(testing.io, "Library");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Robot.prefab.meta", .data = "fileFormatVersion: 2\nguid: aaa111\n" });
    // Library/ is not an asset tree; a .meta there must never be indexed.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Library/Stray.asset.meta", .data = "fileFormatVersion: 2\nguid: bbb222\n" });

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var index = try buildIndexFor(testing.io, arena, root, &.{ "aaa111", "bbb222" });
    const want = try std.fs.path.join(arena, &.{ "Assets", "Robot.prefab" });
    try testing.expectEqualStrings(want, index.get("aaa111").?);
    try testing.expectEqual(@as(?[]const u8, null), index.get("bbb222"));
}
