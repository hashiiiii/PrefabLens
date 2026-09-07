const std = @import("std");
const merge_git = @import("merge_git.zig");
const context = @import("merge_session_context.zig");
const Git = merge_git.Git;

pub const Sources = struct {
    ours: []const u8,
    theirs: []const u8,
    bases: []const []const u8,
    known: ?context.Revisions,

    pub fn apply(self: Sources, env: *std.process.Environ.Map) !void {
        // An inherited handoff can describe another merge, including a recursive driver call.
        for ([_][]const u8{ "PREFABLENS_MERGE_BASE", "PREFABLENS_MERGE_OURS", "PREFABLENS_MERGE_THEIRS" }) |key| _ = env.swapRemove(key);
        if (self.known) |known| {
            try env.put("PREFABLENS_MERGE_BASE", known.base);
            try env.put("PREFABLENS_MERGE_OURS", known.ours);
            try env.put("PREFABLENS_MERGE_THEIRS", known.theirs);
        }
    }
};

pub fn read(git: Git, local: []const u8, remote: []const u8) !Sources {
    const ours = try identity(git, local);
    const theirs = try identity(git, remote);
    const result = try git.run(&.{ "merge-base", "--all", ours, theirs });
    const code = merge_git.exitCode(result);
    if (code > 1) return error.GitCommandFailed;
    var bases: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    while (lines.next()) |oid| {
        if (!validOid(oid)) return error.InvalidRevision;
        try bases.append(git.arena, oid);
    }
    if (code == 1 and bases.items.len != 0) return error.InvalidRevision;
    const ancestors = try bases.toOwnedSlice(git.arena);
    return .{
        .ours = ours,
        .theirs = theirs,
        .bases = ancestors,
        .known = if (ancestors.len == 1) .{ .base = ancestors[0], .ours = ours, .theirs = theirs } else null,
    };
}

fn identity(git: Git, name: []const u8) ![]const u8 {
    const expression = try std.fmt.allocPrint(git.arena, "{s}^{{commit}}", .{name});
    const oid = merge_git.trim(try git.output(&.{ "rev-parse", "--verify", "--end-of-options", expression }));
    if (!validOid(oid)) return error.InvalidRevision;
    return oid;
}

fn validOid(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

const testing = std.testing;

fn commit(git: Git, parents: []const []const u8, message: []const u8) ![]const u8 {
    const tree = merge_git.trim(try git.output(&.{"write-tree"}));
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "commit-tree", tree, "-m", message });
    for (parents) |parent| try args.appendSlice(git.arena, &.{ "-p", parent });
    return merge_git.trim(try git.output(args.items));
}

fn fixture(tmp: *testing.TmpDir, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Git {
    try env.put("PATH", "/usr/bin:/bin");
    const git: Git = .{ .io = testing.io, .arena = arena, .env = env, .cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", arena) };
    try git.ok(&.{ "init", "-q" });
    try @import("testing/git.zig").configureHermeticRepository(testing.io, arena, git.cwd);
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try git.ok(&.{ "read-tree", "--empty" });
    return git;
}

test "strategy revisions: use immutable commits and replace inherited handoff" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixture(&tmp, arena, &env);
    const base = try commit(git, &.{}, "base");
    const ours = try commit(git, &.{base}, "ours");
    const theirs = try commit(git, &.{base}, "theirs");
    try git.ok(&.{ "update-ref", "refs/heads/local", ours });
    try git.ok(&.{ "symbolic-ref", "HEAD", "refs/heads/local" });
    try git.ok(&.{ "update-ref", "refs/heads/remote", theirs });
    try env.put("PREFABLENS_MERGE_BASE", theirs);
    try env.put("PREFABLENS_MERGE_OURS", base);
    try env.put("PREFABLENS_MERGE_THEIRS", "invalid");
    const sources = try read(git, "HEAD", "remote");
    try sources.apply(&env);
    try testing.expectEqualStrings(base, sources.known.?.base);
    try testing.expectEqualStrings(ours, sources.ours);
    try testing.expectEqualStrings(theirs, sources.theirs);
    try testing.expectEqualStrings(base, env.get("PREFABLENS_MERGE_BASE").?);
    try testing.expectEqualStrings(ours, env.get("PREFABLENS_MERGE_OURS").?);
    try testing.expectEqualStrings(theirs, env.get("PREFABLENS_MERGE_THEIRS").?);
    try git.ok(&.{ "update-ref", "refs/heads/local", base });
    try testing.expectEqualStrings(ours, sources.ours);
}

test "strategy revisions: retain all real bases and clear unknown context" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixture(&tmp, arena, &env);
    const root = try commit(git, &.{}, "root");
    const left = try commit(git, &.{root}, "left");
    const right = try commit(git, &.{root}, "right");
    const ours = try commit(git, &.{ left, right }, "merge left");
    const theirs = try commit(git, &.{ right, left }, "merge right");
    const unrelated = try commit(git, &.{}, "unrelated");
    for ([_][]const u8{ theirs, unrelated }, [_]usize{ 2, 0 }) |remote, count| {
        for ([_][]const u8{ "PREFABLENS_MERGE_BASE", "PREFABLENS_MERGE_OURS", "PREFABLENS_MERGE_THEIRS" }) |key| try env.put(key, root);
        const sources = try read(git, ours, remote);
        try sources.apply(&env);
        try testing.expectEqual(@as(?context.Revisions, null), sources.known);
        try testing.expectEqual(count, sources.bases.len);
        if (count == 2) {
            try testing.expect(std.mem.eql(u8, left, sources.bases[0]) or std.mem.eql(u8, left, sources.bases[1]));
            try testing.expect(std.mem.eql(u8, right, sources.bases[0]) or std.mem.eql(u8, right, sources.bases[1]));
        }
        for ([_][]const u8{ "PREFABLENS_MERGE_BASE", "PREFABLENS_MERGE_OURS", "PREFABLENS_MERGE_THEIRS" }) |key| try testing.expect(env.get(key) == null);
    }
}
