const std = @import("std");
const builtin = @import("builtin");
const t = @import("testing/git.zig");
const pty = @import("testing/pty.zig");
const Session = @import("testing/pty_session.zig");

const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    repo: []const u8,
    env: *std.process.Environ.Map,

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

    fn git(self: Context, args: []const []const u8) !void {
        try t.expectCode(try self.run(try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args })), 0, args[0]);
    }

    fn write(self: Context, path: []const u8, bytes: []const u8) !void {
        try t.writeFile(self.io, self.arena, self.repo, path, bytes);
    }
};

pub fn main(init: std.process.Init) !u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "diffnav integration: skipped on unsupported OS\n");
        return 0;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    try t.require(args.len == 4, "expected PrefabLens, diffnav, and fixture paths");
    const root = try t.scratchDirectory(init.io, arena, "diffnav space 日本語");
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    const repo = try std.fs.path.join(arena, &.{ root, "repository" });
    const bin = try std.fs.path.join(arena, &.{ root, "bin" });
    const user = try std.fs.path.join(arena, &.{ root, "user" });
    for ([_][]const u8{ repo, bin, user }) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);

    var env = try init.environ_map.clone(arena);
    // The fixture must not inherit a caller's worktree, Git configuration, or diffnav theme.
    var inherited = init.environ_map.iterator();
    while (inherited.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "GIT_")) _ = env.swapRemove(entry.key_ptr.*);
    }
    _ = env.swapRemove("NO_COLOR");
    try env.put("HOME", user);
    try env.put("XDG_CONFIG_HOME", user);
    try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(arena, &.{ user, "gitconfig" }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_COUNT", "0");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("DIFFNAV_CONFIG_DIR", user);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ user, "config.yml" }),
        .data = "ui:\n  theme: tokyo_night\n  showFileTree: true\n  showDiffStats: false\n  startFoldersOpenDepth: -1\n  fileTreeWidth: 24\n",
    });
    const ctx: Context = .{ .io = init.io, .arena = arena, .root = root, .repo = repo, .env = &env };
    for ([_][]const u8{ "prefablens", "diffnav" }, args[1..3]) |name, executable| {
        const path = if (std.mem.indexOfScalar(u8, executable, '/') != null) executable else path: {
            const resolved = try ctx.run(&.{ "sh", "-c", "command -v \"$1\"", "resolve-executable", executable });
            try t.expectCode(resolved, 0, name);
            break :path std.mem.trim(u8, resolved.stdout, "\r\n");
        };
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(init.io, path, arena);
        try std.Io.Dir.cwd().symLink(init.io, absolute, try std.fs.path.join(arena, &.{ bin, name }), .{});
    }
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ bin, env.get("PATH") orelse "" }));
    try t.expectCode(try ctx.run(&.{ "delta", "--version" }), 0, "delta is required for test-diffnav");

    try testScreenAssertions();
    try prepare(ctx, args[3]);
    try testSnapshotAssertions(ctx);
    // Zig resolves argv[0] against the parent's PATH, so setup must name the supplied executable.
    try t.expectCode(try ctx.run(&.{ try std.fs.path.join(arena, &.{ bin, "prefablens" }), "setup-diff" }), 0, "register the actual difftool");
    try compare(ctx, "working-tree", "git difftool --dir-diff --no-symlinks", true);
    try compare(ctx, "per-file", "git difftool --no-prompt -- Assets/'00 Cylinder.prefab'", false);
    try ctx.git(&.{ "add", "--all" });
    try compare(ctx, "staged", "git difftool --dir-diff --no-symlinks --cached", false);
    try ctx.git(&.{ "commit", "-qm", "fixture changes" });
    try compare(ctx, "revisions", "git difftool --dir-diff --no-symlinks HEAD~1 HEAD", false);
    try std.Io.File.stdout().writeStreamingAll(init.io, "diffnav integration: passed\n");
    return 0;
}

fn prepare(ctx: Context, fixtures: []const u8) !void {
    const before = try t.readFile(ctx.io, ctx.arena, fixtures, "cylinder_before.prefab");
    const after = try t.readFile(ctx.io, ctx.arena, fixtures, "cylinder_after.prefab");
    try std.Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(ctx.arena, &.{ ctx.repo, "Assets" }));
    try ctx.git(&.{ "init", "-q", "-b", "main" });
    try ctx.git(&.{ "config", "core.autocrlf", "false" });
    try ctx.git(&.{ "config", "commit.gpgSign", "false" });
    try ctx.git(&.{ "config", "core.hooksPath", try std.fs.path.join(ctx.arena, &.{ ctx.root, "no-hooks" }) });
    try ctx.git(&.{ "config", "user.name", "PrefabLens tests" });
    try ctx.git(&.{ "config", "user.email", "prefablens-tests@example.invalid" });
    const files = [_]struct { path: []const u8, before: ?[]const u8, after: ?[]const u8 }{
        .{ .path = "Assets/00 Cylinder.prefab", .before = before, .after = after },
        .{ .path = "Assets/01 Movement.cs", .before = "public float speed = 1;\r\n", .after = "public float speed = 3;\r\n" },
        .{ .path = "Assets/02 Cylinder.prefab.meta", .before = "userData: before\n", .after = "userData: after\n" },
        .{ .path = "Assets/03 Added.prefab", .before = null, .after = after },
        .{ .path = "Assets/04 Removed.prefab", .before = before, .after = null },
        .{ .path = "Assets/05 Formatting.prefab", .before = before, .after = try std.mem.concat(ctx.arena, u8, &.{ before, "# Formatting-only change.\n" }) },
        .{ .path = "Assets/06 Damaged.asset", .before = before, .after = "--- !u!114 &1\nMonoBehaviour:\n  values: [1, 2\n" },
        .{ .path = "Assets/07 LightingData.asset", .before = "\x00binary before\n", .after = "\x00binary after\n" },
        .{ .path = "Assets/08 空 白.prefab", .before = before, .after = after },
    };
    for (files) |file| if (file.before) |bytes| try ctx.write(file.path, bytes);
    try ctx.git(&.{ "add", "--all" });
    try ctx.git(&.{ "commit", "-qm", "fixture baseline" });
    for (files) |file| {
        if (file.after) |bytes| {
            try ctx.write(file.path, bytes);
        } else {
            try std.Io.Dir.cwd().deleteFile(ctx.io, try std.fs.path.join(ctx.arena, &.{ ctx.repo, file.path }));
        }
        if (file.before == null) try ctx.git(&.{ "add", "-N", "--", file.path });
    }
    try std.Io.Dir.cwd().createDirPath(ctx.io, try std.fs.path.join(ctx.arena, &.{ ctx.repo, "Notes", "Nested" }));
    try ctx.write("Notes/Nested/untracked.txt", "Keep this untracked file.\n");
    try std.Io.Dir.cwd().symLink(ctx.io, "missing target", try std.fs.path.join(ctx.arena, &.{ ctx.repo, "untracked-link" }), .{});
}

fn compare(ctx: Context, name: []const u8, command: []const u8, mixed: bool) !void {
    const before = try snapshot(ctx);
    var session = try Session.start(ctx.io, ctx.arena, ctx.repo, ctx.env, try std.fs.path.join(ctx.arena, &.{ ctx.root, name }), command);
    defer session.deinit();
    try session.waitFor(&.{"F1/"});
    if (mixed) try session.waitFor(&.{"GameObject:"});
    try select(&session, "00 Cylinder.prefab", &.{ "Position.x: 0.64596", "v: raw" });
    if (mixed) {
        try session.send("v");
        try session.waitFor(&.{ "v: semantic", "component: {fileID:" });
        // Side-by-side output repeats unchanged context on the same visible row.
        try session.waitForLineCount("component: {fileID:", 2);
        try session.send("s");
        try session.waitForLineCount("component: {fileID:", 1);
        try session.send("s");
        try session.waitForLineCount("component: {fileID:", 2);
        try session.send("s");
        try session.waitFor(&.{ "v: semantic", "m_Name: Cylinder" });
        try session.resize(80, 20);
        try session.send("v");
        try session.waitFor(&.{ "Position.x: 0.64596", "v: raw" });
        try session.resize(100, 24);
        try select(&session, "01 Movement.cs", &.{ "[raw]", "public float speed" });
        try select(&session, "02 Cylinder.prefab.meta", &.{ "[raw]", "userData" });
        try select(&session, "03 Added.prefab", &.{ "[semantic", "Position" });
        try select(&session, "04 Removed.prefab", &.{ "[semantic", "Position" });
        try select(&session, "05 Formatting.prefab", &.{"No semantic changes"});
        try session.send("v");
        try session.waitFor(&.{ "[raw", "Formatting-only change" });
        try select(&session, "06 Damaged.asset", &.{ "[raw]", "[renderer] renderer failed" });
        try session.send("G");
        try session.waitFor(&.{"values: [1, 2"});
        try select(&session, "07 LightingData.asset", &.{ "[raw]", "binary" });
        try select(&session, "08 空 白.prefab", &.{ "[semantic", "Position.x: 0.64596" });
    }
    try session.finish();
    const after = try snapshot(ctx);
    try t.require(snapshotsEqual(before, after), "difftool changed file bytes, permissions, links, index, or configuration");
    try std.Io.File.stdout().writeStreamingAll(ctx.io, try std.fmt.allocPrint(ctx.arena, "diffnav {s}: passed\n", .{name}));
}

fn snapshotsEqual(before: std.StringHashMap([32]u8), after: std.StringHashMap([32]u8)) bool {
    if (before.count() != after.count()) return false;
    var iterator = before.iterator();
    while (iterator.next()) |entry| {
        const current = after.get(entry.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, entry.value_ptr, &current)) return false;
    }
    return true;
}

fn select(session: *Session, name: []const u8, needles: []const []const u8) !void {
    try session.send(try std.fmt.allocPrint(session.arena, "t{s}\r", .{name}));
    // Only the selected pane includes the path prefix; the sidebar also lists every basename.
    const header = try std.fmt.allocPrint(session.arena, "Assets/{s}", .{name[0..2]});
    try session.waitFor(try std.mem.concat(session.arena, []const u8, &.{ &.{header}, needles }));
}

fn snapshot(ctx: Context) !std.StringHashMap([32]u8) {
    var result = std.StringHashMap([32]u8).init(ctx.arena);
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, ctx.repo, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walkSelectively(ctx.arena);
    defer {
        while (walker.stack.items.len != 0) walker.leave(ctx.io);
        walker.deinit();
    }
    try snapshotEntry(ctx, dir, &result, ".");
    try snapshotEntry(ctx, dir, &result, ".git/index");
    try snapshotEntry(ctx, dir, &result, ".git/config");
    while (try walker.next(ctx.io)) |entry| {
        if (std.mem.eql(u8, entry.path, ".git")) continue;
        try snapshotEntry(ctx, dir, &result, entry.path);
        if (entry.kind == .directory) try walker.enter(ctx.io, entry);
    }
    return result;
}

fn snapshotEntry(ctx: Context, dir: std.Io.Dir, result: *std.StringHashMap([32]u8), path: []const u8) !void {
    const stat = try dir.statFile(ctx.io, path, .{ .follow_symlinks = false });
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(try std.fmt.allocPrint(ctx.arena, "{s}:{d}:", .{ @tagName(stat.kind), @intFromEnum(stat.permissions) }));
    switch (stat.kind) {
        .file => hash.update(try dir.readFileAlloc(ctx.io, path, ctx.arena, .limited(1024 * 1024))),
        .sym_link => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            hash.update(buffer[0..try dir.readLink(ctx.io, path, &buffer)]);
        },
        else => {},
    }
    try result.put(try ctx.arena.dupe(u8, path), hash.finalResult());
}

fn testScreenAssertions() !void {
    // Historical captures must not make a cleared view satisfy a later interaction.
    const capture = "\x1b[?1049h\x1b[Hsemantic\x1b[H\x1b[2Kraw\x1b[K";
    try t.require(pty.terminalCaptureContains(capture, "semantic"), "lost historical terminal assertions");
    try t.require(!pty.terminalScreenContains(capture, "semantic"), "a cleared semantic view remained visible");
    try t.require(pty.terminalScreenContains(capture, "raw"), "erase-to-end removed the new raw label");
    try t.require(!pty.terminalScreenContains(capture ++ "\x1b[?1049l", "raw"), "an exited TUI remained visible");
    const header = "\x1b[?1049h\u{25cf} Assets/01 Movement.cs [semantic]\x1b[1;25H[raw]\x1b[K";
    try t.require(pty.terminalScreenContains(header, "Assets/01 Movement.cs [raw]"), "a Unicode icon shifted the updated header");
    const shortened = "\x1b[?1049hsemantic [raw]\x1b[H\x1b[9P";
    try t.require(!pty.terminalScreenContains(shortened, "semantic"), "deleted header characters remained visible");
}

fn testSnapshotAssertions(ctx: Context) !void {
    // Read-only guarantees include untracked files outside Assets and symlink targets.
    const before = try snapshot(ctx);
    const path = "Notes/Nested/untracked.txt";
    const original = try t.readFile(ctx.io, ctx.arena, ctx.repo, path);
    try ctx.write(path, "Changed outside Assets.\n");
    try t.require(!snapshotsEqual(before, try snapshot(ctx)), "snapshot missed a nested untracked write");
    try ctx.write(path, original);

    const file = try std.Io.Dir.cwd().openFile(ctx.io, try std.fs.path.join(ctx.arena, &.{ ctx.repo, path }), .{});
    defer file.close(ctx.io);
    const permissions = (try file.stat(ctx.io)).permissions;
    try file.setPermissions(ctx.io, .fromMode(@intFromEnum(permissions) ^ 0o100));
    try t.require(!snapshotsEqual(before, try snapshot(ctx)), "snapshot missed an executable-bit change");
    try file.setPermissions(ctx.io, permissions);

    const link = try std.fs.path.join(ctx.arena, &.{ ctx.repo, "untracked-link" });
    try std.Io.Dir.cwd().deleteFile(ctx.io, link);
    try std.Io.Dir.cwd().symLink(ctx.io, "another missing target", link, .{});
    try t.require(!snapshotsEqual(before, try snapshot(ctx)), "snapshot missed a changed symlink target");
    try std.Io.Dir.cwd().deleteFile(ctx.io, link);
    try std.Io.Dir.cwd().symLink(ctx.io, "missing target", link, .{});
    try t.require(snapshotsEqual(before, try snapshot(ctx)), "restoring fixture bytes did not restore the snapshot");
}
