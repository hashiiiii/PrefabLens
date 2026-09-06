const std = @import("std");
const core = @import("core");
const merge_git = @import("merge_git.zig");
const merge_io = @import("merge_io.zig");
const atomic_file = @import("atomic_file.zig");
const merge_ui_state = @import("merge_ui_state.zig");
const merge_tui = @import("merge_tui.zig");
const fallback = @import("merge_fallback.zig");
const file_conflict = @import("merge_file_conflict.zig");
const installation = @import("installation.zig");
const strategy_revisions = @import("merge_strategy_revisions.zig");
const Git = merge_git.Git;

pub const Stage = struct {
    mode: []const u8,
    oid: []const u8,
    number: u8,
    path: []const u8,
    record: []const u8,
};
pub const Conflict = struct { paths: []const []const u8, kind: []const u8, message: []const u8 };
pub const Result = struct { tree: []const u8, stages: []const Stage, conflicts: []const Conflict, ours: []const u8 = "HEAD", theirs: ?[]const u8 = null, index_before: ?[]const u8 = null, sources: ?strategy_revisions.Sources = null };

fn validOid(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Result {
    var records = std.mem.splitScalar(u8, bytes, 0);
    const tree = records.next() orelse return error.InvalidMergeOutput;
    if (!validOid(tree)) return error.InvalidMergeOutput;
    var stages: std.ArrayList(Stage) = .empty;
    while (records.next()) |record| {
        if (record.len == 0) break;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidMergeOutput;
        var metadata = std.mem.splitScalar(u8, record[0..tab], ' ');
        const mode = metadata.next() orelse return error.InvalidMergeOutput;
        const oid = metadata.next() orelse return error.InvalidMergeOutput;
        const number = try std.fmt.parseInt(u8, metadata.next() orelse return error.InvalidMergeOutput, 10);
        if (metadata.next() != null or !validOid(oid) or number < 1 or number > 3 or record.len == tab + 1)
            return error.InvalidMergeOutput;
        try stages.append(arena, .{ .mode = mode, .oid = oid, .number = number, .path = record[tab + 1 ..], .record = record });
    }
    var conflicts: std.ArrayList(Conflict) = .empty;
    while (records.next()) |count_text| {
        if (count_text.len == 0) break;
        const count = try std.fmt.parseInt(usize, count_text, 10);
        if (count > bytes.len) return error.InvalidMergeOutput;
        const paths = try arena.alloc([]const u8, count);
        for (paths) |*path| path.* = records.next() orelse return error.InvalidMergeOutput;
        const kind = records.next() orelse return error.InvalidMergeOutput;
        const message = records.next() orelse return error.InvalidMergeOutput;
        if (std.mem.startsWith(u8, kind, "CONFLICT")) try conflicts.append(arena, .{ .paths = paths, .kind = kind, .message = message });
    }
    return .{ .tree = tree, .stages = try stages.toOwnedSlice(arena), .conflicts = try conflicts.toOwnedSlice(arena) };
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, env: *std.process.Environ.Map, stderr: *std.Io.Writer) !u8 {
    var git_env = try env.clone(arena);
    for ([_][]const u8{ "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS" }) |key| _ = git_env.swapRemove(key);
    try git_env.put("GIT_LITERAL_PATHSPECS", "1");
    const git: Git = .{ .io = io, .arena = arena, .env = &git_env };
    try installation.requireCompatible(git);
    const v = try merge_git.version(git);
    if (!v.atLeast(2, 39)) {
        try stderr.writeAll("prefablens: Automatic merge needs Git 2.39 or later.\n");
        return 2;
    }
    const separator = for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else return error.InvalidStrategyArguments;
    if (args.len - separator != 3) return error.InvalidStrategyArguments;
    var options: std.ArrayList([]const u8) = .empty;
    var base_count: usize = 0;
    for (args[0..separator]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!v.atLeast(2, 43)) {
                try stderr.writeAll("prefablens: Git strategy options (-X) need Git 2.43 or later. No merge files were changed.\n");
                return 2;
            }
            try options.append(arena, try std.fmt.allocPrint(arena, "-X{s}", .{arg[2..]}));
        } else {
            if (!validOid(arg)) return error.InvalidStrategyArguments;
            base_count += 1;
        }
    }
    const head = args[separator + 1];
    const remote = args[separator + 2];
    if (!validOid(remote) or (!std.mem.eql(u8, head, "HEAD") and !validOid(head))) return error.InvalidStrategyArguments;
    const sources = try strategy_revisions.read(git, head, remote);
    try sources.apply(&git_env);
    const index_before = try std.Io.Dir.cwd().readFileAlloc(io, try indexPath(git), arena, .limited(256 * 1024 * 1024));
    if (merge_git.exitCode(try git.run(&.{ "diff-index", "--cached", "--quiet", sources.ours, "--" })) != 0) {
        try stderr.writeAll("prefablens: Commit or unstage index changes before this merge.\n");
        return 2;
    }
    if (base_count == 0) try options.append(arena, "--allow-unrelated-histories");
    const merge_args = try std.mem.concat(arena, []const u8, &.{ &.{ "merge-tree", "--write-tree", "-z", "--messages" }, options.items, &.{ sources.ours, sources.theirs } });
    const output = try git.run(merge_args);
    if (merge_git.exitCode(output) > 1) {
        try stderr.writeAll(output.stderr);
        return 2;
    }
    var result = try parse(arena, output.stdout);
    result.ours = sources.ours;
    result.theirs = sources.theirs;
    result.index_before = index_before;
    result.sources = sources;
    try install(git, sources.ours, result);
    return resolveSession(git, result, env, stderr) catch |err| {
        try stderr.print("prefablens: Merge remains unresolved: {s}.\n", .{@errorName(err)});
        return 1;
    };
}

fn resolveSession(git: Git, result: Result, env: *std.process.Environ.Map, stderr: *std.Io.Writer) !u8 {
    // Git still owns MERGE_HEAD, merge commits, squash and abort after this command returns.
    const tty = (std.Io.File.stdin().isTty(git.io) catch false) and (std.Io.File.stdout().isTty(git.io) catch false);
    var resolved: std.StringHashMap(void) = .init(git.arena);
    var aborted = false;
    // File groups retire matching metadata conflicts before the content pass considers them.
    if (tty) for (result.conflicts) |conflict| {
        if (!isStructural(conflict.kind) or allResolved(conflict.paths, &resolved)) continue;
        switch (try file_conflict.resolve(git, result, conflict, env)) {
            .unresolved => {},
            .aborted => {
                aborted = true;
                break;
            },
            .resolved => |paths| for (paths) |path| {
                try resolved.put(path, {});
            },
        }
    };
    for (result.conflicts) |conflict| {
        if (aborted) break;
        if (allResolved(conflict.paths, &resolved)) continue;
        if (tty and std.mem.eql(u8, conflict.kind, "CONFLICT (contents)") and conflict.paths.len == 1) {
            const path = conflict.paths[0];
            switch (try resolveContent(git, result, path, env)) {
                .resolved => try resolved.put(path, {}),
                .aborted => break,
                .unresolved => {},
            }
        }
    }
    var unresolved = false;
    for (result.conflicts) |conflict| {
        if ((isStructural(conflict.kind) or std.mem.eql(u8, conflict.kind, "CONFLICT (contents)")) and allResolved(conflict.paths, &resolved)) continue;
        unresolved = true;
        try stderr.writeAll(conflict.message);
    }
    const remaining = try git.output(&.{ "ls-files", "--unmerged", "-z" });
    return if (unresolved or remaining.len != 0) 1 else 0;
}

fn isStructural(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "CONFLICT (modify/delete)") or std.mem.eql(u8, kind, "CONFLICT (rename/delete)") or std.mem.eql(u8, kind, "CONFLICT (rename/rename)");
}

fn allResolved(paths: []const []const u8, resolved: *std.StringHashMap(void)) bool {
    if (paths.len == 0) return false;
    for (paths) |path| if (!resolved.contains(path)) return false;
    return true;
}

fn indexPath(git: Git) ![]const u8 {
    const relative = merge_git.trim(try git.output(&.{ "rev-parse", "--git-path", "index" }));
    return if (std.fs.path.isAbsolute(relative)) relative else git.path(relative);
}

fn install(git: Git, head: []const u8, result: Result) !void {
    const index_path = try indexPath(git);
    const lock_path = try std.fmt.allocPrint(git.arena, "{s}.lock", .{index_path});
    const cwd = std.Io.Dir.cwd();
    const lock = try cwd.createFile(git.io, lock_path, .{ .exclusive = true });
    defer {
        lock.close(git.io);
        cwd.deleteFile(git.io, lock_path) catch {};
    }
    const original = try cwd.readFileAlloc(git.io, index_path, git.arena, .limited(256 * 1024 * 1024));
    // A staged source edit can invalidate the candidate's type or inheritance evidence.
    if (result.index_before) |before| if (!std.mem.eql(u8, before, original)) return error.SourceChanged;
    var random: [16]u8 = undefined;
    git.io.random(&random);
    const scratch = try std.fmt.allocPrint(git.arena, "{s}.prefablens-{x}", .{ index_path, random });
    try cwd.createDir(git.io, scratch, .default_dir);
    defer cwd.deleteTree(git.io, scratch) catch {};
    const root = try cwd.realPathFileAlloc(git.io, scratch, git.arena);
    const final_index = try std.fs.path.join(git.arena, &.{ root, "result" });
    const checkout_index = try std.fs.path.join(git.arena, &.{ root, "checkout" });
    try cwd.writeFile(git.io, .{ .sub_path = final_index, .data = original });
    try cwd.writeFile(git.io, .{ .sub_path = checkout_index, .data = original });
    var env = try git.env.clone(git.arena);
    var alternate = git;
    alternate.env = &env;
    try env.put("GIT_INDEX_FILE", final_index);
    try alternate.ok(&.{ "read-tree", result.tree });
    var records: std.ArrayList(u8) = .empty;
    const zero = try git.arena.alloc(u8, result.tree.len);
    @memset(zero, '0');
    var seen: std.StringHashMap(void) = .init(git.arena);
    for (result.stages) |stage| {
        if (seen.contains(stage.path)) continue;
        try seen.put(stage.path, {});
        try records.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "0 {s}\t{s}\x00", .{ zero, stage.path }));
    }
    for (result.stages) |stage| {
        try records.appendSlice(git.arena, stage.record);
        try records.append(git.arena, 0);
    }
    if (records.items.len != 0) try alternate.input(&.{ "update-index", "-z", "--index-info" }, records.items);
    // Build the full conflict index before any worktree writes. Git's two-tree checkout
    // then checks local edits and untracked collisions while the real index stays locked.
    try env.put("GIT_INDEX_FILE", checkout_index);
    try alternate.ok(&.{ "read-tree", "-m", "-u", head, result.tree });
    // Retain checkout stat data so reset --merge can recognize unchanged merged files.
    const checked_out = try cwd.readFileAlloc(git.io, checkout_index, git.arena, .limited(256 * 1024 * 1024));
    try cwd.writeFile(git.io, .{ .sub_path = final_index, .data = checked_out });
    try env.put("GIT_INDEX_FILE", final_index);
    if (records.items.len != 0) try alternate.input(&.{ "update-index", "-z", "--index-info" }, records.items);
    const prepared = try cwd.readFileAlloc(git.io, final_index, git.arena, .limited(256 * 1024 * 1024));
    try env.put("GIT_INDEX_FILE", checkout_index);
    atomic_file.replace(git.io, git.arena, index_path, original, prepared) catch |err| {
        // A failed index write must not leave a clean index beside a merged worktree.
        alternate.ok(&.{ "read-tree", "-m", "-u", result.tree, head }) catch {};
        return err;
    };
}

pub fn side(stages: []const Stage, path: []const u8, number: u8) ?Stage {
    for (stages) |stage| if (stage.number == number and std.mem.eql(u8, stage.path, path)) return stage;
    return null;
}

pub fn blob(git: Git, stage: ?Stage) ![]const u8 {
    const entry = stage orelse return "";
    if (!std.mem.eql(u8, entry.mode, "100644") and !std.mem.eql(u8, entry.mode, "100755")) return error.UnsupportedFileMode;
    return git.output(&.{ "cat-file", "blob", entry.oid });
}

const ContentOutcome = enum { resolved, unresolved, aborted };

fn resolveContent(git: Git, result: Result, path: []const u8, env: *std.process.Environ.Map) !ContentOutcome {
    const base = blob(git, side(result.stages, path, 1)) catch return .unresolved;
    const ours = blob(git, side(result.stages, path, 2)) catch return .unresolved;
    const theirs = blob(git, side(result.stages, path, 3)) catch return .unresolved;
    if (fallback.isBinary(base) or fallback.isBinary(ours) or fallback.isBinary(theirs)) return .unresolved;
    if (!core.isUnityYaml(ours) or !core.isUnityYaml(theirs) or (base.len != 0 and !core.isUnityYaml(base))) return .unresolved;
    var built = core.merge.build(git.arena, base, ours, theirs) catch return .unresolved;
    const prepared = try file_conflict.prepareContent(git, result, path) orelse return .unresolved;
    var state = try merge_ui_state.State.init(git.arena, &built.plan);
    if (state.outcome != .ready) try merge_tui.run(git.io, git.arena, env, &state, path, built.partial);
    if (state.outcome == .aborted) return .aborted;
    if (state.outcome != .ready) return .unresolved;
    const bytes = core.merge.finish(git.arena, &built.plan) catch return .unresolved;
    try file_conflict.finishContent(git, prepared, bytes);
    return .resolved;
}

test "Git strategy: parses structured conflicts with no stage records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Git documents conflicts without unmerged stages. A nonempty tree alone cannot mean clean.
    const output = "a" ** 40 ++ "\x00\x001\x00Assets/New.prefab\x00CONFLICT (file location)\x00Path needs a decision.\n\x00";
    const parsed = try parse(arena.allocator(), output);
    try std.testing.expectEqual(@as(usize, 0), parsed.stages.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.conflicts.len);
    try std.testing.expectEqualStrings("Assets/New.prefab", parsed.conflicts[0].paths[0]);
}

test "Git strategy: preserves path bytes and rejects truncated relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = "a" ** 40;
    const oid = "b" ** 40;
    const parsed = try parse(arena.allocator(), tree ++ "\x00100644 " ++ oid ++ " 2\tAssets/a\tb\nc.prefab\x00\x001\x00Assets/a\tb\nc.prefab\x00CONFLICT (contents)\x00message\x00");
    try std.testing.expectEqualStrings("Assets/a\tb\nc.prefab", parsed.stages[0].path);
    try std.testing.expectEqualStrings("Assets/a\tb\nc.prefab", parsed.conflicts[0].paths[0]);
    try std.testing.expectError(error.InvalidMergeOutput, parse(arena.allocator(), tree ++ "\x00\x003\x00old\x00ours\x00"));
}

test "Git strategy: a staged source change rejects candidate installation" {
    const testing = std.testing;
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", "/usr/bin:/bin");
    const git: Git = .{ .io = testing.io, .arena = arena, .env = &env, .cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", arena) };
    try git.ok(&.{ "init", "-q" });
    try @import("git_merge_test_main.zig").configureHermeticRepository(testing.io, arena, git.cwd);
    try git.ok(&.{ "config", "user.name", "Fixture" });
    try git.ok(&.{ "config", "user.email", "fixture@example.invalid" });
    try tmp.dir.createDir(testing.io, "Assets", .default_dir);
    const original = "--- !u!114 &1\nMonoBehaviour:\n  value: 1\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/A.prefab", .data = original });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Source.cs", .data = "class Source {}\n" });
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "base" });
    const head = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/A.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  value: 2\n" });
    try git.ok(&.{ "add", "Assets/A.prefab" });
    try git.ok(&.{ "commit", "-qm", "candidate" });
    const tree = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD^{tree}" }));
    try git.ok(&.{ "checkout", "-q", "--detach", head });
    const before = try tmp.dir.readFileAlloc(testing.io, ".git/index", arena, .limited(1024 * 1024));
    // A real staged declaration change arrives after candidate evaluation.
    const changed_source = "class Source { public int[] values; }\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Assets/Source.cs", .data = changed_source });
    try git.ok(&.{ "add", "Assets/Source.cs" });
    const changed_index = try tmp.dir.readFileAlloc(testing.io, ".git/index", arena, .limited(1024 * 1024));
    try testing.expectError(error.SourceChanged, install(git, head, .{ .tree = tree, .stages = &.{}, .conflicts = &.{}, .index_before = before }));
    try testing.expectEqualStrings(original, try tmp.dir.readFileAlloc(testing.io, "Assets/A.prefab", arena, .limited(1024)));
    try testing.expectEqualStrings(changed_source, try tmp.dir.readFileAlloc(testing.io, "Assets/Source.cs", arena, .limited(1024)));
    try testing.expectEqualStrings(changed_index, try tmp.dir.readFileAlloc(testing.io, ".git/index", arena, .limited(1024 * 1024)));
}
