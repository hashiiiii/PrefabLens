const std = @import("std");
const Git = @import("merge_git.zig").Git;
const schema = @import("merge_csharp.zig");
const context = @import("core").merge_context;
const testing = std.testing;

// All returned slices belong to git.arena. Keep that arena alive while using
// snapshots. No source file or metadata is read from the current worktree.
pub const Store = struct {
    git: Git,
    objects: std.StringHashMapUnmanaged([]const u8) = .empty,
    cached_bytes: usize = 0,

    pub fn init(git: Git) Store {
        return .{ .git = git };
    }
    pub fn deinit(self: *Store) void {
        self.objects.deinit(self.git.arena);
    }
    pub fn cachedObjectCount(self: *const Store) usize {
        return self.objects.count();
    }
    pub fn snapshot(self: *Store, revision: []const u8) !context.Snapshot {
        const arena = self.git.arena;
        // Peel annotated tags without forcing a candidate tree into a commit.
        // ls-tree accepts only commits/trees, and all later IO uses this identity.
        const expression = try std.fmt.allocPrint(arena, "{s}^{{}}", .{revision});
        const identity = @import("merge_git.zig").trim(try self.git.output(&.{ "rev-parse", "--verify", "--end-of-options", expression }));
        if (!validOid(identity)) return error.InvalidRevision;
        const tree = try self.git.output(&.{ "ls-tree", "-r", "-z", "-l", identity });
        var entries: std.ArrayList(Entry) = .empty;
        var records = std.mem.splitScalar(u8, tree, 0);
        var names: schema.Names = .{};
        var ambiguous_metadata = false;
        while (records.next()) |record| {
            if (record.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidTree;
            var columns = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
            const mode = columns.next() orelse return error.InvalidTree;
            const object_type = columns.next() orelse return error.InvalidTree;
            const oid = columns.next() orelse return error.InvalidTree;
            const size_token = columns.next() orelse return error.InvalidTree;
            if (columns.next() != null or !validOid(oid)) return error.InvalidTree;
            const path = record[tab + 1 ..];
            const regular = std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755");
            if (!regular or ends(path, ".dll") or ends(path, ".asmdef") or ends(path, ".asmref") or ends(path, ".rsp")) names = .unknown;
            if (!regular and ends(path, ".meta")) ambiguous_metadata = true;
            if (!regular or !std.mem.eql(u8, object_type, "blob")) continue;
            if (!ends(path, ".cs") and !ends(path, ".meta") and !isAsset(path)) continue;
            const size = try std.fmt.parseInt(usize, size_token, 10);
            if (size > max_object_bytes) return error.SourceTooLarge;
            try entries.append(arena, .{ .path = path, .oid = oid, .size = size });
        }
        var batch = try Batch.init(self.git);
        defer batch.child.kill(self.git.io);
        var guids: std.StringHashMapUnmanaged(usize) = .empty;
        defer guids.deinit(arena);
        var paths: std.StringHashMapUnmanaged(usize) = .empty;
        defer paths.deinit(arena);
        var declarations: std.StringHashMapUnmanaged(usize) = .empty;
        defer declarations.deinit(arena);
        for (entries.items, 0..) |*entry, i| {
            entry.bytes = try self.blob(&batch, entry.*);
            try paths.put(arena, entry.path, i);
            if (ends(entry.path, ".cs")) {
                try schema.inspectNames(arena, entry.bytes, &names);
                for (try schema.declaredNames(arena, entry.bytes)) |name| {
                    const count = try declarations.getOrPut(arena, name);
                    if (!count.found_existing) count.value_ptr.* = 0;
                    count.value_ptr.* += 1;
                }
            }
            if (ends(entry.path, ".meta")) {
                entry.guid = try metadataGuid(arena, entry.bytes);
                if (entry.guid == null) ambiguous_metadata = true;
                if (entry.guid) |guid| {
                    const count = try guids.getOrPut(arena, guid);
                    if (!count.found_existing) count.value_ptr.* = 0;
                    count.value_ptr.* += 1;
                }
            }
        }
        try batch.finish(self.git.io);
        // Malformed or linked metadata prevents proving repository-wide GUID
        // uniqueness, including GUIDs that appear in otherwise valid metadata.
        if (ambiguous_metadata) return .{ .revision = identity };
        var assets: std.ArrayList(context.Asset) = .empty;
        var scripts: std.ArrayList(context.Script) = .empty;
        for (entries.items) |entry| {
            if (ends(entry.path, ".meta")) continue;
            const meta_path = try std.fmt.allocPrint(arena, "{s}.meta", .{entry.path});
            const meta_index = paths.get(meta_path) orelse continue;
            const guid = entries.items[meta_index].guid orelse continue;
            if (guids.get(guid).? != 1) continue;
            if (isAsset(entry.path)) {
                try assets.append(arena, .{ .guid = guid, .path = entry.path, .bytes = entry.bytes });
            } else if (ends(entry.path, ".cs")) {
                const filename = std.fs.path.basename(entry.path);
                const class_name = filename[0 .. filename.len - 3];
                var fields: std.ArrayList(context.Field) = .empty;
                if ((declarations.get(class_name) orelse 0) == 1) {
                    for (try schema.read(arena, entry.bytes, class_name, names)) |field| {
                        try fields.append(arena, .{ .path = field.name, .dictionary_equality = switch (field.dictionary_equality) {
                            .unknown => .unknown,
                            .default => .default,
                        }, .dictionary_value = if (field.dictionary_value) |value| switch (value) {
                            .int32 => .int32,
                            .string => .string,
                        } else null, .kind = switch (field.kind) {
                            .ordered_array => .ordered,
                            .int32_array => .int32_array,
                            .string_dictionary => .string_dictionary,
                            .int32_dictionary => .int32_dictionary,
                        } });
                    }
                }
                try scripts.append(arena, .{ .guid = guid, .class_name = class_name, .source_hash = entry.oid, .fields = fields.items });
            }
        }
        return .{ .revision = identity, .assets = assets.items, .scripts = scripts.items };
    }
    fn blob(self: *Store, batch: *Batch, entry: Entry) ![]const u8 {
        if (self.objects.get(entry.oid)) |bytes| return bytes;
        if (entry.size > max_cached_bytes - self.cached_bytes) return error.ContextTooLarge;
        const io = self.git.io;
        // Exactly one tiny request is outstanding. Drain its body before writing
        // another request, even when the body is larger than the OS pipe buffer.
        try batch.child.stdin.?.writeStreamingAll(io, try std.fmt.allocPrint(self.git.arena, "{s}\n", .{entry.oid}));
        const reader = &batch.reader.interface;
        const header = try reader.takeDelimiterExclusive('\n');
        var parts = std.mem.splitScalar(u8, header, ' ');
        const oid = parts.next() orelse return error.InvalidObject;
        const kind = parts.next() orelse return error.InvalidObject;
        const size = try std.fmt.parseInt(usize, parts.next() orelse return error.InvalidObject, 10);
        if (!std.mem.eql(u8, oid, entry.oid) or !std.mem.eql(u8, kind, "blob") or parts.next() != null or size != entry.size) return error.InvalidObject;
        if (size > max_object_bytes) return error.SourceTooLarge;
        if (try reader.takeByte() != '\n') return error.InvalidObject;
        const bytes = try reader.readAlloc(self.git.arena, size);
        if (try reader.takeByte() != '\n') return error.InvalidObject;
        try self.objects.put(self.git.arena, entry.oid, bytes);
        self.cached_bytes += bytes.len;
        return bytes;
    }
};
const max_object_bytes = 64 * 1024 * 1024;
const max_cached_bytes = 256 * 1024 * 1024;
const Entry = struct { path: []const u8, oid: []const u8, size: usize, bytes: []const u8 = "", guid: ?[]const u8 = null };
const Batch = struct {
    child: std.process.Child,
    reader: std.Io.File.Reader,
    fn init(git: Git) !Batch {
        var child = try std.process.spawn(git.io, .{
            .argv = &.{ "git", "cat-file", "--batch" },
            .cwd = .{ .path = git.cwd },
            .environ_map = git.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(git.io);
        return .{ .child = child, .reader = child.stdout.?.readerStreaming(git.io, try git.arena.alloc(u8, 4096)) };
    }
    fn finish(self: *Batch, io: std.Io) !void {
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = try self.child.wait(io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }
};
fn ends(path: []const u8, suffix: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, suffix);
}
fn isAsset(path: []const u8) bool {
    return ends(path, ".prefab") or ends(path, ".unity") or ends(path, ".asset");
}
fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
pub fn metadataGuid(arena: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "guid:")) continue;
        if (result != null) return null;
        const value = std.mem.trim(u8, line[5..], " \t\r");
        if (value.len != 32) return null;
        for (value) |byte| if (!std.ascii.isHex(byte)) return null;
        result = try std.ascii.allocLowerString(arena, value);
    }
    return result;
}

fn fixtureGit(tmp: *testing.TmpDir, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Git {
    try env.put("PATH", "/usr/bin:/bin");
    const git: Git = .{ .io = testing.io, .arena = arena, .env = env, .cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", arena) };
    try git.ok(&.{ "init", "-q" });
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try git.ok(&.{ "config", "commit.gpgsign", "false" });
    return git;
}
fn fixtureCommit(git: Git) ![]const u8 {
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "fixture" });
    return @import("merge_git.zig").trim(try git.output(&.{ "rev-parse", "HEAD" }));
}
fn fixtureWrite(tmp: *testing.TmpDir, path: []const u8, bytes: []const u8) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
}
const script_guid = "11111111111111111111111111111111";
const asset_guid = "22222222222222222222222222222222";

test "revision snapshots preserve divergent source and cache blobs independently of dirty worktree" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try tmp.dir.createDir(testing.io, "With spaces", .default_dir);
    try fixtureWrite(&tmp, "With spaces/Example.cs", "using UnityEngine; class Example : MonoBehaviour { public int[] values; }");
    try fixtureWrite(&tmp, "With spaces/Example.cs.meta", "fileFormatVersion: 2\nguid: " ++ script_guid ++ "\n");
    try fixtureWrite(&tmp, "With spaces/Thing.prefab", "base asset bytes\n");
    try fixtureWrite(&tmp, "With spaces/Thing.prefab.meta", "guid: " ++ asset_guid ++ "\n");
    try fixtureWrite(&tmp, "ignored.bin", "\x00\xffnot source");
    const base = try fixtureCommit(git);
    try fixtureWrite(&tmp, "With spaces/Example.cs", "using UnityEngine; class Example : MonoBehaviour { public string[] values; }");
    const ours = try fixtureCommit(git);
    try git.ok(&.{ "checkout", "-q", "--detach", base });
    try fixtureWrite(&tmp, "With spaces/Example.cs", "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string, int> values; }");
    const theirs = try fixtureCommit(git);
    try fixtureWrite(&tmp, "With spaces/Example.cs", "broken dirty source");
    try fixtureWrite(&tmp, "With spaces/Thing.prefab", "dirty asset");
    var store = Store.init(git);
    defer store.deinit();
    const b = try store.snapshot(base);
    const cached = store.cachedObjectCount();
    const o = try store.snapshot(ours);
    const t = try store.snapshot(theirs);
    const repeat = try store.snapshot(base);
    try testing.expectEqual(context.Kind.int32_array, b.kind(script_guid, "values").?);
    try testing.expectEqual(context.Kind.ordered, o.kind(script_guid, "values").?);
    try testing.expectEqual(context.Kind.string_dictionary, t.kind(script_guid, "values").?);
    try testing.expectEqual(context.ValueType.int32, t.field(script_guid, "values").?.dictionary_value.?);
    try testing.expectEqualStrings("base asset bytes\n", repeat.asset(asset_guid).?.bytes);
    try testing.expectEqualStrings(base, b.revision);
    try testing.expectEqual(cached + 2, store.cachedObjectCount());
}

test "revision snapshots decline absent metadata duplicate GUIDs and unknown assembly evidence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; class Example : MonoBehaviour { public int[] values; }");
    const absent = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    try fixtureWrite(&tmp, "other.txt.meta", "guid: " ++ script_guid ++ "\n");
    const duplicate = try fixtureCommit(git);
    try fixtureWrite(&tmp, "other.txt.meta", "guid: 33333333333333333333333333333333\n");
    try fixtureWrite(&tmp, "Library.dll", "unknown assembly bytes");
    const assembly = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    for ([_][]const u8{ absent, duplicate, assembly }) |revision| {
        try testing.expectEqual(null, (try store.snapshot(revision)).kind(script_guid, "values"));
    }
}

test "revision batch drains large objects and ignores non-source object contents" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    const large = try arena.alloc(u8, 2 * 1024 * 1024);
    @memset(large, 'x');
    try fixtureWrite(&tmp, "Large.prefab", large);
    try fixtureWrite(&tmp, "Large.prefab.meta", "guid: " ++ asset_guid ++ "\n");
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; class Example : MonoBehaviour { public int[] values; }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    try fixtureWrite(&tmp, "Fake.cs.txt", "class MonoBehaviour {} class Dictionary {} #bad syntax");
    const revision = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    const snapshot = try store.snapshot(revision);
    try testing.expectEqualSlices(u8, large, snapshot.asset(asset_guid).?.bytes);
    try testing.expectEqual(context.Kind.int32_array, snapshot.kind(script_guid, "values").?);
    try testing.expectEqual(@as(usize, 4), store.cachedObjectCount());
}

test "revision evidence detects cross-file class ambiguity and does not follow symlinks" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; namespace Game { class Example : MonoBehaviour { public int[] values; } }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    try fixtureWrite(&tmp, "Other.cs", "namespace Other { class Example {} }");
    const ambiguous = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Other.cs", "class Unrelated {}");
    try tmp.dir.symLink(testing.io, "Example.cs", "Linked.cs", .{});
    try fixtureWrite(&tmp, "Linked.cs.meta", "guid: " ++ asset_guid ++ "\n");
    const linked = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    try testing.expectEqual(null, (try store.snapshot(ambiguous)).kind(script_guid, "values"));
    const snapshot = try store.snapshot(linked);
    try testing.expectEqual(null, snapshot.kind(script_guid, "values"));
    try testing.expectEqual(null, snapshot.kind(asset_guid, "values"));
}

test "revision snapshot rejects oversized source before loading object bytes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    const file = try tmp.dir.createFile(testing.io, "Oversized.cs", .{});
    try file.setLength(testing.io, max_object_bytes + 1);
    file.close(testing.io);
    const revision = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    try testing.expectError(error.SourceTooLarge, store.snapshot(revision));
    try testing.expectEqual(@as(usize, 0), store.cachedObjectCount());
}

test "malformed duplicate metadata still invalidates a reused GUID" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; class Example : MonoBehaviour { public int[] values; }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    try fixtureWrite(&tmp, "Other.txt.meta", "guid: " ++ script_guid ++ "\nguid: 33333333333333333333333333333333\n");
    const revision = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    try testing.expectEqual(null, (try store.snapshot(revision)).kind(script_guid, "values"));
}

test "candidate tree snapshot is distinct from historical commit and dirty worktree" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; class Example : MonoBehaviour { public int[] values; }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    const historical = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; class Example : MonoBehaviour { public string[] values; }");
    try git.ok(&.{ "add", "--", "Example.cs" });
    const candidate_tree = @import("merge_git.zig").trim(try git.output(&.{"write-tree"}));
    try fixtureWrite(&tmp, "Example.cs", "dirty syntax that must never supply source evidence");
    var store = Store.init(git);
    defer store.deinit();
    const base = try store.snapshot(historical);
    const cached_before = store.cachedObjectCount();
    const output = try store.snapshot(candidate_tree);
    try testing.expectEqualStrings(historical, base.revision);
    try testing.expectEqualStrings(candidate_tree, output.revision);
    try testing.expectEqual(context.Kind.int32_array, base.kind(script_guid, "values").?);
    try testing.expectEqual(context.Kind.ordered, output.kind(script_guid, "values").?);
    try testing.expectEqual(cached_before + 1, store.cachedObjectCount());
    const repeated = try store.snapshot(candidate_tree);
    try testing.expectEqualStrings(output.scripts[0].source_hash, repeated.scripts[0].source_hash);
    try testing.expectEqual(cached_before + 1, store.cachedObjectCount());
}

test "candidate dictionary value-type changes cannot reuse historical descriptors" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; [SerializeField] Dictionary<int,string> labels; }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    const historical = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string,System.Action> values; }");
    try git.ok(&.{ "add", "--", "Example.cs" });
    const tree = @import("merge_git.zig").trim(try git.output(&.{"write-tree"}));
    var store = Store.init(git);
    defer store.deinit();
    const before = try store.snapshot(historical);
    const after = try store.snapshot(tree);
    try testing.expectEqual(context.ValueType.int32, before.field(script_guid, "values").?.dictionary_value.?);
    try testing.expectEqual(context.ValueType.string, before.field(script_guid, "labels").?.dictionary_value.?);
    try testing.expectEqual(null, after.field(script_guid, "values"));
}

test "revision snapshots retain unknown comparer evidence from constructors and external mutations" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    const git = try fixtureGit(&tmp, arena, &env);
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] public Dictionary<string,int> values = new Dictionary<string,int>(); }");
    try fixtureWrite(&tmp, "Example.cs.meta", "guid: " ++ script_guid ++ "\n");
    const direct = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Other.cs", "using System.Collections.Generic; public class Other { public void Use(Example instance) { var copy = instance.values; copy.Add(\"A\",1); instance.values[\"A\"]++; instance.values = new Dictionary<string,int> { { \"B\", 2 } }; var replacement = new Dictionary<string,int> { { \"C\", 3 } }; foreach (var pair in instance.values) replacement.Add(pair.Key,pair.Value); instance.values = replacement; } }");
    const mutation = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Other.cs", "public class Other { public void Replace(Example instance) { ref var alias = ref instance.values; alias = Factory(); } }");
    const external = try fixtureCommit(git);
    try fixtureWrite(&tmp, "Other.cs", "public class Other {}");
    try fixtureWrite(&tmp, "Example.cs", "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; public Example() { values = new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase); } }");
    const constructor = try fixtureCommit(git);
    var store = Store.init(git);
    defer store.deinit();
    const original = try store.snapshot(direct);
    try testing.expectEqual(context.Kind.string_dictionary, original.kind(script_guid, "values").?);
    try testing.expectEqual(context.DictionaryEquality.default, original.field(script_guid, "values").?.dictionary_equality);
    const mutated = try store.snapshot(mutation);
    try testing.expectEqual(context.Kind.string_dictionary, mutated.kind(script_guid, "values").?);
    try testing.expectEqual(context.DictionaryEquality.default, mutated.field(script_guid, "values").?.dictionary_equality);
    for ([_][]const u8{ external, constructor }) |revision| {
        const snapshot = try store.snapshot(revision);
        try testing.expectEqual(null, snapshot.kind(script_guid, "values"));
        try testing.expectEqual(context.Kind.string_dictionary, snapshot.field(script_guid, "values").?.kind);
        try testing.expectEqual(context.ValueType.int32, snapshot.field(script_guid, "values").?.dictionary_value.?);
        try testing.expectEqual(context.DictionaryEquality.unknown, snapshot.field(script_guid, "values").?.dictionary_equality);
    }
}
