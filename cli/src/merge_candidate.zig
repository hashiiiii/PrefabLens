const std = @import("std");
const core = @import("core");
const strategy = @import("git_merge_strategy.zig");
const session = @import("merge_session_context.zig");
const revision = @import("merge_revision.zig");
const merge_git = @import("merge_git.zig");
const files = @import("merge_file_conflict.zig");
const Git = merge_git.Git;

const Identity = struct { guid: []const u8, path: []const u8 };
const Entry = struct { path: []const u8, mode: []const u8, oid: []const u8 };
const Node = struct {
    path: []const u8,
    deps: std.StringHashMap(void),
    unity: bool = false,
    relevant: bool = false,
    changed: bool = false,
    uncertain_identity: bool = false,
};
pub const Item = struct {
    paths: []const []const u8,
    conflict: ?strategy.Conflict = null,
    input_paths: ?session.Paths = null,
    done: bool = false,
    attempted: bool = false,
};

// The private index always contains the complete checkout, including presentation
// blobs. Pending groups live outside it and are masked only in source evidence.
pub const Candidate = struct {
    git: Git,
    alternate: Git,
    scratch: []const u8,
    result: strategy.Result,
    store: revision.Store,
    nodes: std.ArrayList(Node) = .empty,
    node_index: std.StringHashMap(usize),
    blobs: std.StringHashMap([]const u8),
    relevance: std.StringHashMap(bool),
    items: std.ArrayList(Item) = .empty,
    snapshots: std.ArrayList([]const Entry) = .empty,
    identities: std.ArrayList(Identity) = .empty,
    evidence_paths: []const []const u8 = &.{},

    pub fn init(git: Git, result: strategy.Result) !Candidate {
        const relative = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "index" }));
        const index = if (std.fs.path.isAbsolute(relative)) relative else try git.path(relative);
        var random: [16]u8 = undefined;
        git.io.random(&random);
        const scratch = try std.fmt.allocPrint(git.arena, "{s}.prefablens-candidate-{x}", .{ index, random });
        try std.Io.Dir.cwd().createDir(git.io, scratch, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(git.io, scratch) catch {};
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(git.io, scratch, git.arena);
        const env = try git.arena.create(std.process.Environ.Map);
        env.* = try git.env.clone(git.arena);
        try env.put("GIT_INDEX_FILE", try std.fs.path.join(git.arena, &.{ absolute, "index" }));
        var alternate = git;
        alternate.env = env;
        try alternate.ok(&.{ "read-tree", result.tree });
        var self: Candidate = .{ .git = git, .alternate = alternate, .scratch = absolute, .result = result, .store = revision.Store.init(git), .node_index = .init(git.arena), .blobs = .init(git.arena), .relevance = .init(git.arena) };
        const sources = result.sources orelse return error.MissingMergeSources;
        for (sources.bases) |base| try self.scan(base);
        try self.scan(sources.ours);
        try self.scan(sources.theirs);
        try self.scan(result.tree);
        try self.seed();
        return self;
    }

    pub fn deinit(self: *Candidate) void {
        self.store.deinit();
        std.Io.Dir.cwd().deleteTree(self.git.io, self.scratch) catch {};
    }

    fn node(self: *Candidate, path: []const u8) !usize {
        if (self.node_index.get(path)) |index| return index;
        const index = self.nodes.items.len;
        try self.nodes.append(self.git.arena, .{ .path = path, .deps = .init(self.git.arena) });
        try self.node_index.put(path, index);
        return index;
    }

    fn readBlob(self: *Candidate, oid: []const u8) ![]const u8 {
        if (self.blobs.get(oid)) |bytes| return bytes;
        const bytes = try self.git.output(&.{ "cat-file", "blob", oid });
        try self.blobs.put(oid, bytes);
        return bytes;
    }

    fn collectionRelevant(self: *Candidate, oid: []const u8, bytes: []const u8) !bool {
        if (self.relevance.get(oid)) |value| return value;
        // Inspect parsed structure only. A script binding needs schema inspection
        // because Unity can serialize a typed collection as a scalar token.
        var memory = std.heap.ArenaAllocator.init(self.git.arena);
        defer memory.deinit();
        const built = core.merge.build(memory.allocator(), bytes, bytes, bytes) catch {
            try self.relevance.put(oid, true);
            return true;
        };
        const relevant = for (built.plan.ours.documents) |document| {
            if (document.class_id == 1001 or collectionNode(document.body)) break true;
        } else false;
        try self.relevance.put(oid, relevant);
        return relevant;
    }

    fn scan(self: *Candidate, tree: []const u8) !void {
        const a = self.git.arena;
        const entries = try treeEntries(self.git, tree);
        try self.snapshots.append(a, entries);
        // Keep every strict metadata identity, including duplicates: a conflict
        // cannot make the other occurrence look uniquely identified for scheduling.
        var identities: std.ArrayList(Identity) = .empty;
        for (entries) |entry| {
            _ = try self.node(entry.path);
            if (!std.ascii.endsWithIgnoreCase(entry.path, ".meta")) continue;
            if (!regular(entry.mode)) {
                self.nodes.items[self.node_index.get(entry.path).?].uncertain_identity = true;
                continue;
            }
            const bytes = try self.readBlob(entry.oid);
            if (try revision.metadataGuid(a, bytes)) |guid| {
                const identity: Identity = .{ .guid = guid, .path = entry.path[0 .. entry.path.len - 5] };
                try identities.append(a, identity);
                try self.rememberIdentity(identity);
            } else self.nodes.items[self.node_index.get(entry.path).?].uncertain_identity = true;
        }
        for (entries) |entry| {
            if (!regular(entry.mode) or !assetPath(entry.path)) continue;
            const bytes = try self.readBlob(entry.oid);
            if (!core.isUnityYaml(bytes)) continue;
            const index = try self.node(entry.path);
            self.nodes.items[index].unity = true;
            self.nodes.items[index].relevant = self.nodes.items[index].relevant or try self.collectionRelevant(entry.oid, bytes);
            const dependencies = core.merge_variant_source.dependencies(a, bytes) catch &.{};
            for (dependencies) |guid| for (identities.items) |identity| {
                if (!std.mem.eql(u8, guid, identity.guid)) continue;
                try self.nodes.items[index].deps.put(identity.path, {});
                try self.nodes.items[index].deps.put(try std.fmt.allocPrint(a, "{s}.meta", .{identity.path}), {});
            };
        }
    }

    fn rememberIdentity(self: *Candidate, value: Identity) !void {
        for (self.identities.items) |existing| if (std.mem.eql(u8, existing.guid, value.guid) and std.mem.eql(u8, existing.path, value.path)) return;
        try self.identities.append(self.git.arena, value);
    }

    fn discoverAccepted(self: *Candidate, paths: []const []const u8) !void {
        // Only committed paths can introduce new edges. Historical and previous
        // selected identities remain in the union until all dependents finish.
        for (paths) |path| {
            if (!std.ascii.endsWithIgnoreCase(path, ".meta")) continue;
            const entry = (try files.treeEntry(self.git, self.result.tree, path)) orelse continue;
            if (try revision.metadataGuid(self.git.arena, try self.readBlob(entry.oid))) |guid| {
                try self.rememberIdentity(.{ .guid = guid, .path = path[0 .. path.len - 5] });
            }
        }
        for (paths) |path| {
            if (!assetPath(path)) continue;
            const entry = (try files.treeEntry(self.git, self.result.tree, path)) orelse continue;
            const dependencies = core.merge_variant_source.dependencies(self.git.arena, try self.readBlob(entry.oid)) catch continue;
            const index = try self.node(path);
            for (dependencies) |guid| for (self.identities.items) |identity| {
                if (!std.mem.eql(u8, guid, identity.guid)) continue;
                try self.nodes.items[index].deps.put(identity.path, {});
                try self.nodes.items[index].deps.put(try std.fmt.allocPrint(self.git.arena, "{s}.meta", .{identity.path}), {});
            };
        }
    }

    fn seed(self: *Candidate) !void {
        const a = self.git.arena;
        // A comparison across the union retains deleted and replacement GUID edges.
        for (self.nodes.items) |*n| {
            const first = findEntry(self.snapshots.items[0], n.path);
            for (self.snapshots.items[1..]) |entries| if (!equalEntry(first, findEntry(entries, n.path))) {
                n.changed = true;
                break;
            };
        }
        for (self.result.conflicts) |conflict| {
            try self.items.append(a, .{ .paths = conflict.paths, .conflict = conflict });
            for (conflict.paths) |path| {
                const index = try self.node(path);
                self.nodes.items[index].changed = true;
                if (std.ascii.endsWithIgnoreCase(path, ".meta")) self.nodes.items[index].uncertain_identity = true;
            }
        }
        // Declaration/assembly changes can alter name lookup anywhere. They are
        // dependencies of semantic work, not proof that unrelated assets conflict.
        var schema_paths: std.ArrayList([]const u8) = .empty;
        for (self.nodes.items) |n| if (n.changed and (schemaPath(n.path) or n.uncertain_identity)) try schema_paths.append(a, n.path);
        self.evidence_paths = schema_paths.items;
        if (schema_paths.items.len != 0) for (self.nodes.items) |*n| {
            // Unknown declarations/identity invalidate selected proof globally.
            // The core can still establish that a scalar-only file is unaffected.
            if (n.unity) n.changed = true;
        };
        var progress = true;
        while (progress) {
            progress = false;
            for (self.nodes.items) |*n| {
                if (n.changed) continue;
                var deps = n.deps.keyIterator();
                while (deps.next()) |path| {
                    const index = self.node_index.get(path.*) orelse continue;
                    if (!self.nodes.items[index].changed) continue;
                    n.changed = true;
                    progress = true;
                    break;
                }
            }
        }
        for (self.nodes.items) |n| {
            if (!n.unity or !n.relevant or !n.changed or self.covered(n.path)) continue;
            // Deleted paths and structural groups retain Git's own relationship.
            if (findEntry(self.snapshots.items[self.snapshots.items.len - 1], n.path) == null) continue;
            try self.items.append(a, .{ .paths = try a.dupe([]const u8, &.{n.path}) });
        }
        const mapping = try @import("merge_candidate_paths.zig").Map.init(self.git, self.result);
        for (self.items.items) |*item| {
            if (item.paths.len != 1 or (item.conflict != null and !std.mem.eql(u8, item.conflict.?.kind, "CONFLICT (contents)"))) continue;
            item.input_paths = try mapping.resolve(item.paths[0]);
            const inputs = item.input_paths orelse continue;
            const index = self.node_index.get(item.paths[0]).?;
            for ([_][]const u8{ inputs.base, inputs.ours, inputs.theirs }) |path| {
                const historical = self.node_index.get(path) orelse continue;
                if (historical == index) continue;
                var deps = self.nodes.items[historical].deps.keyIterator();
                while (deps.next()) |dep| try self.nodes.items[index].deps.put(dep.*, {});
                // Consumers of an old source path must wait for its checkout path.
                for (self.nodes.items) |*n| if (n.deps.contains(path)) try n.deps.put(item.paths[0], {});
            }
        }
    }

    fn covered(self: *const Candidate, path: []const u8) bool {
        for (self.items.items) |item| for (item.paths) |p| if (pathUnder(path, p)) return true;
        return false;
    }

    pub fn pendingPaths(self: *Candidate) ![]const []const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        for (self.items.items) |item| {
            if (item.done) continue;
            try paths.appendSlice(self.git.arena, item.paths);
            // Expand directory groups to expose unresolved schema evidence.
            for (self.nodes.items) |n| for (item.paths) |path| {
                if (!std.mem.eql(u8, n.path, path) and pathUnder(n.path, path)) try paths.append(self.git.arena, n.path);
            };
        }
        return paths.items;
    }

    pub fn ready(self: *Candidate, index: usize) bool {
        const item = self.items.items[index];
        if (item.done or item.attempted) return false;
        if (item.conflict == null or std.mem.eql(u8, item.conflict.?.kind, "CONFLICT (contents)")) {
            const semantic = for (item.paths) |path| {
                if (self.node_index.get(path)) |n| if (self.nodes.items[n].unity) break true;
            } else false;
            if (semantic) for (self.evidence_paths) |evidence| {
                for (self.items.items, 0..) |other, j| {
                    if (index == j or other.done) continue;
                    for (other.paths) |path| if (pathUnder(evidence, path)) return false;
                }
            };
        }

        for (item.paths) |path| {
            const n = self.node_index.get(path) orelse continue;
            var deps = self.nodes.items[n].deps.keyIterator();
            while (deps.next()) |dep| for (self.items.items, 0..) |other, j| {
                if (index == j or other.done) continue;
                for (other.paths) |p| if (pathUnder(dep.*, p)) return false;
            };
        }
        return true;
    }

    pub fn selected(self: *Candidate) !core.merge_context.Snapshot {
        return session.maskUnresolved(self.git.arena, try self.store.snapshot(self.result.tree), try self.pendingPaths());
    }

    pub fn build(self: *Candidate, index: usize, output: core.merge_context.Snapshot) !?core.merge.BuildResult {
        const item = self.items.items[index];
        if (item.paths.len != 1 or (item.conflict != null and !std.mem.eql(u8, item.conflict.?.kind, "CONFLICT (contents)"))) return null;
        const path = item.paths[0];
        const paths = item.input_paths orelse return null;
        const inputs = try self.readInputs(path);
        for ([_][]const u8{ inputs.base, inputs.ours, inputs.theirs }) |bytes| if (bytes.len != 0 and !core.isUnityYaml(bytes)) return null;
        if (inputs.ours.len == 0 and inputs.theirs.len == 0) return null;
        var context: core.merge_context.Context = .{};
        if (self.result.sources.?.known) |known| {
            context = (try session.bind(&self.store, known, paths, inputs)) orelse return null;
        } else return null;
        context.output = output;
        return core.merge.buildWithContext(self.git.arena, inputs.base, inputs.ours, inputs.theirs, context) catch null;
    }

    fn inputPaths(self: *Candidate, path: []const u8) ?session.Paths {
        for (self.items.items) |item| if (item.paths.len == 1 and std.mem.eql(u8, item.paths[0], path)) return item.input_paths;
        return null;
    }

    pub fn readInputs(self: *Candidate, path: []const u8) !session.Inputs {
        const entries = try self.inputEntries(path);
        return .{ .base = try strategy.blob(self.git, entries[0]), .ours = try strategy.blob(self.git, entries[1]), .theirs = try strategy.blob(self.git, entries[2]) };
    }

    fn inputEntries(self: *Candidate, path: []const u8) ![3]?strategy.Stage {
        const sources = self.result.sources.?;
        const paths = self.inputPaths(path);
        return .{
            if (paths) |p| try self.baseEntry(p.base) else null,
            try files.treeEntry(self.git, sources.ours, if (paths) |p| p.ours else path),
            try files.treeEntry(self.git, sources.theirs, if (paths) |p| p.theirs else path),
        };
    }

    fn baseEntry(self: *Candidate, path: []const u8) !?strategy.Stage {
        const bases = self.result.sources.?.bases;
        if (bases.len == 0) return null;
        const first = try files.treeEntry(self.git, bases[0], path);
        for (bases[1..]) |base| {
            const other = try files.treeEntry(self.git, base, path);
            if (first == null or other == null) {
                if (first != null or other != null) return null;
            } else if (!std.mem.eql(u8, first.?.oid, other.?.oid) or !std.mem.eql(u8, first.?.mode, other.?.mode)) return null;
        }
        return first;
    }

    pub fn automatic(self: *Candidate) !void {
        while (true) {
            const index = for (self.items.items, 0..) |_, i| {
                if (self.ready(i)) break i;
            } else break;
            self.items.items[index].attempted = true;
            var built = (try self.build(index, try self.selected())) orelse continue;
            const bytes = core.merge.finish(self.git.arena, &built.plan) catch continue;
            const path = self.items.items[index].paths[0];
            const entry = (try files.treeEntry(self.git, self.result.tree, path)) orelse continue;
            try self.put(path, entry.mode, bytes);
            try self.retire(&.{path});
        }
        // Git may skip the driver for an unchanged dependent or one-sided file.
        // Actual historical stages still make those semantic choices uncommittable.
        for (self.items.items, 0..) |item, index| {
            if (!item.done and item.conflict == null) try self.addConflict(index);
        }
        for (self.items.items) |*item| item.attempted = false;
    }

    fn addConflict(self: *Candidate, index: usize) !void {
        const a = self.git.arena;
        const path = self.items.items[index].paths[0];
        var stages: std.ArrayList(strategy.Stage) = .empty;
        try stages.appendSlice(a, self.result.stages);
        const entries = try self.inputEntries(path);
        for (entries, 1..) |entry, number| if (entry) |value| {
            var stage = value;
            stage.number = @intCast(number);
            stage.path = path;
            stage.record = try std.fmt.allocPrint(a, "{s} {s} {d}\t{s}", .{ value.mode, value.oid, number, path });
            try stages.append(a, stage);
        };
        self.result.stages = stages.items;
        const c: strategy.Conflict = .{ .paths = self.items.items[index].paths, .kind = "CONFLICT (contents)", .message = try std.fmt.allocPrint(a, "CONFLICT (semantic context): {s} {s}.\n", .{ path, if (self.inputPaths(path) == null) "has an unknown historical file relationship" else "needs a collection/source decision" }) };
        self.items.items[index].conflict = c;
        self.result.conflicts = try std.mem.concat(a, strategy.Conflict, &.{ self.result.conflicts, &.{c} });
        // Keep Git's accepted presentation when the historical relationship is unknown.
        if (self.inputPaths(path) == null) return;
        const inputs = try self.readInputs(path);
        const entry = (try files.treeEntry(self.git, self.result.tree, path)) orelse return;
        const style_result = try self.git.run(&.{ "config", "--get", "merge.conflictStyle" });
        if (merge_git.exitCode(style_result) > 1) return error.GitFailed;
        const style = merge_git.trim(style_result.stdout);
        const attributes = try self.git.output(&.{ "check-attr", "-z", "conflict-marker-size", "--", path });
        var attribute_fields = std.mem.splitScalar(u8, attributes, 0);
        _ = attribute_fields.next();
        _ = attribute_fields.next();
        const marker_size = std.fmt.parseInt(u31, attribute_fields.next() orelse "7", 10) catch 7;
        var presentation: std.Io.Writer.Allocating = .init(a);
        try marker(&presentation.writer, '<', marker_size, "ours", inputs.ours);
        if (std.mem.eql(u8, style, "diff3") or std.mem.eql(u8, style, "zdiff3")) try marker(&presentation.writer, '|', marker_size, "base", inputs.base);
        try marker(&presentation.writer, '=', marker_size, "", inputs.theirs);
        try marker(&presentation.writer, '>', marker_size, "theirs", "");
        try self.put(path, entry.mode, try presentation.toOwnedSlice());
    }

    pub fn put(self: *Candidate, path: []const u8, mode: []const u8, bytes: []const u8) !void {
        const file = try std.fs.path.join(self.git.arena, &.{ self.scratch, "blob" });
        try std.Io.Dir.cwd().writeFile(self.git.io, .{ .sub_path = file, .data = bytes });
        const oid = merge_git.trim(try self.git.output(&.{ "hash-object", "-w", "--no-filters", "--", file }));
        const record = try std.fmt.allocPrint(self.git.arena, "{s} {s}\t{s}\x00", .{ mode, oid, path });
        try self.alternate.input(&.{ "update-index", "-z", "--index-info" }, record);
        self.result.tree = merge_git.trim(try self.alternate.output(&.{"write-tree"}));
    }

    pub fn retire(self: *Candidate, paths: []const []const u8) !void {
        const a = self.git.arena;
        for (self.items.items) |*item| {
            const complete = for (item.paths) |path| {
                if (!contains(paths, path)) break false;
            } else true;
            if (complete) item.done = true;
        }
        var stages: std.ArrayList(strategy.Stage) = .empty;
        for (self.result.stages) |stage| if (!contains(paths, stage.path)) try stages.append(a, stage);
        self.result.stages = stages.items;
        var conflicts: std.ArrayList(strategy.Conflict) = .empty;
        for (self.result.conflicts) |c| {
            const complete = for (c.paths) |path| {
                if (!contains(paths, path)) break false;
            } else true;
            if (!complete) try conflicts.append(a, c);
        }
        self.result.conflicts = conflicts.items;
    }

    // Refresh only committed paths in the complete checkout baseline. readIndex's
    // source tree omits unresolved paths and must never replace this baseline.
    pub fn refresh(self: *Candidate, paths: []const []const u8) !void {
        const a = self.git.arena;
        const zero = try a.alloc(u8, self.result.tree.len);
        @memset(zero, '0');
        var records: std.ArrayList(u8) = .empty;
        for (paths) |path| {
            try records.appendSlice(a, try std.fmt.allocPrint(a, "0 {s}\t{s}\x00", .{ zero, path }));
            const entries = try self.git.output(&.{ "ls-files", "--stage", "-z", "--", path });
            if (entries.len != 0) {
                const tab = std.mem.indexOfScalar(u8, entries, '\t') orelse return error.InvalidIndex;
                if (tab == 0 or entries[tab - 1] != '0' or std.mem.count(u8, entries, "\x00") != 1) return error.IndexChanged;
                try records.appendSlice(a, entries);
            }
        }
        try self.alternate.input(&.{ "update-index", "-z", "--index-info" }, records.items);
        self.result.tree = merge_git.trim(try self.alternate.output(&.{"write-tree"}));
        try self.discoverAccepted(paths);
        try self.retire(paths);
    }
};

fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}
fn pathUnder(path: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, path, parent) or (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/');
}
fn regular(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755");
}
fn assetPath(path: []const u8) bool {
    for ([_][]const u8{ ".prefab", ".unity", ".asset" }) |suffix| if (std.ascii.endsWithIgnoreCase(path, suffix)) return true;
    return false;
}
fn schemaPath(path: []const u8) bool {
    for ([_][]const u8{ ".cs", ".cs.meta", ".asmdef", ".asmref", ".dll", ".rsp" }) |suffix| if (std.ascii.endsWithIgnoreCase(path, suffix)) return true;
    return false;
}
fn findEntry(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, path, entry.path)) return entry;
    return null;
}
fn equalEntry(a: ?Entry, b: ?Entry) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.oid, b.?.oid) and std.mem.eql(u8, a.?.mode, b.?.mode);
}
fn treeEntries(git: Git, tree: []const u8) ![]const Entry {
    const bytes = try git.output(&.{ "ls-tree", "-r", "-z", tree });
    var entries: std.ArrayList(Entry) = .empty;
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidTree;
        var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
        const mode = fields.next() orelse return error.InvalidTree;
        _ = fields.next() orelse return error.InvalidTree;
        const oid = fields.next() orelse return error.InvalidTree;
        try entries.append(git.arena, .{ .path = record[tab + 1 ..], .mode = mode, .oid = oid });
    }
    return entries.items;
}

fn marker(writer: *std.Io.Writer, byte: u8, size: u31, label: []const u8, bytes: []const u8) !void {
    try writer.splatByteAll(byte, if (size == 0) 7 else size);
    if (label.len != 0) try writer.print(" {s}", .{label});
    try writer.writeByte('\n');
    try writer.writeAll(bytes);
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
}

fn collectionNode(value: *const core.model.Node) bool {
    return switch (value.*) {
        .seq => true,
        .map => |entries| for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "m_Script") or collectionNode(entry.value)) break true;
        } else false,
        .scalar, .ref => false,
    };
}
