const std = @import("std");
const core = @import("core");
const testing = std.testing;

/// guid -> project-relative asset path ("Assets/..."), the form Unity users
/// read and the extension shows. Same type as core.json.Resolver, so it can be
/// passed through directly; callers join with the project root to open files.
pub const Index = core.json.Resolver;

/// Unity puts "guid:" on the second line of every .meta; 4 KiB covers any
/// importer header, and reading only the head keeps the scan I/O-minimal.
const meta_head_bytes = 4096;

/// Concurrent .meta readers. Measured on a 50k-.meta tree (macOS/ARM): 2-4
/// readers ~350 ms where serial takes ~700 ms, and 8+ regresses to worse than
/// serial on APFS — so the count is capped, not scaled to the machine.
const max_readers = 4;

/// Full index of every .meta under `project_root` — the explicit --project
/// path. An unreadable root is an error (surfaced as "cannot read project
/// directory" by the caller).
pub fn buildIndex(io: std.Io, arena: std.mem.Allocator, project_root: []const u8) !Index {
    return scan(io, arena, project_root, &.{""}, &.{});
}

/// Index for default resolution: scans only Assets/ and Packages/ (the only
/// trees Unity puts .meta files in), skips the ones that don't exist, and
/// stops early once every guid in `wanted` (deduplicated by the caller) has
/// been found.
pub fn buildIndexFor(io: std.Io, arena: std.mem.Allocator, project_root: []const u8, wanted: []const []const u8) !Index {
    return scan(io, arena, project_root, &.{ "Assets", "Packages" }, wanted);
}

/// A guid found by a scan worker; fixed storage so workers never allocate
/// (the shared arena is not thread-safe). Unity guids are 32 hex chars.
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

    // Serial walk collecting .meta paths — ~20 ms even at 50k files; the
    // per-file open+read below is the cost worth spreading across readers.
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
    // Relative to the root, never joined with it: the display form ("Assets/...")
    // the extension shows; Windows walkers emit `\`, so compare natively.
    const want = try std.fs.path.join(arena, &.{ "Assets", "Scripts", "Player.cs" });
    try testing.expectEqualStrings(want, path);
}

test "buildIndexFor scans only Assets and Packages and skips missing subroots" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // No Packages/ here — it must be skipped, not error.
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

test "buildIndexFor returns an empty index when no asset trees exist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var index = try buildIndexFor(testing.io, arena, root, &.{"aaa111"});
    try testing.expectEqual(@as(?[]const u8, null), index.get("aaa111"));
}
