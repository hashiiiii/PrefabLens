const std = @import("std");
const t = @import("testing/git.zig");

const expected_command = "diffnav --compare --renderer prefablens --renderer-arg=render-diff --renderer-arg=--color --renderer-arg=-- -- \"$LOCAL\" \"$REMOTE\" \"$MERGED\"";
const before_yaml = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 1\n";
const after_yaml = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 2\n";

const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    prefablens: []const u8,
    env: *std.process.Environ.Map,

    fn run(self: Context, cwd: []const u8, args: []const []const u8) !std.process.RunResult {
        return std.process.run(self.arena, self.io, .{
            .argv = try std.mem.concat(self.arena, []const u8, &.{ &.{self.prefablens}, args }),
            .cwd = .{ .path = cwd },
            .environ_map = self.env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
        });
    }

    fn git(self: Context, cwd: []const u8, args: []const []const u8) !std.process.RunResult {
        return std.process.run(self.arena, self.io, .{
            .argv = try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args }),
            .cwd = .{ .path = cwd },
            .environ_map = self.env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
        });
    }

    fn gitOk(self: Context, cwd: []const u8, args: []const []const u8) !void {
        try t.expectCode(try self.git(cwd, args), 0, args[0]);
    }

    fn repository(self: Context, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.arena, &.{ self.root, name });
        try std.Io.Dir.cwd().createDirPath(self.io, path);
        try self.gitOk(path, &.{ "init", "-q", "-b", "main" });
        try self.gitOk(path, &.{ "config", "user.name", "PrefabLens tests" });
        try self.gitOk(path, &.{ "config", "user.email", "prefablens-tests@example.invalid" });
        return path;
    }
};

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const root = try t.scratchDirectory(init.io, arena, "diff setup space 日本語");
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    const outside = try std.fs.path.join(arena, &.{ root, "outside" });
    const home = try std.fs.path.join(arena, &.{ root, "home" });
    try std.Io.Dir.cwd().createDirPath(init.io, outside);
    try std.Io.Dir.cwd().createDirPath(init.io, home);

    var env = try init.environ_map.clone(arena);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "XDG_CONFIG_HOME" }) |key| _ = env.swapRemove(key);
    try env.put("HOME", home);
    try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(arena, &.{ home, ".gitconfig" }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_COUNT", "0");
    try env.put("GIT_CEILING_DIRECTORIES", root);

    const ctx: Context = .{
        .io = init.io,
        .arena = arena,
        .root = root,
        .prefablens = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], arena),
        .env = &env,
    };
    const cases = .{ help, repositoryScopes, linkedWorktree, userScope, outsideRepository, invalidArguments, renderer };
    var failures: usize = 0;
    inline for (cases) |case| {
        case(ctx, outside) catch |err| {
            std.debug.print("diff integration case failed: {s}\n", .{@errorName(err)});
            failures += 1;
        };
    }
    if (failures != 0) return 1;
    try std.Io.File.stdout().writeStreamingAll(init.io, "diff integration: passed\n");
    return 0;
}

fn requireContains(haystack: []const u8, needle: []const u8, message: []const u8) !void {
    try t.require(std.mem.indexOf(u8, haystack, needle) != null, message);
}

fn read(ctx: Context, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1024 * 1024));
}

fn expectAbsent(ctx: Context, path: []const u8) !void {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.UnexpectedFile;
}

fn config(ctx: Context, cwd: []const u8, scope: []const u8, key: []const u8) ![]const u8 {
    const result = try ctx.git(cwd, &.{ "config", scope, "--get", key });
    try t.expectCode(result, 0, key);
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

fn expectConfiguration(ctx: Context, cwd: []const u8, scope: []const u8) !void {
    try t.require(std.mem.eql(u8, try config(ctx, cwd, scope, "diff.tool"), "prefablens"), "setup wrote the wrong diff.tool value");
    try t.require(std.mem.eql(u8, try config(ctx, cwd, scope, "difftool.prefablens.cmd"), expected_command), "setup wrote the wrong difftool command");
}

fn help(ctx: Context, outside: []const u8) !void {
    for ([_][]const []const u8{ &.{ "render-diff", "--help" }, &.{ "render-diff", "-h" }, &.{ "setup-diff", "--help" }, &.{ "setup-diff", "-h" } }) |args| {
        const result = try ctx.run(outside, args);
        try t.expectCode(result, 0, "help outside a repository");
        try t.require(result.stderr.len == 0, "help wrote stderr");
        try requireContains(result.stdout, args[0], "help omitted its command name");
    }
    const top_level = try ctx.run(outside, &.{"--help"});
    try t.expectCode(top_level, 0, "top-level help");
    try requireContains(top_level.stdout, "prefablens setup-diff [--local|--user]", "top-level help omitted diff setup");
    try expectAbsent(ctx, ctx.env.get("GIT_CONFIG_GLOBAL").?);
}

fn repositoryScopes(ctx: Context, _: []const u8) !void {
    const cases = [_]struct { name: []const u8, args: []const []const u8 }{
        .{ .name = "default", .args = &.{} },
        .{ .name = "explicit-local", .args = &.{"--local"} },
    };
    for (cases) |case| {
        const repo = try ctx.repository(case.name);
        const nested = try std.fs.path.join(ctx.arena, &.{ repo, "Assets", "Nested" });
        try std.Io.Dir.cwd().createDirPath(ctx.io, nested);
        const attributes = try std.fs.path.join(ctx.arena, &.{ repo, ".gitattributes" });
        const info_attributes = try std.fs.path.join(ctx.arena, &.{ repo, ".git", "info", "attributes" });
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = attributes, .data = "*.prefab diff=keep\n" });
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = info_attributes, .data = "*.asset -diff\n" });
        try ctx.gitOk(repo, &.{ "config", "prefablens.test.keep", "yes" });
        for (0..2) |_| {
            const result = try ctx.run(nested, try std.mem.concat(ctx.arena, []const u8, &.{ &.{"setup-diff"}, case.args }));
            try t.expectCode(result, 0, case.name);
            try requireContains(result.stdout, "registered", "setup did not describe configuration registration");
        }
        try expectConfiguration(ctx, nested, "--local");
        try t.require(std.mem.eql(u8, try config(ctx, repo, "--local", "prefablens.test.keep"), "yes"), "setup changed unrelated local configuration");
        try t.require(std.mem.eql(u8, try read(ctx, attributes), "*.prefab diff=keep\n"), "setup changed repository attributes");
        try t.require(std.mem.eql(u8, try read(ctx, info_attributes), "*.asset -diff\n"), "setup changed local attributes");
    }
    try expectAbsent(ctx, ctx.env.get("GIT_CONFIG_GLOBAL").?);
}

fn linkedWorktree(ctx: Context, _: []const u8) !void {
    const repo = try ctx.repository("worktree-source");
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = try std.fs.path.join(ctx.arena, &.{ repo, "tracked" }), .data = "base\n" });
    try ctx.gitOk(repo, &.{ "add", "tracked" });
    try ctx.gitOk(repo, &.{ "commit", "-qm", "base" });
    const linked = try std.fs.path.join(ctx.arena, &.{ ctx.root, "linked worktree" });
    try ctx.gitOk(repo, &.{ "worktree", "add", "-q", "-b", "linked", linked });
    const nested = try std.fs.path.join(ctx.arena, &.{ linked, "Assets" });
    try std.Io.Dir.cwd().createDirPath(ctx.io, nested);
    try t.expectCode(try ctx.run(nested, &.{ "setup-diff", "--local" }), 0, "linked worktree setup");
    try expectConfiguration(ctx, linked, "--local");
}

fn userScope(ctx: Context, outside: []const u8) !void {
    try ctx.gitOk(outside, &.{ "config", "--global", "prefablens.test.keep", "yes" });
    for (0..2) |_| try t.expectCode(try ctx.run(outside, &.{ "setup-diff", "--user" }), 0, "user setup");
    try expectConfiguration(ctx, outside, "--global");
    try t.require(std.mem.eql(u8, try config(ctx, outside, "--global", "prefablens.test.keep"), "yes"), "setup changed unrelated global configuration");
}

fn outsideRepository(ctx: Context, outside: []const u8) !void {
    const result = try ctx.run(outside, &.{"setup-diff"});
    try t.expectCode(result, 2, "local setup outside a repository");
    try requireContains(result.stderr, "setup-diff --user", "outside-repository error omitted user setup guidance");
}

fn invalidArguments(ctx: Context, _: []const u8) !void {
    const repo = try ctx.repository("invalid");
    try ctx.gitOk(repo, &.{ "config", "prefablens.test.keep", "yes" });
    const local_path = try std.fs.path.join(ctx.arena, &.{ repo, ".git", "config" });
    const local_before = try ctx.arena.dupe(u8, try read(ctx, local_path));
    const global_path = ctx.env.get("GIT_CONFIG_GLOBAL").?;
    const global_before = try ctx.arena.dupe(u8, try read(ctx, global_path));
    const attributes = try std.fs.path.join(ctx.arena, &.{ repo, ".gitattributes" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = attributes, .data = "keep\n" });
    for ([_][]const []const u8{ &.{ "setup-diff", "--project" }, &.{ "setup-diff", "--local", "--user" }, &.{ "setup-diff", "--unknown" }, &.{ "setup-diff", "extra" } }) |args| {
        const result = try ctx.run(repo, args);
        try t.expectCode(result, 2, "invalid setup arguments");
        try requireContains(result.stderr, "usage:", "invalid setup arguments omitted usage");
        try t.require(std.mem.eql(u8, local_before, try read(ctx, local_path)), "invalid setup changed local configuration");
        try t.require(std.mem.eql(u8, global_before, try read(ctx, global_path)), "invalid setup changed global configuration");
        try t.require(std.mem.eql(u8, try read(ctx, attributes), "keep\n"), "invalid setup changed attributes");
    }
}

fn renderer(ctx: Context, outside: []const u8) !void {
    const before_path = try std.fs.path.join(ctx.arena, &.{ outside, "before $(printf wrong)" });
    const after_path = try std.fs.path.join(ctx.arena, &.{ outside, "after 空 白" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = before_path, .data = before_yaml });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = after_path, .data = after_yaml });
    const rendered = try ctx.run(outside, &.{ "render-diff", "--no-color", "--", before_path, after_path, "Assets/Literal.prefab" });
    try t.expectCode(rendered, 0, "literal renderer inputs");
    try t.require(rendered.stderr.len == 0, "renderer wrote stderr for valid inputs");
    try requireContains(rendered.stdout, "1 → 2", "renderer did not compare literal input files");
    try t.require(std.mem.indexOf(u8, rendered.stdout, "\x1b[") == null, "--no-color emitted ANSI escapes");

    const malformed_path = try std.fs.path.join(ctx.arena, &.{ outside, "malformed" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = malformed_path, .data = "--- !u!114 &1\nMonoBehaviour:\n  values: [1, 2\n" });
    const malformed = try ctx.run(outside, &.{ "render-diff", before_path, malformed_path, "Assets/Literal.prefab" });
    try t.expectCode(malformed, 2, "malformed renderer input");
    try t.require(malformed.stdout.len == 0, "malformed renderer input wrote stdout");
    try requireContains(malformed.stderr, "invalid_flow_value", "malformed renderer input omitted syntax diagnostic");
}
