const std = @import("std");
const builtin = @import("builtin");
const t = @import("git_merge_test_main.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n";
const merged = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";
const existing_attributes = "# Keep existing rules.\n*.txt text";

const Context = struct {
    git: Git,
    root: []const u8,
    prefablens: []const u8,

    fn setup(self: Context, git: Git, flags: []const []const u8) !std.process.RunResult {
        return std.process.run(git.arena, git.io, .{
            .argv = try std.mem.concat(git.arena, []const u8, &.{ &.{ self.prefablens, "setup-merge" }, flags }),
            .cwd = .{ .path = git.cwd },
            .environ_map = git.env,
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
        });
    }

    fn repo(self: Context, name: []const u8) !Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.root, name });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.prefablens, .local, &.{.{
            .path = "Assets/A.prefab",
            .base = base,
            .ours = ours,
            .theirs = theirs,
        }});
        // Fixture merge settings would hide a setup command that failed to install its own settings.
        try git.ok(&.{ "config", "--local", "--remove-section", "merge.prefablens" });
        try git.ok(&.{ "config", "--local", "--unset", "core.attributesFile" });
        try std.Io.Dir.cwd().deleteFile(git.io, try git.path(".git/info/attributes"));
        return git;
    }

    fn isolated(self: Context, name: []const u8, xdg: bool) !Context {
        const a = self.git.arena;
        const root = try std.fs.path.join(a, &.{ self.root, name });
        const user_dir = try std.fs.path.join(a, &.{ root, "user" });
        const outside = try std.fs.path.join(a, &.{ root, "outside" });
        try std.Io.Dir.cwd().createDirPath(self.git.io, user_dir);
        try std.Io.Dir.cwd().createDirPath(self.git.io, outside);
        const env = try a.create(std.process.Environ.Map);
        env.* = try self.git.env.clone(a);
        // Child processes must never read or write the developer's user configuration.
        for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "XDG_CONFIG_HOME" }) |key| _ = env.swapRemove(key);
        try env.put("HOME", user_dir);
        try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(a, &.{ user_dir, ".gitconfig" }));
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("GIT_CONFIG_COUNT", "0");
        try env.put("GIT_ATTR_NOSYSTEM", "1");
        try env.put("GIT_CEILING_DIRECTORIES", root);
        if (xdg) try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "config" }));
        return .{ .git = .{ .io = self.git.io, .arena = a, .env = env, .cwd = outside }, .root = root, .prefablens = self.prefablens };
    }
};

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    const scratch = try t.scratchDirectory(init.io, a, "setup space 日本語");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a);
    const script = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a);
    var env = try init.environ_map.clone(a);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}{c}{s}", .{ std.fs.path.dirname(prefablens).?, std.fs.path.delimiter, std.fs.path.dirname(script).?, std.fs.path.delimiter, env.get("PATH") orelse "" }));
    const ctx: Context = .{ .git = .{ .io = init.io, .arena = a, .env = &env }, .root = scratch, .prefablens = prefablens };
    const cases = .{ repositoryScopes, linkedWorktree, outsideRepository, invalidArguments, newUser, userScopes, systemAttributes, invalidUserPaths, userInstallationFailure };
    var failures: usize = 0;
    inline for (cases) |case| {
        case(ctx) catch |err| {
            std.debug.print("merge setup case failed: {s}\n", .{@errorName(err)});
            failures += 1;
        };
    }
    if (failures != 0) return 1;
    try std.Io.File.stdout().writeStreamingAll(init.io, "merge setup integration: passed\n");
    return 0;
}

fn read(git: Git, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(git.io, path, git.arena, .limited(1024 * 1024));
}

fn write(git: Git, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(git.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = path, .data = bytes });
}

fn expectAbsent(git: Git, path: []const u8) !void {
    std.Io.Dir.cwd().access(git.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    std.debug.print("unexpected setup file: {s}\n", .{path});
    return error.TestFailed;
}

fn expectAttributes(git: Git, path: []const u8) !void {
    const attributes = try read(git, path);
    try t.require(std.mem.startsWith(u8, attributes, existing_attributes ++ "\n"), "setup removed existing attributes or joined two rules");
    try t.require(std.mem.count(u8, attributes, "*.prefab merge=prefablens\n") == 1, "setup omitted or duplicated the prefab rule");
    const actual = try git.output(&.{ "check-attr", "merge", "--", "Assets/A.prefab", "Assets/A.unity", "Notes/A.txt" });
    try t.require(std.mem.eql(u8, actual, "Assets/A.prefab: merge: prefablens\nAssets/A.unity: merge: prefablens\nNotes/A.txt: merge: unspecified\n"), "setup did not select the driver for Unity files");
}

fn expectConfiguration(git: Git, scope: []const u8) !void {
    const expected = [_][2][]const u8{
        .{ "merge.prefablens.name", "PrefabLens semantic Unity YAML merge" },
        .{ "merge.prefablens.driver", "prefablens merge-driver %O %A %B %P %L" },
        .{ "merge.prefablens.recursive", "text" },
        .{ "mergetool.prefablens.cmd", "prefablens mergetool \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\"" },
        .{ "mergetool.prefablens.trustExitCode", "true" },
        .{ "pull.twohead", "prefablens" },
    };
    for (expected) |entry| {
        const actual = merge_git.trim(try git.output(&.{ "config", scope, "--get", entry[0] }));
        try t.require(std.mem.eql(u8, actual, entry[1]), "setup wrote the wrong merge configuration or scope");
    }
}

fn expectMerge(git: Git) !void {
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 0, "merge after setup");
    try t.expectFile(git.io, git.arena, git.cwd, "Assets/A.prefab", merged);
}

fn repositoryScopes(parent: Context) !void {
    const ctx = try parent.isolated("repository-scopes", false);
    try ctx.git.ok(&.{ "config", "--global", "prefablens.test.setting", "keep" });
    const global_path = ctx.git.env.get("GIT_CONFIG_GLOBAL").?;
    const global_before = try read(ctx.git, global_path);
    const cases = [_]struct { name: []const u8, flags: []const []const u8, project: bool = false }{
        .{ .name = "default", .flags = &.{} },
        .{ .name = "local", .flags = &.{"--local"} },
        .{ .name = "project", .flags = &.{"--project"}, .project = true },
    };
    for (cases) |case| {
        var git = try ctx.repo(case.name);
        const path = try git.path(if (case.project) ".gitattributes" else ".git/info/attributes");
        try write(git, path, existing_attributes);
        try git.ok(&.{ "config", "--local", "prefablens.test.setting", "keep" });
        // Setup from a subdirectory must still write attributes at the repository root.
        git.cwd = try git.path("Assets");
        for (0..2) |_| try t.expectCode(try ctx.setup(git, case.flags), 0, case.name);
        git.cwd = std.fs.path.dirname(git.cwd).?;
        try expectAttributes(git, path);
        try expectConfiguration(git, "--local");
        try t.require(std.mem.eql(u8, try read(git, global_path), global_before), "repository setup modified global configuration");
        try t.require(std.mem.eql(u8, merge_git.trim(try git.output(&.{ "config", "--local", "prefablens.test.setting" })), "keep"), "setup changed unrelated local configuration");
        try expectAbsent(git, try git.path(if (case.project) ".git/info/attributes" else ".gitattributes"));
        if (case.project) {
            try git.ok(&.{ "add", ".gitattributes" });
            try git.ok(&.{ "commit", "-qm", "Share merge attributes" });
        }
        try expectMerge(git);
    }
}

fn linkedWorktree(parent: Context) !void {
    const ctx = try parent.isolated("linked-worktree", false);
    var git = try ctx.repo("repo");
    const path = try std.fs.path.join(git.arena, &.{ ctx.root, "linked" });
    try git.ok(&.{ "worktree", "add", "-q", "-b", "linked", path });
    const attributes = try git.path(".git/info/attributes");
    try write(git, attributes, existing_attributes);
    git.cwd = path;
    try t.expectCode(try ctx.setup(git, &.{"--local"}), 0, "setup in a linked worktree");
    try expectAttributes(git, attributes);
    try expectConfiguration(git, "--local");
    try expectMerge(git);
}

fn outsideRepository(parent: Context) !void {
    const ctx = try parent.isolated("outside-repository", false);
    const bare_path = try std.fs.path.join(ctx.git.arena, &.{ ctx.root, "bare.git" });
    try ctx.git.ok(&.{ "init", "--bare", "-q", bare_path });
    for ([_][]const u8{ ctx.git.cwd, bare_path }) |path| {
        var git = ctx.git;
        git.cwd = path;
        for ([_][]const []const u8{ &.{}, &.{"--local"}, &.{"--project"} }) |flags| {
            const result = try ctx.setup(git, flags);
            try t.expectCode(result, 2, "setup requires a working tree");
            try t.require(std.mem.indexOf(u8, result.stderr, "working tree") != null and std.mem.indexOf(u8, result.stderr, "setup-merge --user") != null, "setup omitted repository guidance or the user scope command");
            try expectAbsent(git, try git.path(".gitattributes"));
            try expectAbsent(git, try git.path(".git/info/attributes"));
        }
    }
    try expectAbsent(ctx.git, ctx.git.env.get("GIT_CONFIG_GLOBAL").?);
}

fn invalidArguments(parent: Context) !void {
    const ctx = try parent.isolated("invalid-arguments", false);
    const git = try ctx.repo("repo");
    const before = try read(git, try git.path(".git/config"));
    const cases = [_][]const []const u8{
        &.{"--team"},                &.{"--unknown"},           &.{"extra"},                &.{ "--local", "--project" },
        &.{ "--project", "--user" }, &.{ "--user", "--local" }, &.{ "--local", "--local" },
    };
    for (cases) |flags| {
        try t.expectCode(try ctx.setup(git, flags), 2, "invalid setup arguments");
        try t.require(std.mem.eql(u8, before, try read(git, try git.path(".git/config"))), "invalid arguments changed repository configuration");
        try expectAbsent(git, try git.path(".gitattributes"));
        try expectAbsent(git, try git.path(".git/info/attributes"));
        try expectAbsent(git, git.env.get("GIT_CONFIG_GLOBAL").?);
    }
}

fn newUser(parent: Context) !void {
    const ctx = try parent.isolated("new-user", false);
    // Empty XDG_CONFIG_HOME uses the home fallback, even when its parent directories do not exist yet.
    try ctx.git.env.put("XDG_CONFIG_HOME", "");
    const attributes = try std.fs.path.join(ctx.git.arena, &.{ ctx.git.env.get("HOME").?, ".config/git/attributes" });
    try expectAbsent(ctx.git, attributes);
    try expectAbsent(ctx.git, ctx.git.env.get("GIT_CONFIG_GLOBAL").?);
    try t.expectCode(try ctx.setup(ctx.git, &.{"--user"}), 0, "first user setup");
    try expectConfiguration(ctx.git, "--global");
    const repo = try ctx.repo("repo");
    const actual = try repo.output(&.{ "check-attr", "merge", "--", "Assets/A.prefab" });
    try t.require(std.mem.eql(u8, actual, "Assets/A.prefab: merge: prefablens\n"), "first user setup did not create active attributes");
    try expectMerge(repo);
}

fn userScopes(parent: Context) !void {
    const cases = [_]enum { home_default, xdg_default, custom, included, symlink }{ .home_default, .xdg_default, .custom, .included, .symlink };
    for (cases) |case| {
        if (case == .symlink and builtin.os.tag == .windows) continue;
        const ctx = try parent.isolated(@tagName(case), case == .xdg_default);
        const git = ctx.git;
        const user_dir = git.env.get("HOME").?;
        const attributes = switch (case) {
            .home_default => try std.fs.path.join(git.arena, &.{ user_dir, ".config/git/attributes" }),
            .xdg_default => try std.fs.path.join(git.arena, &.{ git.env.get("XDG_CONFIG_HOME").?, "git/attributes" }),
            else => try std.fs.path.join(git.arena, &.{ user_dir, "custom attributes 日本語" }),
        };
        try write(git, attributes, existing_attributes);
        try git.ok(&.{ "config", "--global", "prefablens.test.setting", "keep" });
        if (case == .custom or case == .symlink) try git.ok(&.{ "config", "--global", "core.attributesFile", "~/custom attributes 日本語" });
        if (case == .included) {
            const included = try std.fs.path.join(git.arena, &.{ user_dir, "included config" });
            try git.ok(&.{ "config", "--file", included, "core.attributesFile", "~/custom attributes 日本語" });
            try git.ok(&.{ "config", "--global", "include.path", included });
        }
        const target = try std.fs.path.join(git.arena, &.{ user_dir, "attributes target" });
        if (case == .symlink) {
            try std.Io.Dir.cwd().rename(attributes, .cwd(), target, git.io);
            try std.Io.Dir.cwd().symLink(git.io, target, attributes, .{});
        }
        try t.expectCode(try ctx.setup(git, &.{"--user"}), 0, @tagName(case));
        try expectConfiguration(git, "--global");
        const repo = try ctx.repo("repo");
        const local_attributes = try repo.path("local attributes");
        try write(repo, local_attributes, "*.prefab merge=text\n");
        try repo.ok(&.{ "config", "--local", "core.attributesFile", local_attributes });
        const config_before = try read(repo, try repo.path(".git/config"));
        // A local override must not redirect a later user setup into this repository's attributes file.
        try t.expectCode(try ctx.setup(repo, &.{"--user"}), 0, "repeat user setup inside a repository");
        try t.require(std.mem.eql(u8, config_before, try read(repo, try repo.path(".git/config"))), "user setup changed local configuration");
        try t.require(std.mem.eql(u8, try read(repo, local_attributes), "*.prefab merge=text\n"), "user setup followed a local attributes override");
        try expectAbsent(repo, try repo.path(".gitattributes"));
        try expectAbsent(repo, try repo.path(".git/info/attributes"));
        try repo.ok(&.{ "config", "--local", "--unset", "core.attributesFile" });
        try expectAttributes(repo, attributes);
        try t.require(std.mem.eql(u8, merge_git.trim(try git.output(&.{ "config", "--global", "prefablens.test.setting" })), "keep"), "user setup changed unrelated configuration");
        if (case == .symlink) {
            const stat = try std.Io.Dir.cwd().statFile(git.io, attributes, .{ .follow_symlinks = false });
            try t.require(stat.kind == .sym_link, "user setup replaced an attributes symlink");
            try t.require(std.mem.eql(u8, try read(git, target), try read(git, attributes)), "user setup did not update the symlink target");
        }
        try expectMerge(repo);
    }
}

fn systemAttributes(parent: Context) !void {
    const ctx = try parent.isolated("system-attributes", true);
    const git = ctx.git;
    const system_config = try std.fs.path.join(git.arena, &.{ ctx.root, "system.config" });
    const system_attributes = try std.fs.path.join(git.arena, &.{ ctx.root, "system.attributes" });
    try write(git, system_attributes, "*.txt text\n");
    try git.ok(&.{ "config", "--file", system_config, "core.attributesFile", system_attributes });
    const before = try read(git, system_config);
    try git.env.put("GIT_CONFIG_SYSTEM", system_config);
    _ = git.env.swapRemove("GIT_CONFIG_NOSYSTEM");
    // A system attributes path must not make successful user setup silently ineffective.
    try t.expectCode(try ctx.setup(git, &.{"--user"}), 0, "user setup with system attributes");
    const repo = try ctx.repo("repo");
    const actual = try repo.output(&.{ "check-attr", "merge", "--", "Assets/A.prefab" });
    try t.require(std.mem.eql(u8, actual, "Assets/A.prefab: merge: prefablens\n"), "system configuration bypassed user attributes");
    try t.require(std.mem.eql(u8, before, try read(git, system_config)), "user setup changed system configuration");
    try t.require(std.mem.eql(u8, "*.txt text\n", try read(git, system_attributes)), "user setup changed system attributes");
    try expectMerge(repo);
}

fn invalidUserPaths(parent: Context) !void {
    const ctx = try parent.isolated("invalid-user-paths", false);
    for ([_][]const u8{ "", "relative-attributes" }) |path| {
        try ctx.git.ok(&.{ "config", "--global", "core.attributesFile", path });
        const global_path = ctx.git.env.get("GIT_CONFIG_GLOBAL").?;
        const before = try read(ctx.git, global_path);
        const result = try ctx.setup(ctx.git, &.{"--user"});
        try t.expectCode(result, 2, "invalid user attributes path");
        try t.require(std.mem.indexOf(u8, result.stderr, "core.attributesFile") != null and std.mem.indexOf(u8, result.stderr, "absolute") != null, "invalid attributes path omitted repair guidance");
        try t.require(std.mem.eql(u8, before, try read(ctx.git, global_path)), "invalid user attributes path changed global configuration");
        try expectAbsent(ctx.git, try ctx.git.path("relative-attributes"));
    }
}

fn userInstallationFailure(parent: Context) !void {
    const ctx = try parent.isolated("user-installation-failure", false);
    const attributes = try std.fs.path.join(ctx.git.arena, &.{ ctx.root, "attributes" });
    try write(ctx.git, attributes, existing_attributes);
    try ctx.git.ok(&.{ "config", "--global", "core.attributesFile", attributes });
    const global_path = ctx.git.env.get("GIT_CONFIG_GLOBAL").?;
    const before = try read(ctx.git, global_path);
    const exec_path = try std.fs.path.join(ctx.git.arena, &.{ ctx.root, "exec" });
    try std.Io.Dir.cwd().createDirPath(ctx.git.io, exec_path);
    // A real incompatible executable in Git's exec path must fail validation before any setup writes.
    const shadow_name = if (builtin.os.tag == .windows) "git-merge-prefablens.exe" else "git-merge-prefablens";
    try std.Io.Dir.cwd().copyFile(ctx.prefablens, .cwd(), try std.fs.path.join(ctx.git.arena, &.{ exec_path, shadow_name }), ctx.git.io, .{});
    try ctx.git.env.put("GIT_EXEC_PATH", exec_path);
    const result = try ctx.setup(ctx.git, &.{"--user"});
    try t.expectCode(result, 2, "invalid user installation");
    try t.require(std.mem.indexOf(u8, result.stderr, "PATH") != null, "invalid installation omitted repair guidance");
    try t.require(std.mem.eql(u8, before, try read(ctx.git, global_path)), "invalid installation changed global configuration");
    try t.require(std.mem.eql(u8, existing_attributes, try read(ctx.git, attributes)), "invalid installation changed user attributes");
}
