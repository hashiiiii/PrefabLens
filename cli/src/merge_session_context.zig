const std = @import("std");
const core = @import("core");
const merge_git = @import("merge_git.zig");
const revision = @import("merge_revision.zig");
const Git = merge_git.Git;
const Context = core.merge_context.Context;

pub const Revisions = struct {
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    output: ?[]const u8 = null,
};
pub const Inputs = struct { base: []const u8, ours: []const u8, theirs: []const u8 };
pub const Paths = struct { base: []const u8, ours: []const u8, theirs: []const u8 };

pub const Index = struct {
    snapshot: core.merge_context.Snapshot,
    path: []const u8,
    before: []const u8,

    pub fn unchanged(self: Index, git: Git) !void {
        const now = try std.Io.Dir.cwd().readFileAlloc(git.io, self.path, git.arena, .limited(256 * 1024 * 1024));
        if (!std.mem.eql(u8, self.before, now)) return error.SourceChanged;
    }
};

// Remove unresolved entries only in a private index. A dependent cannot inherit
// from a source that still has competing versions in the user's index.
pub fn readIndex(store: *revision.Store) !Index {
    const git = store.git;
    const cwd = std.Io.Dir.cwd();
    const relative = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "index" }));
    const path = if (std.fs.path.isAbsolute(relative)) relative else try git.path(relative);
    const before = try cwd.readFileAlloc(git.io, path, git.arena, .limited(256 * 1024 * 1024));
    var random: [16]u8 = undefined;
    git.io.random(&random);
    const scratch = try std.fmt.allocPrint(git.arena, "{s}.prefablens-context-{x}", .{ path, random });
    const file = try cwd.createFile(git.io, scratch, .{ .exclusive = true });
    defer cwd.deleteFile(git.io, scratch) catch {};
    {
        defer file.close(git.io);
        try file.writeStreamingAll(git.io, before);
    }
    const absolute = try cwd.realPathFileAlloc(git.io, scratch, git.arena);
    var env = try git.env.clone(git.arena);
    try env.put("GIT_INDEX_FILE", absolute);
    var alternate = git;
    alternate.env = &env;
    const unmerged = try alternate.output(&.{ "ls-files", "--unmerged", "-z" });
    var records: std.ArrayList(u8) = .empty;
    var paths: std.StringHashMap(void) = .init(git.arena);
    var entries = std.mem.splitScalar(u8, unmerged, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse return error.InvalidIndex;
        var fields = std.mem.tokenizeScalar(u8, entry[0..tab], ' ');
        _ = fields.next() orelse return error.InvalidIndex;
        const oid = fields.next() orelse return error.InvalidIndex;
        const stage = fields.next() orelse return error.InvalidIndex;
        if (!validOid(oid) or fields.next() != null or stage.len != 1 or stage[0] < '1' or stage[0] > '3') return error.InvalidIndex;
        const item_path = entry[tab + 1 ..];
        if (item_path.len == 0) return error.InvalidIndex;
        if (paths.contains(item_path)) continue;
        try paths.put(item_path, {});
        const zero = try git.arena.alloc(u8, oid.len);
        @memset(zero, '0');
        try records.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "0 {s}\t{s}\x00", .{ zero, item_path }));
    }
    if (records.items.len != 0) try alternate.input(&.{ "update-index", "-z", "--index-info" }, records.items);
    const tree = merge_git.trim(try alternate.output(&.{"write-tree"}));
    if (!validOid(tree)) return error.InvalidTree;
    const output: Index = .{ .snapshot = try store.snapshot(tree), .path = path, .before = before };
    try output.unchanged(git);
    return output;
}

pub fn discover(git: Git) !?Revisions {
    const base = git.env.get("PREFABLENS_MERGE_BASE");
    const ours = git.env.get("PREFABLENS_MERGE_OURS");
    const theirs = git.env.get("PREFABLENS_MERGE_THEIRS");
    if (base != null or ours != null or theirs != null) {
        if (base == null or ours == null or theirs == null) return null;
        if (!validOid(base.?) or !validOid(ours.?) or !validOid(theirs.?)) return null;
        return .{
            .base = (try commitIdentity(git, base.?)) orelse return null,
            .ours = (try commitIdentity(git, ours.?)) orelse return null,
            .theirs = (try commitIdentity(git, theirs.?)) orelse return null,
        };
    }
    const merge_path_result = try git.run(&.{ "rev-parse", "--git-path", "MERGE_HEAD" });
    if (merge_git.exitCode(merge_path_result) != 0) return null;
    const merge_path = merge_git.trim(merge_path_result.stdout);
    const absolute = if (std.fs.path.isAbsolute(merge_path)) merge_path else try git.path(merge_path);
    const merge_head = std.Io.Dir.cwd().readFileAlloc(git.io, absolute, git.arena, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    const remote = merge_git.trim(merge_head);
    if (!validOid(remote)) return null;
    const local = (try commitIdentity(git, "HEAD")) orelse return null;
    const resolved_remote = (try commitIdentity(git, remote)) orelse return null;
    const bases = try git.run(&.{ "merge-base", "--all", local, resolved_remote });
    if (merge_git.exitCode(bases) != 0) return null;
    const ancestor = merge_git.trim(bases.stdout);
    if (!validOid(ancestor)) return null;
    return .{ .base = ancestor, .ours = local, .theirs = resolved_remote };
}

fn validOid(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn commitIdentity(git: Git, value: []const u8) !?[]const u8 {
    const expression = try std.fmt.allocPrint(git.arena, "{s}^{{commit}}", .{value});
    const result = try git.run(&.{ "rev-parse", "--verify", "--end-of-options", expression });
    if (merge_git.exitCode(result) != 0) return null;
    const oid = merge_git.trim(result.stdout);
    return if (validOid(oid)) oid else null;
}

// A historical script is evidence only for the exact blob supplied to this merge.
pub fn bind(store: *revision.Store, revisions: Revisions, paths: Paths, inputs: Inputs) !?Context {
    const base = try store.snapshot(revisions.base);
    const ours = try store.snapshot(revisions.ours);
    const theirs = try store.snapshot(revisions.theirs);
    if (!try matches(store.git, base.revision, paths.base, inputs.base) or
        !try matches(store.git, ours.revision, paths.ours, inputs.ours) or
        !try matches(store.git, theirs.revision, paths.theirs, inputs.theirs)) return null;
    return .{
        .base = base,
        .ours = ours,
        .theirs = theirs,
        .output = if (revisions.output) |output| try store.snapshot(output) else .{},
    };
}

fn matches(git: Git, tree: []const u8, path: []const u8, bytes: []const u8) !bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    const result = try git.run(&.{ "--literal-pathspecs", "ls-tree", "-z", "--full-tree", tree, "--", path });
    if (merge_git.exitCode(result) != 0) return false;
    const entry = result.stdout;
    if (entry.len == 0) return bytes.len == 0;
    if (entry[entry.len - 1] != 0 or std.mem.count(u8, entry, "\x00") != 1) return false;
    const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse return false;
    if (!std.mem.eql(u8, path, entry[tab + 1 .. entry.len - 1])) return false;
    var fields = std.mem.tokenizeScalar(u8, entry[0..tab], ' ');
    const mode = fields.next() orelse return false;
    const kind = fields.next() orelse return false;
    const oid = fields.next() orelse return false;
    if (fields.next() != null or !std.mem.eql(u8, kind, "blob") or
        (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755"))) return false;
    const blob = try git.run(&.{ "cat-file", "blob", oid });
    return merge_git.exitCode(blob) == 0 and std.mem.eql(u8, bytes, blob.stdout);
}

const testing = std.testing;
const script_guid = "11111111111111111111111111111111";
const asset_guid = "22222222222222222222222222222222";
const asset_path = "Assets/Thing.prefab";
const base_bytes = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ script_guid ++ ", type: 3}\n  values: 01000000i\n";
const ours_bytes = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ script_guid ++ ", type: 3}\n  values: 0100000002000000i\n";
const theirs_bytes = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: " ++ script_guid ++ ", type: 3}\n  values: 0100000003000000i\n";

fn fixtureGit(tmp: *testing.TmpDir, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Git {
    try env.put("PATH", "/usr/bin:/bin");
    const git: Git = .{ .io = testing.io, .arena = arena, .env = env, .cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", arena) };
    try git.ok(&.{ "init", "-q" });
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try git.ok(&.{ "config", "commit.gpgsign", "false" });
    try tmp.dir.createDir(testing.io, "Assets", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs", .data = "using UnityEngine; class Example : MonoBehaviour { public int[] values; }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs.meta", .data = "guid: " ++ script_guid ++ "\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = asset_path ++ ".meta", .data = "guid: " ++ asset_guid ++ "\n" });
    return git;
}
fn fixtureCommit(git: Git, bytes: []const u8) ![]const u8 {
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = try git.path(asset_path), .data = bytes });
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "fixture" });
    return merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
}

test "session context binds exact historical inputs and ignores dirty declarations" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    const base = try fixtureCommit(git, base_bytes);
    const ours = try fixtureCommit(git, ours_bytes);
    try git.ok(&.{ "checkout", "-q", "--detach", base });
    const theirs = try fixtureCommit(git, theirs_bytes);
    const output = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD^{tree}" }));
    // Unstaged scripts are not part of any input revision or selected output tree.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Example.cs", .data = "broken dirty source" });
    var store = revision.Store.init(git);
    defer store.deinit();
    const paths: Paths = .{ .base = asset_path, .ours = asset_path, .theirs = asset_path };
    const inputs: Inputs = .{ .base = base_bytes, .ours = ours_bytes, .theirs = theirs_bytes };
    const revisions: Revisions = .{ .base = base, .ours = ours, .theirs = theirs, .output = output };
    const context = (try bind(&store, revisions, paths, inputs)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(core.merge_context.Kind.int32_array, context.base.kind(script_guid, "values").?);
    try testing.expectEqualStrings(ours_bytes, context.ours.asset(asset_guid).?.bytes);
    try testing.expectEqualStrings(theirs_bytes, context.theirs.asset(asset_guid).?.bytes);
    try testing.expectEqualStrings(output, context.output.revision);
    // A manually edited temporary input cannot borrow a matching path's old type proof.
    try testing.expectEqual(null, try bind(&store, revisions, paths, .{ .base = base_bytes, .ours = "edited input", .theirs = theirs_bytes }));
    try testing.expectEqual(null, try bind(&store, revisions, .{ .base = "Assets/Missing.prefab", .ours = asset_path, .theirs = asset_path }, inputs));
}

test "session context discovers only complete strategy revisions or a single merge head" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    const base = try fixtureCommit(git, base_bytes);
    const ours = try fixtureCommit(git, ours_bytes);
    try git.ok(&.{ "checkout", "-q", "--detach", base });
    const theirs = try fixtureCommit(git, theirs_bytes);
    try git.ok(&.{ "checkout", "-q", "--detach", ours });
    // HEAD alone cannot identify the other side of a file-driver invocation.
    try testing.expectEqual(null, try discover(git));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/MERGE_HEAD", .data = try std.fmt.allocPrint(arena, "{s}\n", .{theirs}) });
    const merging = (try discover(git)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(base, merging.base);
    try testing.expectEqualStrings(ours, merging.ours);
    try testing.expectEqualStrings(theirs, merging.theirs);
    // Octopus sources cannot be assigned to one Theirs snapshot.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/MERGE_HEAD", .data = try std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ theirs, base }) });
    try testing.expectEqual(null, try discover(git));
    try env.put("PREFABLENS_MERGE_BASE", base);
    try testing.expectEqual(null, try discover(git));
    try env.put("PREFABLENS_MERGE_OURS", ours);
    try env.put("PREFABLENS_MERGE_THEIRS", theirs);
    const explicit = (try discover(git)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(theirs, explicit.theirs);
    // Internal handoff accepts immutable identities, never branch names that can move.
    try env.put("PREFABLENS_MERGE_OURS", "HEAD");
    try testing.expectEqual(null, try discover(git));
}

test "session context omits unresolved output sources and detects index changes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    const clean_guid = "33333333333333333333333333333333";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Clean.prefab", .data = base_bytes });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Clean.prefab.meta", .data = "guid: " ++ clean_guid ++ "\n" });
    const base = try fixtureCommit(git, base_bytes);
    const ours = try fixtureCommit(git, ours_bytes);
    try git.ok(&.{ "checkout", "-q", "--detach", base });
    const theirs = try fixtureCommit(git, theirs_bytes);
    try git.ok(&.{ "checkout", "-q", "--detach", ours });
    const merge_result = try git.run(&.{ "merge", "--no-commit", theirs });
    try testing.expectEqual(@as(u8, 1), merge_git.exitCode(merge_result));
    const unmerged_before = try git.output(&.{ "ls-files", "--unmerged", "-z" });
    try testing.expect(unmerged_before.len != 0);
    var store = revision.Store.init(git);
    defer store.deinit();
    // A marker-bearing source is not a selected source result for any dependent Variant.
    const output = try readIndex(&store);
    try testing.expectEqual(null, output.snapshot.asset(asset_guid));
    try testing.expectEqualStrings(base_bytes, output.snapshot.asset(clean_guid).?.bytes);
    try testing.expectEqualStrings(unmerged_before, try git.output(&.{ "ls-files", "--unmerged", "-z" }));
    try output.unchanged(git);
    // A later source decision invalidates plans that still use the old output snapshot.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = asset_path, .data = ours_bytes });
    try git.ok(&.{ "add", "--", asset_path });
    try testing.expectError(error.SourceChanged, output.unchanged(git));
    const refreshed = try readIndex(&store);
    try testing.expectEqualStrings(ours_bytes, refreshed.snapshot.asset(asset_guid).?.bytes);
}
