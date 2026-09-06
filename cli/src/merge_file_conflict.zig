const std = @import("std");
const core = @import("core");
const merge_git = @import("merge_git.zig");
const strategy = @import("git_merge_strategy.zig");
const merge_io = @import("merge_io.zig");
const fallback = @import("merge_fallback.zig");
const file_choice = @import("merge_file_choice.zig");
const merge_tui = @import("merge_tui.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const session_context = @import("merge_session_context.zig");
const revision = @import("merge_revision.zig");
const Git = merge_git.Git;
const Stage = strategy.Stage;

pub const Outcome = union(enum) { unresolved, aborted, resolved: []const []const u8 };

const Layout = struct {
    paths: []const []const u8,
    base_path: []const u8,
    ours_path: ?[]const u8,
    theirs_path: ?[]const u8,
    base: Stage,
    ours: ?Stage,
    theirs: ?Stage,
};

const Metadata = struct { bytes: []const u8, mode: []const u8 };
const Snapshot = struct { path: []const u8, bytes: ?[]const u8, stat: ?std.Io.File.Stat };
const Replacement = struct { path: []const u8, bytes: []const u8, mode: []const u8 };

pub const ContentPrepared = struct {
    saved: Snapshot,
    index_path: []const u8,
    index_before: []const u8,
    mode: []const u8,
    oid_len: usize,
};

pub fn prepareContent(git: Git, result: strategy.Result, path: []const u8) !?ContentPrepared {
    if (!safePath(path)) return null;
    const entry = (treeEntry(git, result.tree, path) catch return null) orelse return null;
    const saved = checkedSnapshot(git, result.tree, path) catch return null;
    const index_path = try gitIndexPath(git);
    const index_before = try std.Io.Dir.cwd().readFileAlloc(git.io, index_path, git.arena, .limited(256 * 1024 * 1024));
    try checkIndexPaths(git, result, &.{path});
    try checkIndexBytes(git, index_path, index_before);
    return .{
        .saved = saved,
        .index_path = index_path,
        .index_before = index_before,
        .mode = entry.mode,
        .oid_len = result.tree.len,
    };
}

pub fn finishContent(git: Git, prepared: ContentPrepared, canonical_bytes: []const u8) !void {
    try apply(git, prepared.oid_len, prepared.index_path, prepared.index_before, &.{prepared.saved}, &.{.{ .path = prepared.saved.path, .bytes = canonical_bytes, .mode = prepared.mode }});
}

pub fn resolve(git: Git, result: strategy.Result, conflict: strategy.Conflict, env: *std.process.Environ.Map) !Outcome {
    return resolveWithContext(git, result, conflict, env, null);
}

pub fn resolveWithContext(git: Git, result: strategy.Result, conflict: strategy.Conflict, env: *std.process.Environ.Map, captured: ?session_context.Index) !Outcome {
    const classified = classify(result.stages, conflict) orelse return .unresolved;
    const layout = originals(git, result, classified) catch return .unresolved;
    for (layout.paths) |path| if (!safePath(path) or std.mem.endsWith(u8, path, ".meta")) return .unresolved;
    const base = strategy.blob(git, layout.base) catch return .unresolved;
    const ours = strategy.blob(git, layout.ours) catch return .unresolved;
    const theirs = strategy.blob(git, layout.theirs) catch return .unresolved;
    for ([_][]const u8{ base, ours, theirs }) |bytes| {
        if (bytes.len != 0 and (!core.isUnityYaml(bytes) or fallback.isBinary(bytes))) return .unresolved;
    }
    if (base.len == 0 or (layout.ours != null and ours.len == 0) or (layout.theirs != null and theirs.len == 0)) return .unresolved;

    var context: core.merge_context.Context = .{};
    if (captured) |output| {
        var store = revision.Store.init(git);
        defer store.deinit();
        const known = (result.sources orelse return .unresolved).known orelse return .unresolved;
        context = (try session_context.bind(&store, known, .{
            .base = layout.base_path,
            .ours = layout.ours_path orelse layout.base_path,
            .theirs = layout.theirs_path orelse layout.base_path,
        }, .{ .base = base, .ours = ours, .theirs = theirs })) orelse return .unresolved;
        context.output = output.snapshot;
    }
    // Unsupported input must be refused before the first interactive decision.
    var built: ?core.merge.BuildResult = if (layout.ours != null and layout.theirs != null)
        core.merge.buildWithContext(git.arena, base, ours, theirs, context) catch return .unresolved
    else
        null;
    const meta = metadata(git, result, layout) catch return .unresolved;
    var paths: std.ArrayList([]const u8) = .empty;
    for (layout.paths) |path| {
        try paths.append(git.arena, path);
        // Snapshot absent metadata too: creating a sidecar during the UI is a manual edit.
        try paths.append(git.arena, try std.fmt.allocPrint(git.arena, "{s}.meta", .{path}));
    }
    const snapshots = try git.arena.alloc(Snapshot, paths.items.len);
    for (paths.items, snapshots) |path, *saved| {
        saved.* = checkedSnapshot(git, result.tree, path) catch return .unresolved;
    }
    for (snapshots, 0..) |saved, i| {
        if (saved.stat) |stat| {
            for (snapshots[0..i]) |previous| {
                if (previous.stat != null and previous.stat.?.inode == stat.inode) return .unresolved;
            }
        }
    }
    const index_path = try gitIndexPath(git);
    const index_before = try std.Io.Dir.cwd().readFileAlloc(git.io, index_path, git.arena, .limited(256 * 1024 * 1024));
    try checkIndexPaths(git, result, paths.items);
    try checkIndexBytes(git, index_path, index_before);
    if (captured) |output| if (!std.mem.eql(u8, output.before, index_before)) return error.SourceChanged;
    const decision = try file_choice.run(git.io, git.arena, env, .{ .base = layout.base_path, .ours = layout.ours_path, .theirs = layout.theirs_path, .paired_meta = meta != null });
    if (decision == .quit) return .aborted;
    var replacements: std.ArrayList(Replacement) = .empty;
    if (decision != .delete) {
        const final_path = switch (decision) {
            .keep => layout.ours_path orelse layout.theirs_path.?,
            .ours => layout.ours_path.?,
            .theirs => layout.theirs_path.?,
            else => unreachable,
        };
        const bytes = if (built) |*merge| blk: {
            var state = try merge_ui_state.State.init(git.arena, &merge.plan);
            if (state.outcome != .ready) try merge_tui.run(git.io, git.arena, env, &state, final_path, merge.partial);
            if (state.outcome != .ready) return .aborted;
            break :blk core.merge.finish(git.arena, &merge.plan) catch return .unresolved;
        } else if (layout.ours != null) ours else theirs;
        try replacements.append(git.arena, .{ .path = final_path, .bytes = bytes, .mode = mergeMode(layout.base, layout.ours, layout.theirs) });
        if (meta) |value| try replacements.append(git.arena, .{ .path = try std.fmt.allocPrint(git.arena, "{s}.meta", .{final_path}), .bytes = value.bytes, .mode = value.mode });
    }
    // Both screens have completed. Index and filesystem changes now form one transaction.
    try apply(git, result.tree.len, index_path, index_before, snapshots, replacements.items);
    return .{ .resolved = try paths.toOwnedSlice(git.arena) };
}

fn classify(stages: []const Stage, conflict: strategy.Conflict) ?Layout {
    const p = conflict.paths;
    var layout: Layout = undefined;
    if (std.mem.eql(u8, conflict.kind, "CONFLICT (modify/delete)") and p.len == 1) {
        const ours = strategy.side(stages, p[0], 2);
        const theirs = strategy.side(stages, p[0], 3);
        if ((ours == null) == (theirs == null)) return null;
        layout = .{ .paths = p, .base_path = p[0], .ours_path = if (ours != null) p[0] else null, .theirs_path = if (theirs != null) p[0] else null, .base = strategy.side(stages, p[0], 1) orelse return null, .ours = ours, .theirs = theirs };
    } else if (std.mem.eql(u8, conflict.kind, "CONFLICT (rename/delete)") and p.len == 2 and !std.mem.eql(u8, p[0], p[1])) {
        const ours = strategy.side(stages, p[0], 2);
        const theirs = strategy.side(stages, p[0], 3);
        if ((ours == null) == (theirs == null)) return null;
        layout = .{ .paths = p, .base_path = p[1], .ours_path = if (ours != null) p[0] else null, .theirs_path = if (theirs != null) p[0] else null, .base = strategy.side(stages, p[0], 1) orelse return null, .ours = ours, .theirs = theirs };
    } else if (std.mem.eql(u8, conflict.kind, "CONFLICT (rename/rename)") and p.len == 3 and !std.mem.eql(u8, p[0], p[1]) and !std.mem.eql(u8, p[0], p[2]) and !std.mem.eql(u8, p[1], p[2])) {
        layout = .{ .paths = p, .base_path = p[0], .ours_path = p[1], .theirs_path = p[2], .base = strategy.side(stages, p[0], 1) orelse return null, .ours = strategy.side(stages, p[1], 2) orelse return null, .theirs = strategy.side(stages, p[2], 3) orelse return null };
    } else return null;
    var count: usize = 0;
    for (stages) |stage| for (p) |path| {
        if (std.mem.eql(u8, stage.path, path)) count += 1;
    };
    if (count != (if (layout.ours != null and layout.theirs != null) @as(usize, 3) else 2)) return null;
    return layout;
}

fn mergeMode(base: Stage, ours: ?Stage, theirs: ?Stage) []const u8 {
    if (ours == null) return theirs.?.mode;
    if (theirs == null) return ours.?.mode;
    return if (std.mem.eql(u8, ours.?.mode, base.mode)) theirs.?.mode else ours.?.mode;
}

fn originals(git: Git, result: strategy.Result, layout: Layout) !Layout {
    const remote = result.theirs orelse return error.MissingMergeSources;
    const bases = merge_git.trim(try git.output(&.{ "merge-base", "--all", result.ours, remote }));
    if (bases.len == 0 or std.mem.indexOfScalar(u8, bases, '\n') != null) return error.AmbiguousMergeBase;
    var source = layout;
    source.base = (try treeEntry(git, bases, layout.base_path)) orelse return error.UnknownFileRelationship;
    source.ours = if (layout.ours_path) |path| (try treeEntry(git, result.ours, path)) orelse return error.UnknownFileRelationship else null;
    source.theirs = if (layout.theirs_path) |path| (try treeEntry(git, remote, path)) orelse return error.UnknownFileRelationship else null;
    // Git may place its already merged blob in rename/rename stages 2 and 3.
    // Those entries describe locations, while source trees supply semantic inputs.
    if (!std.mem.eql(u8, source.base.oid, layout.base.oid)) return error.UnknownFileRelationship;
    return source;
}

fn worktreeBlob(git: Git, oid: []const u8, path: []const u8) ![]const u8 {
    return git.output(&.{ "cat-file", "--filters", try std.fmt.allocPrint(git.arena, "--path={s}", .{path}), oid });
}

fn safePath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or std.ascii.eqlIgnoreCase(component, ".git")) return false;
    }
    return true;
}

pub fn treeEntry(git: Git, tree: []const u8, path: []const u8) !?Stage {
    const bytes = try git.output(&.{ "--literal-pathspecs", "ls-tree", "-z", tree, "--", path });
    if (bytes.len == 0) return null;
    if (bytes[bytes.len - 1] != 0 or std.mem.count(u8, bytes, "\x00") != 1) return error.AmbiguousPath;
    const tab = std.mem.indexOfScalar(u8, bytes, '\t') orelse return error.InvalidTree;
    var fields = std.mem.tokenizeScalar(u8, bytes[0..tab], ' ');
    const mode = fields.next() orelse return error.InvalidTree;
    const kind = fields.next() orelse return error.InvalidTree;
    const oid = fields.next() orelse return error.InvalidTree;
    if (!std.mem.eql(u8, kind, "blob") or fields.next() != null or !std.mem.eql(u8, path, bytes[tab + 1 .. bytes.len - 1])) return error.AmbiguousPath;
    if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) return error.UnsupportedFileMode;
    return .{ .mode = mode, .oid = oid, .number = 0, .path = path, .record = "" };
}

fn metadata(git: Git, result: strategy.Result, layout: Layout) !?Metadata {
    const remote = result.theirs orelse return error.MissingMergeSources;
    const bases = merge_git.trim(try git.output(&.{ "merge-base", "--all", result.ours, remote }));
    if (bases.len == 0 or std.mem.indexOfScalar(u8, bases, '\n') != null) return error.AmbiguousMergeBase;
    const trees = [_][]const u8{ bases, result.ours, remote };
    const asset_paths = [_]?[]const u8{ layout.base_path, layout.ours_path, layout.theirs_path };
    const assets = [_]?Stage{ layout.base, layout.ours, layout.theirs };
    var entries: [3]?Stage = .{ null, null, null };
    for (trees, asset_paths, assets, 0..) |tree, asset_path, asset, side_number| {
        for (layout.paths) |path| {
            const entry = try treeEntry(git, tree, path);
            const expected = asset_path != null and std.mem.eql(u8, path, asset_path.?);
            if (expected) {
                if (entry == null or !std.mem.eql(u8, entry.?.oid, asset.?.oid) or !std.mem.eql(u8, entry.?.mode, asset.?.mode)) return error.UnknownFileRelationship;
            } else if (entry != null) return error.AmbiguousPath;
            const meta_path = try std.fmt.allocPrint(git.arena, "{s}.meta", .{path});
            if (try treeEntry(git, tree, meta_path)) |meta| {
                if (!expected or entries[side_number] != null) return error.UnknownMetadataRelationship;
                entries[side_number] = meta;
            }
        }
    }
    if (entries[0] == null and entries[1] == null and entries[2] == null) return null;
    for (result.conflicts) |conflict| {
        if (std.mem.eql(u8, conflict.kind, "CONFLICT (modify/delete)") or std.mem.eql(u8, conflict.kind, "CONFLICT (rename/delete)") or std.mem.eql(u8, conflict.kind, "CONFLICT (rename/rename)")) continue;
        for (conflict.paths) |conflict_path| {
            for (layout.paths) |path| {
                if (conflict_path.len == path.len + 5 and std.mem.startsWith(u8, conflict_path, path) and std.mem.endsWith(u8, conflict_path, ".meta")) return error.MetadataContentConflict;
            }
        }
    }
    for (entries, assets) |entry, asset| {
        if ((entry == null) != (asset == null)) return error.IncompleteMetadataPair;
    }
    var bytes: [3][]const u8 = undefined;
    for (entries, &bytes) |entry, *value| value.* = try strategy.blob(git, entry);
    const identity = guid(bytes[0]) orelse return error.InvalidMetadataGuid;
    for (bytes) |value| {
        if (value.len == 0) continue;
        if (fallback.isBinary(value) or !std.ascii.eqlIgnoreCase(identity, guid(value) orelse return error.InvalidMetadataGuid)) return error.MetadataGuidMismatch;
    }
    const output = if (entries[1] == null) bytes[2] else if (entries[2] == null) bytes[1] else if (std.mem.eql(u8, bytes[1], bytes[2]) or std.mem.eql(u8, bytes[0], bytes[2])) bytes[1] else if (std.mem.eql(u8, bytes[0], bytes[1])) bytes[2] else try mergeMetadataText(git, bytes);
    if (!std.ascii.eqlIgnoreCase(identity, guid(output) orelse return error.InvalidMetadataGuid)) return error.MetadataGuidMismatch;
    return .{ .bytes = output, .mode = mergeMode(entries[0].?, entries[1], entries[2]) };
}

fn guid(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "guid:")) continue;
        if (found != null) return null;
        const value = std.mem.trim(u8, line[5..], " \t\r");
        if (value.len != 32) return null;
        for (value) |byte| if (!std.ascii.isHex(byte)) return null;
        found = value;
    }
    return found;
}

fn mergeMetadataText(git: Git, bytes: [3][]const u8) ![]const u8 {
    const scratch = try scratchDirectory(git);
    defer std.Io.Dir.cwd().deleteTree(git.io, scratch) catch {};
    var paths: [3][]const u8 = undefined;
    for (bytes, &paths, 0..) |content, *path, index| {
        path.* = try std.fmt.allocPrint(git.arena, "{s}/{d}", .{ scratch, index });
        try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = path.*, .data = content });
    }
    const merged = try git.run(&.{ "merge-file", "-p", "--", paths[1], paths[0], paths[2] });
    if (merge_git.exitCode(merged) != 0) return error.MetadataContentConflict;
    return merged.stdout;
}

fn gitIndexPath(git: Git) ![]const u8 {
    const path = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "index" }));
    return if (std.fs.path.isAbsolute(path)) path else git.path(path);
}

fn checkIndexPaths(git: Git, result: strategy.Result, paths: []const []const u8) !void {
    for (paths) |path| {
        var expected: std.ArrayList(u8) = .empty;
        for (result.stages) |stage| {
            if (!std.mem.eql(u8, stage.path, path)) continue;
            try expected.appendSlice(git.arena, stage.record);
            try expected.append(git.arena, 0);
        }
        if (expected.items.len == 0) {
            if (try treeEntry(git, result.tree, path)) |entry| {
                try expected.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "{s} {s} 0\t{s}\x00", .{ entry.mode, entry.oid, path }));
            }
        }
        const actual = try git.output(&.{ "--literal-pathspecs", "ls-files", "--stage", "-z", "--", path });
        if (!std.mem.eql(u8, actual, expected.items)) return error.IndexChanged;
    }
}

fn checkIndexBytes(git: Git, path: []const u8, expected: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(git.io, path, git.arena, .limited(256 * 1024 * 1024));
    if (!std.mem.eql(u8, bytes, expected)) return error.IndexChanged;
}

fn scratchDirectory(git: Git) ![]const u8 {
    var random: [16]u8 = undefined;
    git.io.random(&random);
    const path = try std.fmt.allocPrint(git.arena, "{s}.prefablens-files-{x}", .{ try gitIndexPath(git), random });
    try std.Io.Dir.cwd().createDir(git.io, path, .default_dir);
    return std.Io.Dir.cwd().realPathFileAlloc(git.io, path, git.arena);
}

fn snapshot(git: Git, path: []const u8) !Snapshot {
    const absolute = try git.path(path);
    // Reject symlinked parent directories as well as symlinked final components.
    var parent = std.fs.path.dirname(path);
    while (parent) |directory| : (parent = std.fs.path.dirname(directory)) {
        const stat = std.Io.Dir.cwd().statFile(git.io, try git.path(directory), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .directory) return error.UnsupportedFileMode;
    }
    const stat = std.Io.Dir.cwd().statFile(git.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = path, .bytes = null, .stat = null },
        else => return err,
    };
    if (stat.kind != .file) return error.UnsupportedFileMode;
    return .{ .path = path, .bytes = try merge_io.readOutputLimited(git.io, git.arena, absolute), .stat = stat };
}

fn checkedSnapshot(git: Git, tree: []const u8, path: []const u8) !Snapshot {
    const saved = try snapshot(git, path);
    if (try treeEntry(git, tree, path)) |entry| {
        if (saved.bytes == null) return error.SourceChanged;
        if (comptime std.Io.File.Permissions.has_executable_bit) {
            if (try tracksExecutable(git)) {
                const executable = saved.stat.?.permissions.toMode() & 0o100 != 0;
                if (executable != std.mem.eql(u8, entry.mode, "100755")) return error.SourceChanged;
            }
        }
        // Unchanged files may retain LF after core.autocrlf is enabled.
        // Compare Git's canonical content and retain the exact working snapshot.
        const actual_oid = merge_git.trim(try git.output(&.{ "hash-object", try std.fmt.allocPrint(git.arena, "--path={s}", .{path}), "--", path }));
        if (!std.mem.eql(u8, actual_oid, entry.oid)) return error.SourceChanged;
        try unchanged(git, saved);
    } else if (saved.bytes != null) return error.AmbiguousPath;
    return saved;
}

fn unchanged(git: Git, before: Snapshot) !void {
    const now = try snapshot(git, before.path);
    if ((now.bytes == null) != (before.bytes == null)) return error.SourceChanged;
    if (before.bytes) |bytes| {
        if (!std.mem.eql(u8, bytes, now.bytes.?) or now.stat.?.permissions != before.stat.?.permissions or now.stat.?.inode != before.stat.?.inode or now.stat.?.mtime.nanoseconds != before.stat.?.mtime.nanoseconds) return error.SourceChanged;
    }
}

fn tracksExecutable(git: Git) !bool {
    if (!std.Io.File.Permissions.has_executable_bit) return false;
    const configured = try git.run(&.{ "config", "--bool", "core.fileMode" });
    return switch (merge_git.exitCode(configured)) {
        0 => std.mem.eql(u8, merge_git.trim(configured.stdout), "true"),
        1 => true,
        else => error.GitFailed,
    };
}

fn permissions(before: Snapshot, mode: []const u8, tracked: bool) std.Io.File.Permissions {
    if (before.stat) |stat| {
        if (comptime std.Io.File.Permissions.has_executable_bit) {
            const existing = stat.permissions.toMode();
            const desired_executable = std.mem.eql(u8, mode, "100755");
            if (tracked and (existing & 0o100 != 0) != desired_executable) {
                const executable_bits: std.posix.mode_t = 0o111;
                return .fromMode(if (desired_executable) existing | executable_bits else existing & ~executable_bits);
            }
        }
        return stat.permissions;
    }
    // Let normal creation apply the user's umask to a new asset or sidecar.
    return if (std.mem.eql(u8, mode, "100755")) .executable_file else .default_file;
}

fn replace(git: Git, before: Snapshot, bytes: []const u8, mode: std.Io.File.Permissions, exact_mode: bool) !std.Io.File.Permissions {
    const absolute = try git.path(before.path);
    const directory = try std.Io.Dir.cwd().openDir(git.io, std.fs.path.dirname(absolute) orelse ".", .{});
    defer directory.close(git.io);
    var atomic = try directory.createFileAtomic(git.io, std.fs.path.basename(absolute), .{ .replace = before.bytes != null, .permissions = mode });
    defer atomic.deinit(git.io);
    try atomic.file.writeStreamingAll(git.io, bytes);
    if (exact_mode) try atomic.file.setPermissions(git.io, mode);
    try atomic.file.sync(git.io);
    const actual_mode = (try atomic.file.stat(git.io)).permissions;
    try unchanged(git, before);
    if (before.bytes != null) try atomic.replace(git.io) else try atomic.link(git.io);
    return actual_mode;
}

fn apply(git: Git, oid_len: usize, index_path: []const u8, index_before: []const u8, snapshots: []const Snapshot, replacements: []const Replacement) !void {
    const cwd = std.Io.Dir.cwd();
    const scratch = try scratchDirectory(git);
    defer cwd.deleteTree(git.io, scratch) catch {};
    const alternate_index = try std.fs.path.join(git.arena, &.{ scratch, "index" });
    try cwd.writeFile(git.io, .{ .sub_path = alternate_index, .data = index_before });
    var env = try git.env.clone(git.arena);
    try env.put("GIT_INDEX_FILE", alternate_index);
    var alternate = git;
    alternate.env = &env;
    var records: std.ArrayList(u8) = .empty;
    const zero = try git.arena.alloc(u8, oid_len);
    @memset(zero, '0');
    for (snapshots) |saved| try records.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "0 {s}\t{s}\x00", .{ zero, saved.path }));
    const worktree_bytes = try git.arena.alloc([]const u8, replacements.len);
    for (replacements, worktree_bytes, 0..) |replacement, *working, i| {
        const blob_path = try std.fmt.allocPrint(git.arena, "{s}/blob-{d}", .{ scratch, i });
        try cwd.writeFile(git.io, .{ .sub_path = blob_path, .data = replacement.bytes });
        const oid = merge_git.trim(try git.output(&.{ "hash-object", "-w", "--no-filters", "--", blob_path }));
        if (oid.len != oid_len) return error.InvalidObjectId;
        working.* = try worktreeBlob(git, oid, replacement.path);
        try records.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "{s} {s}\t{s}\x00", .{ replacement.mode, oid, replacement.path }));
    }
    // Prepare every index removal/insertion in one update. Git atomically writes the alternate index.
    try alternate.input(&.{ "update-index", "-z", "--index-info" }, records.items);
    const lock_path = try std.fmt.allocPrint(git.arena, "{s}.lock", .{index_path});
    const lock = try cwd.createFile(git.io, lock_path, .{ .exclusive = true });
    defer {
        lock.close(git.io);
        cwd.deleteFile(git.io, lock_path) catch {};
    }
    try checkIndexBytes(git, index_path, index_before);
    for (snapshots) |saved| try unchanged(git, saved);

    var applied: std.ArrayList(struct { before: Snapshot, after_bytes: ?[]const u8, after_mode: std.Io.File.Permissions }) = .empty;
    errdefer {
        var i = applied.items.len;
        while (i > 0) {
            i -= 1;
            const change = applied.items[i];
            // Never undo a manual edit made after our write while rolling the group back.
            const now = snapshot(git, change.before.path) catch continue;
            if (!sameContent(now, change.after_bytes, change.after_mode)) continue;
            if (change.before.bytes) |bytes| {
                _ = replace(git, now, bytes, change.before.stat.?.permissions, true) catch {};
            } else {
                cwd.deleteFile(git.io, git.path(change.before.path) catch continue) catch {};
            }
        }
    }
    try applied.ensureTotalCapacity(git.arena, snapshots.len);
    const track_mode = try tracksExecutable(git);
    for (replacements, worktree_bytes) |replacement, working| {
        const saved = for (snapshots) |s| {
            if (std.mem.eql(u8, s.path, replacement.path)) break s;
        } else return error.UnknownReplacement;
        const mode = try replace(git, saved, working, permissions(saved, replacement.mode, track_mode), saved.stat != null);
        applied.appendAssumeCapacity(.{ .before = saved, .after_bytes = working, .after_mode = mode });
    }
    for (snapshots) |saved| {
        if (saved.bytes == null) continue;
        const retained = for (replacements) |replacement| {
            if (std.mem.eql(u8, replacement.path, saved.path)) break true;
        } else false;
        if (retained) continue;
        try unchanged(git, saved);
        try cwd.deleteFile(git.io, try git.path(saved.path));
        applied.appendAssumeCapacity(.{ .before = saved, .after_bytes = null, .after_mode = .default_file });
    }
    // Newly inserted index-info entries have no stat data. Refresh the prepared
    // index so Git can recognize the completed files during --no-commit/abort.
    const refreshed = try alternate.run(&.{ "update-index", "-q", "--unmerged", "--refresh" });
    if (merge_git.exitCode(refreshed) > 1) return error.GitFailed;
    for (applied.items) |change| {
        if (!sameContent(try snapshot(git, change.before.path), change.after_bytes, change.after_mode)) return error.SourceChanged;
    }
    const index_after = try cwd.readFileAlloc(git.io, alternate_index, git.arena, .limited(256 * 1024 * 1024));
    try checkIndexBytes(git, index_path, index_before);
    // Preserve the existing index permissions; publish only after all worktree operations succeed.
    const index_stat = try cwd.statFile(git.io, index_path, .{ .follow_symlinks = false });
    if (index_stat.kind != .file) return error.UnsupportedFileMode;
    const directory = try cwd.openDir(git.io, std.fs.path.dirname(index_path) orelse ".", .{});
    defer directory.close(git.io);
    var atomic = try directory.createFileAtomic(git.io, std.fs.path.basename(index_path), .{ .replace = true, .permissions = index_stat.permissions });
    defer atomic.deinit(git.io);
    try atomic.file.writeStreamingAll(git.io, index_after);
    try atomic.file.sync(git.io);
    try atomic.replace(git.io);
}

fn sameContent(saved: Snapshot, bytes: ?[]const u8, mode: std.Io.File.Permissions) bool {
    if ((saved.bytes == null) != (bytes == null)) return false;
    if (bytes) |value| {
        const same_mode = if (std.Io.File.Permissions.has_executable_bit)
            saved.stat.?.permissions.toMode() & 0o7777 == mode.toMode() & 0o7777
        else if (@import("builtin").os.tag == .windows)
            // Zig 0.16 readOnly() refers to a removed Windows constant.
            saved.stat.?.permissions.toAttributes().READONLY == mode.toAttributes().READONLY
        else
            saved.stat.?.permissions.readOnly() == mode.readOnly();
        return std.mem.eql(u8, saved.bytes.?, value) and same_mode;
    }
    return true;
}
