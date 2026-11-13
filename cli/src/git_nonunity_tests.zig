const std = @import("std");
const t = @import("testing/git.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

const Context = struct {
    git: Git,
    scratch: []const u8,
    prefablens: []const u8,

    fn repo(self: Context, name: []const u8, files: []const t.FileSides) !Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.scratch, name });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.prefablens, .local, files);
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        return git;
    }
};

pub fn run(git: Git, scratch: []const u8, prefablens: []const u8) !void {
    const ctx: Context = .{ .git = git, .scratch = scratch, .prefablens = prefablens };
    try ordinaryTextConflict(ctx);
    try directoryFileConflict(ctx);
    try defaultRepeatedTextConflict(ctx);
    try replayTextConflict(ctx);
    try std.Io.File.stdout().writeStreamingAll(git.io, "non-Unity merge integration: passed\n");
}

fn defaultRepeatedTextConflict(ctx: Context) !void {
    const path = "Assets/repeated.prefab";
    const git = try ctx.repo("nonunity-repeated-text", &.{.{
        .path = path,
        .base = "B: 0\nC: 0\nC: 0\n",
        .ours = "C: 0\n",
        .theirs = "C: 0\nB: 0\n",
    }});
    const theirs = merge_git.trim(try git.output(&.{ "rev-parse", "remote" }));
    const native = try nativeClone(ctx, git, "native-nonunity-repeated-text", theirs);
    try t.expectCode(try native.run(&.{ "merge", "--no-edit", "-s", "ort", "remote" }), 1, "native repeated-line conflict");
    const setup = try std.process.run(git.arena, git.io, .{
        .argv = &.{ ctx.prefablens, "setup-merge", "--local" },
        .cwd = .{ .path = git.cwd },
        .environ_map = git.env,
    });
    try t.expectCode(setup, 0, "default setup for repeated non-Unity text");

    // Myers can accept this repeated-line edit, while ort's histogram algorithm
    // keeps the competing insertion unresolved. The file driver must agree.
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "preserve native repeated-line conflict");
    try t.require(std.mem.eql(u8, try t.readFile(git.io, git.arena, native.cwd, path), try t.readFile(git.io, git.arena, git.cwd, path)), "fallback changed the native repeated-line conflict");
    try t.require(std.mem.eql(u8, try native.output(&.{ "ls-files", "--unmerged", "-z" }), try git.output(&.{ "ls-files", "--unmerged", "-z" })), "fallback changed the native repeated-line conflict stages");
}

fn ordinaryTextConflict(ctx: Context) !void {
    const path = "Notes/plain.txt";
    const git = try ctx.repo("nonunity-text-conflict", &.{.{
        .path = path,
        .base = "value: base\n",
        .ours = "value: ours\n",
        .theirs = "value: theirs\n",
    }});
    const theirs = merge_git.trim(try git.output(&.{ "rev-parse", "remote" }));
    const native = try nativeClone(ctx, git, "native-nonunity-text-conflict", theirs);
    const native_result = try native.run(&.{ "merge", "--no-edit", "-s", "ort", "remote" });
    try t.expectCode(native_result, 1, "native ort non-Unity text conflict");
    const expected = try t.readFile(git.io, git.arena, native.cwd, path);

    // Conflict markers must name the same real sides as Git's built-in ort strategy.
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "ordinary non-Unity text conflict");
    try t.require(
        std.mem.eql(u8, expected, try t.readFile(git.io, git.arena, git.cwd, path)),
        "plain-text conflict markers differ from Git's original-head merge result",
    );
}

fn directoryFileConflict(ctx: Context) !void {
    const path = "Notes/item.txt";
    const git = try ctx.repo("nonunity-directory-file-conflict", &.{.{
        .path = path,
        .base = "base\n",
        .ours = "ours\n",
        .theirs = "remote\n",
    }});
    try git.ok(&.{ "switch", "-q", "remote" });
    try git.ok(&.{ "rm", "--", path });
    try write(git, "Notes/item.txt/child.txt", "theirs\n");
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "replace file with directory" });
    try git.ok(&.{ "switch", "-q", "local" });

    const theirs = merge_git.trim(try git.output(&.{ "rev-parse", "remote" }));
    const native = try nativeClone(ctx, git, "native-nonunity-directory-file-conflict", theirs);
    const native_result = try native.run(&.{ "merge", "--no-edit", "-s", "ort", "remote" });
    try t.expectCode(native_result, 1, "native ort non-Unity file-directory conflict");
    const expected_paths = try indexPaths(native);

    // File-versus-directory recovery paths must keep the names Git derives from real heads.
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "ordinary non-Unity file-directory conflict");
    const actual_paths = try indexPaths(git);
    try requireSamePaths(expected_paths, actual_paths);
    for (expected_paths) |conflict_path| {
        const expected = try t.readFile(git.io, git.arena, native.cwd, conflict_path);
        const actual = try t.readFile(git.io, git.arena, git.cwd, conflict_path);
        try t.require(std.mem.eql(u8, expected, actual), "file-directory conflict changed a non-Unity worktree file");
    }
}

fn replayTextConflict(ctx: Context) !void {
    const path = "Assets/replay.prefab";
    const git = try ctx.repo("nonunity-replay-text-conflict", &.{.{
        .path = path,
        .base = "value: base\ncontext: base\n",
        .ours = "value: local\ncontext: base\n",
        .theirs = "value: previous\ncontext: inherited\n",
    }});
    try git.ok(&.{ "switch", "-q", "remote" });
    try write(git, path, "value: picked\ncontext: inherited\n");
    try git.ok(&.{ "add", "--", path });
    try git.ok(&.{ "commit", "-qm", "picked 'change' $value" });
    const picked = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    const selected_base = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD^" }));
    try git.ok(&.{ "switch", "-q", "local" });
    const native = try nativeClone(ctx, git, "native-nonunity-replay-text-conflict", picked);
    // Extension-based attributes must preserve native behavior for non-Unity contents too.
    const setup = try std.process.run(git.arena, git.io, .{
        .argv = &.{ ctx.prefablens, "setup-merge", "--local" },
        .cwd = .{ .path = git.cwd },
        .environ_map = git.env,
    });
    try t.expectCode(setup, 0, "default setup before non-Unity replay");
    try git.ok(&.{ "config", "merge.conflictStyle", "diff3" });
    try native.ok(&.{ "config", "merge.conflictStyle", "diff3" });
    const native_result = try native.run(&.{ "cherry-pick", "--strategy=ort", picked });
    try t.expectCode(native_result, 1, "native ort non-Unity replay conflict");
    const expected = try t.readFile(git.io, git.arena, native.cwd, path);
    const stages = [_][]const u8{
        try native.output(&.{ "show", try std.fmt.allocPrint(native.arena, ":1:{s}", .{path}) }),
        try native.output(&.{ "show", try std.fmt.allocPrint(native.arena, ":2:{s}", .{path}) }),
        try native.output(&.{ "show", try std.fmt.allocPrint(native.arena, ":3:{s}", .{path}) }),
    };
    const expected_base = try git.output(&.{ "show", try std.fmt.allocPrint(git.arena, "{s}:{s}", .{ selected_base, path }) });

    // The picked commit's parent defines its delta even when it is not the merge-base of the current heads.
    try t.expectCode(try git.run(&.{ "cherry-pick", picked }), 1, "replay only the selected non-Unity text change");
    try t.require(
        std.mem.eql(u8, expected, try t.readFile(git.io, git.arena, git.cwd, path)),
        "replayed plain-text conflict differs from Git's explicit-base result",
    );
    try t.require(std.mem.eql(u8, expected_base, stages[0]), "native replay did not use the selected commit's parent");
    const actual_base = try git.output(&.{ "show", try std.fmt.allocPrint(git.arena, ":1:{s}", .{path}) });
    try t.require(std.mem.eql(u8, expected_base, actual_base), "replay changed the selected-base conflict stage");
    for (stages[1..], 2..) |expected_stage, index| {
        const actual_stage = try git.output(&.{ "show", try std.fmt.allocPrint(git.arena, ":{d}:{s}", .{ index, path }) });
        try t.require(std.mem.eql(u8, expected_stage, actual_stage), "replay changed a non-Unity conflict input stage");
    }
    try t.require(
        std.mem.indexOf(u8, expected, "context: base") != null,
        "replay imported a prior non-Unity change outside the selected commit",
    );
}

fn nativeClone(ctx: Context, source: Git, name: []const u8, remote: []const u8) !Git {
    const destination = try std.fs.path.join(source.arena, &.{ ctx.scratch, name });
    try source.ok(&.{ "clone", "--quiet", "--no-hardlinks", source.cwd, destination });
    var native = source;
    native.cwd = destination;
    try native.ok(&.{ "update-ref", "refs/heads/remote", remote });
    try native.ok(&.{ "switch", "-q", "local" });
    try t.configureHermeticRepository(native.io, native.arena, native.cwd);
    return native;
}

fn indexPaths(git: Git) ![]const []const u8 {
    const output = try git.output(&.{ "ls-files", "--stage", "-z" });
    var paths: std.ArrayList([]const u8) = .empty;
    var previous: ?[]const u8 = null;
    var records = std.mem.splitScalar(u8, output, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidIndexRecord;
        const path = record[tab + 1 ..];
        if (previous == null or !std.mem.eql(u8, previous.?, path)) try paths.append(git.arena, path);
        previous = path;
    }
    return paths.items;
}

fn requireSamePaths(expected: []const []const u8, actual: []const []const u8) !void {
    try t.require(expected.len == actual.len, "directory-file conflict changed the set of indexed paths");
    for (expected) |path| try t.require(contains(actual, path), "directory-file conflict path differs from Git's original-head result");
    for (actual) |path| try t.require(contains(expected, path), "directory-file conflict added an unexpected index path");
}

fn contains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, needle)) return true;
    return false;
}

fn write(git: Git, path: []const u8, bytes: []const u8) !void {
    const full = try git.path(path);
    try std.Io.Dir.cwd().createDirPath(git.io, std.fs.path.dirname(full).?);
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = full, .data = bytes });
}
