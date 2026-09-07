const std = @import("std");
const core = @import("core");
const revision = @import("merge_revision.zig");
const merge_git = @import("merge_git.zig");
const support = @import("testing/git.zig");

const Case = struct { name: []const u8, conflict: bool, choice: ?[]const u8 = null };
const Manifest = struct { cases: []const Case };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or args.len > 3) return error.ExpectedFixtureRootAndOptionalOutputDirectory;
    const fixture_root = args[1];
    const export_root = if (args.len == 3) args[2] else null;
    const manifest_bytes = try read(init.io, arena, fixture_root, "expected-runtime.json");
    const manifest = try std.json.parseFromSlice(Manifest, arena, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    const scratch = try support.scratchDirectory(init.io, arena, "collections");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    for (manifest.value.cases) |case| try verify(init.io, arena, init.environ_map, fixture_root, scratch, export_root, case);
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(arena, "collection fixtures: {d} passed\n", .{manifest.value.cases.len}));
    return 0;
}

fn verify(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, fixture_root: []const u8, scratch: []const u8, export_root: ?[]const u8, case: Case) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, case.name });
    try std.Io.Dir.cwd().createDirPath(io, repo);
    try copyAssets(io, arena, try std.fs.path.join(arena, &.{ fixture_root, "unity", "Assets" }), try std.fs.path.join(arena, &.{ repo, "Assets" }));
    const git: merge_git.Git = .{ .io = io, .arena = arena, .env = env, .cwd = repo };
    try git.ok(&.{ "init", "-q" });
    try support.configureHermeticRepository(io, arena, repo);
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    const path = "Assets/Plain.prefab";
    const case_root = try std.fs.path.join(arena, &.{ fixture_root, "cases", case.name });
    var refs: [3][]const u8 = undefined;
    var inputs: [3][]const u8 = undefined;
    for ([_][]const u8{ "base.prefab", "ours.prefab", "theirs.prefab" }, 0..) |filename, index| {
        if (index == 2) try git.ok(&.{ "checkout", "-q", "--detach", refs[0] });
        inputs[index] = try read(io, arena, case_root, filename);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try git.path(path), .data = inputs[index] });
        try git.ok(&.{ "add", "--all" });
        try git.ok(&.{ "commit", "--allow-empty", "-qm", "collection fixture" });
        refs[index] = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    }
    var store = revision.Store.init(git);
    defer store.deinit();
    var snapshots: [3]core.merge_context.Snapshot = undefined;
    for (refs, 0..) |ref, index| snapshots[index] = try store.snapshot(ref);
    var built = core.merge.buildWithContext(arena, inputs[0], inputs[1], inputs[2], .{ .base = snapshots[0], .ours = snapshots[1], .theirs = snapshots[2], .output = snapshots[2] }) catch |err| {
        std.debug.print("collection fixture {s}: {s}\n", .{ case.name, @errorName(err) });
        return err;
    };
    const count = built.plan.unresolvedCount();
    if ((count != 0) != case.conflict) {
        std.debug.print("collection fixture {s}: expected conflict={}, got {d}\n", .{ case.name, case.conflict, count });
        return error.UnexpectedCollectionConflicts;
    }
    for (built.plan.operations) |operation| {
        if (operation.resolution != .unresolved) continue;
        const choice = case.choice orelse return error.MissingCollectionChoice;
        // A local fixture choice must preserve the independent accepted intervals.
        if (!std.mem.eql(u8, choice, "ours_first")) return error.InvalidCollectionChoice;
        const combined = try core.merge.combinedCollectionValue(arena, &built.plan, operation.id, .ours_first);
        try core.merge.resolve(arena, &built.plan, operation.id, .{ .custom = combined });
    }
    const output = try core.merge.finish(arena, &built.plan);
    if (export_root) |root| {
        const directory = try std.fs.path.join(arena, &.{ root, "cases", case.name });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ directory, "result.prefab" }), .data = output });
    }
    // These bytes have a separate Unity load check; a clean plan alone is insufficient.
    const expected = try read(io, arena, case_root, "expected.prefab");
    if (!std.mem.eql(u8, expected, output)) {
        std.debug.print("collection fixture output mismatch: {s}\n", .{case.name});
        return error.CollectionFixtureMismatch;
    }
}

fn read(io: std.Io, arena: std.mem.Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ root, relative }), arena, .limited(16 * 1024 * 1024));
}

fn copyAssets(io: std.Io, arena: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const path = try std.fs.path.join(arena, &.{ destination, entry.path });
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, path),
            .file => {
                try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
                const bytes = try directory.readFileAlloc(io, entry.path, arena, .limited(16 * 1024 * 1024));
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            },
            else => return error.UnsupportedFixtureEntry,
        }
    }
}
