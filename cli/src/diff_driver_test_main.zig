const std = @import("std");
const t = @import("testing/git.zig");

const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    repo: []const u8,
    env: *std.process.Environ.Map,
    before: []const u8,
    after: []const u8,

    fn run(self: Context, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.arena, self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.repo },
            .environ_map = self.env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
        });
    }

    fn git(self: Context, args: []const []const u8) !std.process.RunResult {
        return self.run(try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args }));
    }

    fn gitOk(self: Context, args: []const []const u8) !void {
        try t.expectCode(try self.git(args), 0, args[0]);
    }

    fn write(self: Context, path: []const u8, bytes: []const u8) !void {
        try t.writeFile(self.io, self.arena, self.repo, path, bytes);
    }
};

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    try t.require(args.len == 3, "expected the prefablens executable and fixture directory");
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], arena);
    const fixtures = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], arena);
    const scratch = try t.scratchDirectory(init.io, arena, "diff-driver space 日本語");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const repo = try std.fs.path.join(arena, &.{ scratch, "repository" });
    const user = try std.fs.path.join(arena, &.{ scratch, "user" });
    try std.Io.Dir.cwd().createDirPath(init.io, repo);
    try std.Io.Dir.cwd().createDirPath(init.io, user);

    var env = try init.environ_map.clone(arena);
    var inherited = init.environ_map.iterator();
    while (inherited.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "GIT_")) _ = env.swapRemove(entry.key_ptr.*);
    }
    try env.put("HOME", user);
    try env.put("XDG_CONFIG_HOME", user);
    try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(arena, &.{ user, "gitconfig" }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_COUNT", "0");
    try env.put("GIT_CEILING_DIRECTORIES", scratch);
    try env.put("GIT_PAGER", "cat");
    try env.put("NO_COLOR", "1");
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
        std.fs.path.dirname(prefablens).?,
        std.fs.path.delimiter,
        env.get("PATH") orelse "",
    }));

    const ctx: Context = .{
        .io = init.io,
        .arena = arena,
        .root = scratch,
        .repo = repo,
        .env = &env,
        .before = try t.readFile(init.io, arena, fixtures, "cylinder_before.prefab"),
        .after = try t.readFile(init.io, arena, fixtures, "cylinder_after.prefab"),
    };
    try prepare(ctx, prefablens);
    try testMixedWorkingTree(ctx);
    try testAddedAndDeleted(ctx);
    try testRename(ctx);
    try testUnmergedDoesNotAbort(ctx);
    try std.Io.File.stdout().writeStreamingAll(init.io, "diff driver integration: passed\n");
    return 0;
}

fn prepare(ctx: Context, prefablens: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(ctx.arena, &.{ ctx.repo, "Assets" }));
    try ctx.gitOk(&.{ "init", "-q", "-b", "main" });
    try t.configureHermeticRepository(ctx.io, ctx.arena, ctx.repo);
    try ctx.gitOk(&.{ "config", "user.name", "PrefabLens tests" });
    try ctx.gitOk(&.{ "config", "user.email", "prefablens-tests@example.invalid" });
    try ctx.gitOk(&.{ "config", "color.ui", "never" });
    try ctx.write("Assets/Cylinder.prefab", ctx.before);
    try ctx.write("Assets/Movement.cs", "public float speed = 1;\n");
    try ctx.gitOk(&.{ "add", "--all" });
    try ctx.gitOk(&.{ "commit", "-qm", "base" });
    try t.expectCode(try ctx.run(&.{ prefablens, "setup-diff" }), 0, "register the diff driver");
    const attr = try t.readFile(ctx.io, ctx.arena, ctx.repo, ".git/info/attributes");
    try t.require(std.mem.indexOf(u8, attr, "*.prefab diff=prefablens\n") != null, "setup omitted the prefab diff rule");
    try t.require(std.mem.indexOf(u8, attr, "*.cs diff=prefablens") == null, "setup selected C# files");
    const command = try ctx.git(&.{ "config", "--local", "--get", "diff.prefablens.command" });
    try t.expectCode(command, 0, "read diff driver command");
    try t.require(
        std.mem.eql(u8, std.mem.trim(u8, command.stdout, " \t\r\n"), "prefablens diff-driver"),
        "setup wrote the wrong driver command",
    );
}

fn testMixedWorkingTree(ctx: Context) !void {
    try ctx.gitOk(&.{ "reset", "-q", "--hard", "HEAD" });
    try ctx.write("Assets/Cylinder.prefab", ctx.after);
    try ctx.write("Assets/Movement.cs", "public float speed = 3;\n");
    const result = try ctx.git(&.{ "--no-pager", "diff" });
    try t.expectCode(result, 0, "mixed git diff");
    try t.require(std.mem.indexOf(u8, result.stderr, "external diff died") == null, "driver aborted git diff");
    try t.require(std.mem.indexOf(u8, result.stdout, "Assets/Cylinder.prefab") != null, "missing prefab path");
    try t.require(std.mem.indexOf(u8, result.stdout, "Position.x: 0.64596 → 1") != null, "missing semantic prefab diff");
    try t.require(std.mem.indexOf(u8, result.stdout, "diff --git") != null, "missing unified diff header for C#");
    try t.require(std.mem.indexOf(u8, result.stdout, "speed = 3") != null, "missing C# unified diff");
}

fn testAddedAndDeleted(ctx: Context) !void {
    try ctx.gitOk(&.{ "reset", "-q", "--hard", "HEAD" });
    try ctx.write("Assets/Added.prefab", ctx.after);
    try ctx.gitOk(&.{ "rm", "-q", "Assets/Cylinder.prefab" });
    try ctx.gitOk(&.{ "add", "Assets/Added.prefab" });
    const result = try ctx.git(&.{ "--no-pager", "diff", "--cached", "--no-renames" });
    try t.expectCode(result, 0, "added and deleted git diff");
    try t.require(std.mem.indexOf(u8, result.stderr, "external diff died") == null, "driver aborted git diff");
    try t.require(std.mem.indexOf(u8, result.stdout, "Assets/Added.prefab") != null, "missing added prefab");
    try t.require(std.mem.indexOf(u8, result.stdout, "Assets/Cylinder.prefab") != null, "missing deleted prefab");
}

fn testRename(ctx: Context) !void {
    try ctx.gitOk(&.{ "reset", "-q", "--hard", "HEAD" });
    try ctx.gitOk(&.{ "mv", "Assets/Cylinder.prefab", "Assets/Renamed.prefab" });
    const mutated = try std.fmt.allocPrint(ctx.arena, "{s}# renamed\n", .{ctx.after});
    try ctx.write("Assets/Renamed.prefab", mutated);
    const result = try ctx.git(&.{ "--no-pager", "diff", "-M", "HEAD" });
    try t.expectCode(result, 0, "renamed git diff");
    try t.require(
        std.mem.indexOf(u8, result.stdout, "Assets/Renamed.prefab") != null or
            std.mem.indexOf(u8, result.stdout, "Assets/Cylinder.prefab") != null,
        "missing rename path",
    );
}

fn testUnmergedDoesNotAbort(ctx: Context) !void {
    try ctx.gitOk(&.{ "reset", "-q", "--hard", "HEAD" });
    try ctx.gitOk(&.{ "checkout", "-qb", "theirs" });
    const theirs = try std.mem.replaceOwned(u8, ctx.arena, ctx.after, "x: 1,", "x: 2,");
    try ctx.write("Assets/Cylinder.prefab", theirs);
    try ctx.gitOk(&.{ "add", "--all" });
    try ctx.gitOk(&.{ "commit", "-qm", "theirs" });
    try ctx.gitOk(&.{ "checkout", "-q", "main" });
    try ctx.write("Assets/Cylinder.prefab", ctx.after);
    try ctx.gitOk(&.{ "add", "--all" });
    try ctx.gitOk(&.{ "commit", "-qm", "ours" });
    const merge = try ctx.git(&.{ "merge", "--no-edit", "theirs" });
    try t.expectNonzero(merge, "prepare unmerged prefab");
    const result = try ctx.git(&.{ "--no-pager", "diff" });
    try t.expectCode(result, 0, "git diff during conflict");
    try t.require(std.mem.indexOf(u8, result.stderr, "external diff died") == null, "unmerged path aborted git diff");
}
