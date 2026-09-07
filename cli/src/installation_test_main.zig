const std = @import("std");
const builtin = @import("builtin");
const t = @import("testing/git.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n";
const merged = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";
const suffix = if (builtin.os.tag == .windows) ".exe" else "";
const primary_name = "prefablens" ++ suffix;
const strategy_name = "git-merge-prefablens";
const stale_strategy_name = "git-merge-prefablens" ++ suffix;
const driver = "prefablens merge-driver %O %A %B %P %L";

const File = enum { missing, primary, script, alternate_primary };
const SetupCase = struct {
    name: []const u8,
    primary: File = .primary,
    strategy: File = .script,
    exec_primary: File = .missing,
    exec_strategy: File = .missing,
    valid: bool = false,
    split: bool = false,
    symlinks: bool = false,
};
const setup_cases = [_]SetupCase{
    .{ .name = "mixed-primary", .primary = .alternate_primary },
    .{ .name = "missing-primary", .primary = .missing },
    .{ .name = "missing-strategy", .strategy = .missing },
    .{ .name = "stale-native-helper", .strategy = .primary },
    .{ .name = "exec-path-strategy-shadow", .exec_strategy = .primary },
    // Git prepends exec-path for the driver too, so a valid terminal PATH alone is insufficient.
    .{ .name = "exec-path-primary-shadow", .exec_primary = .alternate_primary },
    // Git excludes unknown exec-path commands from its custom merge strategy list, even when PATH also contains the name.
    .{ .name = "exec-path-hidden-strategy", .exec_strategy = .script },
    .{ .name = "complete", .valid = true },
    .{ .name = "same-release-copies", .valid = true, .split = true },
    .{ .name = "same-release-symlinks", .valid = true, .symlinks = true },
};
const Drift = enum { missing_primary, missing_strategy, stale_strategy, upgrade };

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    const scratch = try t.scratchDirectory(init.io, a, "installation space 日本語");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    try t.require(args.len == 4, "expected the primary CLI, installed script, and alternate CLI paths");
    var artifacts: [3][]const u8 = undefined;
    for (&artifacts, args[1..4]) |*artifact, path| artifact.* = try std.Io.Dir.cwd().realPathFileAlloc(init.io, path, a);
    var env = try init.environ_map.clone(a);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(a, &.{ scratch, "empty-config" }));
    try env.put("GIT_CONFIG_COUNT", "0");
    const git: Git = .{ .io = init.io, .arena = a, .env = &env };
    const system_exec_path = merge_git.trim(try git.output(&.{"--exec-path"}));
    const clean_path = try cleanPath(git, system_exec_path);
    const ctx: Context = .{ .git = git, .scratch = scratch, .artifacts = artifacts, .clean_path = clean_path };
    var failures: usize = 0;
    for (setup_cases) |case| {
        if (case.symlinks and builtin.os.tag == .windows) continue;
        setupCase(ctx, case) catch |err| {
            std.debug.print("installation setup {s}: {s}\n", .{ case.name, @errorName(err) });
            failures += 1;
        };
    }
    for ([_]Drift{ .missing_primary, .missing_strategy, .stale_strategy, .upgrade }) |drift| {
        runtimeCase(ctx, drift) catch |err| {
            std.debug.print("installation runtime {s}: {s}\n", .{ @tagName(drift), @errorName(err) });
            failures += 1;
        };
    }
    if (failures != 0) return 1;
    try std.Io.File.stdout().writeStreamingAll(init.io, "CLI installation integration: passed\n");
    return 0;
}

const Context = struct {
    git: Git,
    scratch: []const u8,
    artifacts: [3][]const u8,
    clean_path: []const u8,

    fn repo(self: Context, name: []const u8) !Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.scratch, name });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.artifacts[0], .local, &.{.{
            .path = "Assets/A.prefab",
            .base = base,
            .ours = ours,
            .theirs = theirs,
        }});
        return git;
    }

    fn layout(self: Context, name: []const u8, primary: File, strategy: File, symlinks: bool) ![]const u8 {
        const directory = try std.fmt.allocPrint(self.git.arena, "{s} bin 日本語", .{name});
        const path = try std.fs.path.join(self.git.arena, &.{ self.scratch, directory });
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.git.io, path);
        for ([_]File{ primary, strategy }, [_][]const u8{ primary_name, strategy_name }, [_]bool{ false, true }) |file, default_name, is_strategy| {
            const source = switch (file) {
                .missing => continue,
                .primary => self.artifacts[0],
                .script => self.artifacts[1],
                .alternate_primary => self.artifacts[2],
            };
            const filename = if (is_strategy and file == .primary) stale_strategy_name else default_name;
            const destination = try std.fs.path.join(self.git.arena, &.{ path, filename });
            if (symlinks) {
                try cwd.symLink(self.git.io, source, destination, .{});
            } else {
                try cwd.copyFile(source, cwd, destination, self.git.io, .{});
            }
        }
        return path;
    }

    fn environment(self: Context, paths: []const []const u8, exec_path: []const u8) !std.process.Environ.Map {
        var env = try self.git.env.clone(self.git.arena);
        var path: std.ArrayList(u8) = .empty;
        for (paths) |directory| {
            try path.appendSlice(self.git.arena, directory);
            try path.append(self.git.arena, std.fs.path.delimiter);
        }
        try path.appendSlice(self.git.arena, self.clean_path);
        try env.put("PATH", path.items);
        try env.put("GIT_EXEC_PATH", exec_path);
        return env;
    }
};

fn cleanPath(git: Git, exec_path: []const u8) ![]const u8 {
    var clean: std.ArrayList(u8) = .empty;
    const candidates = try std.fmt.allocPrint(git.arena, "{s}{c}{s}", .{ exec_path, std.fs.path.delimiter, git.env.get("PATH") orelse "" });
    var paths = std.mem.splitScalar(u8, candidates, std.fs.path.delimiter);
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        var contaminated = false;
        for ([_][]const u8{ primary_name, strategy_name, stale_strategy_name }) |name| {
            const full = try std.fs.path.join(git.arena, &.{ path, name });
            std.Io.Dir.cwd().access(git.io, full, .{}) catch continue;
            contaminated = true;
        }
        if (contaminated) continue;
        if (clean.items.len != 0) try clean.append(git.arena, std.fs.path.delimiter);
        try clean.appendSlice(git.arena, path);
    }
    return clean.toOwnedSlice(git.arena);
}

fn read(git: Git, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(path), git.arena, .limited(1024 * 1024));
}

fn setup(ctx: Context, git: Git, project: bool) !std.process.RunResult {
    return std.process.run(git.arena, git.io, .{
        .argv = if (project) &.{ ctx.artifacts[0], "setup-merge", "--project" } else &.{ ctx.artifacts[0], "setup-merge" },
        .cwd = .{ .path = git.cwd },
        .environ_map = git.env,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
    });
}

fn setupCase(ctx: Context, case: SetupCase) !void {
    const a = ctx.git.arena;
    const primary = try ctx.layout(try std.fmt.allocPrint(a, "{s}-primary", .{case.name}), case.primary, if (case.split) .missing else case.strategy, case.symlinks);
    const strategy = if (case.split) try ctx.layout(try std.fmt.allocPrint(a, "{s}-strategy", .{case.name}), .missing, case.strategy, false) else primary;
    const exec_path = try ctx.layout(try std.fmt.allocPrint(a, "{s}-exec", .{case.name}), case.exec_primary, case.exec_strategy, false);
    var env = try ctx.environment(&.{ primary, strategy }, exec_path);
    for ([_]bool{ false, true }) |project| {
        var git = try ctx.repo(try std.fmt.allocPrint(a, "{s}-{s}", .{ case.name, if (project) "project" else "local" }));
        git.env = &env;
        const attributes_path = if (project) ".gitattributes" else ".git/info/attributes";
        const attributes = "# Keep the project rules.\n*.txt text\n";
        try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = try git.path(attributes_path), .data = attributes });
        const config = try read(git, ".git/config");
        const result = try setup(ctx, git, project);
        try t.expectCode(result, if (case.valid) 0 else 2, case.name);
        if (!case.valid) {
            try t.expectFile(git.io, a, git.cwd, attributes_path, attributes);
            try t.expectFile(git.io, a, git.cwd, ".git/config", config);
            try t.require(std.mem.indexOf(u8, result.stdout, "ready") == null, "invalid installation reported setup success");
            try t.require(std.mem.indexOf(u8, result.stderr, "prefablens") != null and std.mem.indexOf(u8, result.stderr, "PATH") != null, "installation error omitted the command or PATH repair");
            continue;
        }
        try t.require(std.mem.eql(u8, merge_git.trim(try git.output(&.{ "config", "merge.prefablens.driver" })), driver), "setup pinned the driver to an installation path");
        if (project) {
            try git.ok(&.{ "add", ".gitattributes" });
            try git.ok(&.{ "commit", "-qm", "Share merge rules" });
        }
        try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 0, case.name);
        try t.expectFile(git.io, a, git.cwd, "Assets/A.prefab", merged);
    }
}

fn runtimeCase(ctx: Context, drift: Drift) !void {
    const a = ctx.git.arena;
    const name = try std.fmt.allocPrint(a, "runtime-{s}", .{@tagName(drift)});
    const current = try ctx.layout(try std.fmt.allocPrint(a, "{s}-current", .{name}), .primary, .script, false);
    const empty_exec = try ctx.layout(try std.fmt.allocPrint(a, "{s}-empty-exec", .{name}), .missing, .missing, false);
    var env = try ctx.environment(&.{current}, empty_exec);
    var git = try ctx.repo(name);
    git.env = &env;
    try t.expectCode(try setup(ctx, git, false), 0, "setup before PATH drift");
    const changed = try ctx.layout(try std.fmt.allocPrint(a, "{s}-changed", .{name}), switch (drift) {
        .upgrade => .alternate_primary,
        .missing_primary => .missing,
        else => .primary,
    }, switch (drift) {
        .missing_strategy => .missing,
        .stale_strategy => .primary,
        else => .script,
    }, false);
    env = try ctx.environment(&.{changed}, empty_exec);
    try git.ok(&.{ "update-index", "--refresh" });
    const index = try git.output(&.{ "ls-files", "--stage", "-z" });
    const head = try git.output(&.{ "rev-parse", "HEAD" });
    const objects = try git.output(&.{ "count-objects", "-v" });
    const result = try git.run(&.{ "merge", "--no-edit", "remote" });
    if (drift == .upgrade) {
        try t.expectCode(result, 0, "matching release upgrade without setup");
        try t.expectFile(git.io, a, git.cwd, "Assets/A.prefab", merged);
        return;
    }
    try t.expectNonzero(result, "reject missing or stale commands before the merge tree is written");
    try t.expectFile(git.io, a, git.cwd, "Assets/A.prefab", ours);
    try t.require(std.mem.eql(u8, index, try git.output(&.{ "ls-files", "--stage", "-z" })), "PATH drift changed the index");
    try t.require(std.mem.eql(u8, head, try git.output(&.{ "rev-parse", "HEAD" })), "PATH drift changed HEAD");
    try t.require(std.mem.eql(u8, objects, try git.output(&.{ "count-objects", "-v" })), "PATH drift wrote merge objects");
    const merge_head = try git.run(&.{ "rev-parse", "--verify", "MERGE_HEAD" });
    std.debug.print("runtime {s}: outer Git MERGE_HEAD {s}\n", .{ @tagName(drift), if (merge_git.exitCode(merge_head) == 0) "present" else "absent" });
}
