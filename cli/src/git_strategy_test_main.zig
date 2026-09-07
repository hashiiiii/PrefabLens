const std = @import("std");
const builtin = @import("builtin");
const t = @import("git_merge_test_main.zig");
const pty = @import("pty_smoke_test_main.zig");
const merge_git = @import("merge_git.zig");
const version = @import("build_options").version;
const supports_pty = builtin.os.tag == .linux or builtin.os.tag == .macos;

const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n";
const conflict_theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 3\n  m_Right: 1\n";
const merged = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    const scratch = try t.scratchDirectory(init.io, a, "strategy");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a);
    const strategy_path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a);
    const strategy_version = try std.process.run(a, init.io, .{
        .argv = &.{ prefablens, "merge-strategy", "--version" },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    });
    try t.expectCode(strategy_version, 0, "strategy version command");
    try t.require(std.mem.eql(u8, strategy_version.stdout, "prefablens merge-strategy " ++ version ++ "\n"), "strategy version command printed the wrong output");
    var env = try init.environ_map.clone(a);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}{c}{s}", .{ std.fs.path.dirname(prefablens).?, std.fs.path.delimiter, std.fs.path.dirname(strategy_path).?, std.fs.path.delimiter, env.get("PATH") orelse "" }));
    const ctx: Context = .{ .git = .{ .io = init.io, .arena = a, .env = &env }, .scratch = scratch, .prefablens = prefablens, .fixture_root = args[3] };
    if (args.len == 5 and std.mem.eql(u8, args[4], "private-permissions")) {
        if (supports_pty) try privatePermissions(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "independent-additions")) {
        try independentAdditions(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "clean-renames")) {
        try cleanRenames(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "merge-options")) {
        try mergeOptions(ctx);
        try nonInteractive(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "encoding")) {
        try candidateEncoding(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "transaction-guards")) {
        if (supports_pty) try concurrentContent(ctx);
        try guards(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "candidate-safety")) {
        try addedUnity(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "native-fixtures")) {
        try nativeFixtures(ctx);
        if (supports_pty) try nativeLocalChoices(ctx);
        try candidateEncoding(ctx);
        return 0;
    }
    try automatic(ctx);
    try nonInteractive(ctx);
    try guards(ctx);
    try directoryConflict(ctx);
    try mergeOptions(ctx);
    try independentEdits(ctx);
    try cleanRenames(ctx);
    try nativeFixtures(ctx);
    try candidateEncoding(ctx);
    try addedUnity(ctx);
    if (supports_pty) {
        try nativeLocalChoices(ctx);
        try contentPty(ctx);
        try concurrentContent(ctx);
        try privatePermissions(ctx);
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "git strategy integration: passed\n");
    return 0;
}

const Context = struct {
    git: merge_git.Git,
    scratch: []const u8,
    prefablens: []const u8,
    fixture_root: []const u8,

    fn repo(self: Context, name: []const u8, files: []const t.FileSides) !merge_git.Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.scratch, name });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.prefablens, .local, files);
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        return git;
    }
};

fn readCollectionFile(ctx: Context, root: []const u8, relative: []const u8) ![]const u8 {
    const path = try std.fs.path.join(ctx.git.arena, &.{ root, relative });
    return std.Io.Dir.cwd().readFileAlloc(ctx.git.io, path, ctx.git.arena, .limited(16 * 1024 * 1024));
}

fn expectFile(git: merge_git.Git, path: []const u8, expected: []const u8) !void {
    try t.expectFile(git.io, git.arena, git.cwd, path, expected);
}
fn write(git: merge_git.Git, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(git.io, std.fs.path.dirname(try git.path(path)).?);
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = try git.path(path), .data = bytes });
}
fn markers(git: merge_git.Git, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(path), git.arena, .limited(1024 * 1024));
    try t.require(std.mem.indexOf(u8, bytes, "<<<<<<<") != null, "unresolved text lost conflict markers");
}
fn automatic(ctx: Context) !void {
    for ([_]bool{ false, true }) |no_commit| {
        const git = try ctx.repo(if (no_commit) "no-commit" else "clean", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
        try t.expectCode(try git.run(if (no_commit) &.{ "merge", "--no-commit", "remote" } else &.{ "merge", "--no-edit", "remote" }), 0, "automatic strategy merge");
        try expectFile(git, "Assets/A.prefab", merged);
        if (no_commit) {
            try git.ok(&.{ "rev-parse", "--verify", "MERGE_HEAD" });
            try git.ok(&.{ "merge", "--abort" });
            try expectFile(git, "Assets/A.prefab", ours);
        }
    }
}
fn nonInteractive(ctx: Context) !void {
    const cases = [_]struct { name: []const u8, files: []const t.FileSides }{
        .{ .name = "text", .files = &.{.{ .path = "Notes/A.txt", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" }} },
        .{ .name = "unity", .files = &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs }} },
        .{ .name = "mixed", .files = &.{ .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs }, .{ .path = "Notes/A.txt", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" } } },
    };
    for (cases) |case| {
        const git = try ctx.repo(case.name, case.files);
        try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "noninteractive conflict");
        for (case.files) |file| try markers(git, file.path);
        try t.require((try git.output(&.{ "ls-files", "-u" })).len != 0, "unresolved index was lost");
        try git.ok(&.{ "merge", "--abort" });
        for (case.files) |file| try expectFile(git, file.path, file.ours);
    }
}
fn guards(ctx: Context) !void {
    const git = try ctx.repo("local-edits", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
    try write(git, "Assets/A.prefab", "manual edit\n");
    try t.expectNonzero(try git.run(&.{ "merge", "--no-edit", "remote" }), "overlapping local edits");
    try expectFile(git, "Assets/A.prefab", "manual edit\n");
    try t.require((try git.output(&.{ "ls-files", "-u" })).len == 0, "refused merge changed conflict stages");
    const v = try merge_git.version(git);
    if (!v.atLeast(2, 43)) {
        try t.expectNonzero(try git.run(&.{ "merge", "-Xours", "--no-edit", "remote" }), "old Git strategy option");
        try expectFile(git, "Assets/A.prefab", "manual edit\n");
    }
}
fn runPty(git: merge_git.Git, keys: []const u8) !std.process.RunResult {
    // Git's external strategy inherits this PATH from the shell in the real terminal.
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    return pty.runCommandInPty(git.io, git.arena, git.cwd, command, keys, 30);
}
fn contentPty(ctx: Context) !void {
    const text = try ctx.repo("pty-text-only", &.{
        .{ .path = "Notes/A.txt", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" },
        .{ .path = "Assets/A.prefab", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" },
    });
    // With no input keys, an incorrectly opened UI would block this real terminal merge.
    try t.expectCode(try runPty(text, ""), 1, "non-Unity terminal merge must not open a UI");
    try markers(text, "Notes/A.txt");
    try markers(text, "Assets/A.prefab");
    for ([_]bool{ false, true }) |mixed| {
        const files = [_]t.FileSides{
            .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
            .{ .path = "Notes/A.txt", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" },
        };
        const git = try ctx.repo(if (mixed) "pty-mixed" else "pty-unity", files[0..if (mixed) @as(usize, 2) else 1]);
        try t.expectCode(try runPty(git, "\x1b[C\r\r"), if (mixed) 1 else 0, "resolve Unity through plain merge");
        try expectFile(git, "Assets/A.prefab", ours);
        const unmerged = try git.output(&.{ "ls-files", "-u" });
        try t.require(std.mem.indexOf(u8, unmerged, "A.prefab") == null, "resolved Unity remained unmerged");
        if (mixed) {
            try markers(git, "Notes/A.txt");
            try git.ok(&.{ "rev-parse", "--verify", "MERGE_HEAD" });
            try git.ok(&.{ "merge", "--abort" });
        }
    }
    const git = try ctx.repo("pty-quit", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs }});
    try t.expectCode(try runPty(git, "\x1b[27uy"), 1, "quit plain merge");
    try markers(git, "Assets/A.prefab");
    // Ordinary editing and git add must still complete the merge after PrefabLens quits.
    try write(git, "Assets/A.prefab", ours);
    try git.ok(&.{ "add", "Assets/A.prefab" });
    try git.ok(&.{ "commit", "--no-edit" });
}
fn directoryConflict(ctx: Context) !void {
    const git = try ctx.repo("directory-conflict", &.{
        .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs },
        .{ .path = "Notes/A.txt", .base = "same\n", .ours = "same\n", .theirs = "same\n" },
    });
    try git.ok(&.{ "mv", "Notes", "Renamed" });
    try git.ok(&.{ "commit", "-qm", "Move directory" });
    try git.ok(&.{ "switch", "-q", "remote" });
    try write(git, "Notes/B.txt", "new file\n");
    try git.ok(&.{ "add", "Notes/B.txt" });
    try git.ok(&.{ "commit", "-qm", "Add to old directory" });
    try git.ok(&.{ "switch", "-q", "local" });
    try git.ok(&.{ "config", "merge.directoryRenames", "conflict" });
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "directory rename conflict");
    try git.ok(&.{ "rev-parse", "--verify", "MERGE_HEAD" });
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, "Renamed/A.txt", "same\n");
}

fn mergeOptions(ctx: Context) !void {
    const squash = try ctx.repo("squash", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
    const head = try squash.output(&.{ "rev-parse", "HEAD" });
    try t.expectCode(try squash.run(&.{ "merge", "--squash", "remote" }), 0, "squash through native strategy");
    try expectFile(squash, "Assets/A.prefab", merged);
    try t.require(std.mem.eql(u8, head, try squash.output(&.{ "rev-parse", "HEAD" })), "squash created a commit");
    try t.expectNonzero(try squash.run(&.{ "rev-parse", "--verify", "MERGE_HEAD" }), "squash merge head");

    const unrelated = try ctx.repo("unrelated", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
    try unrelated.ok(&.{ "switch", "--orphan", "disjoint" });
    try write(unrelated, "Other.txt", "unrelated history\n");
    try unrelated.ok(&.{ "add", "Other.txt" });
    try unrelated.ok(&.{ "commit", "-qm", "Other root" });
    try unrelated.ok(&.{ "switch", "-q", "local" });
    try t.expectCode(try unrelated.run(&.{ "merge", "--allow-unrelated-histories", "--no-edit", "disjoint" }), 0, "unrelated histories through native strategy");
    try expectFile(unrelated, "Other.txt", "unrelated history\n");
    try expectFile(unrelated, "Assets/A.prefab", ours);
}

fn independentEdits(ctx: Context) !void {
    const git = try ctx.repo("independent-edit", &.{
        .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs },
        .{ .path = "Notes/A.txt", .base = "same\n", .ours = "same\n", .theirs = "same\n" },
    });
    try write(git, "Notes/A.txt", "manual work\n");
    try write(git, "Notes/Untracked.txt", "keep untracked\n");
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "preserve unrelated edits");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, "Assets/A.prefab", ours);
    try expectFile(git, "Notes/A.txt", "manual work\n");
    try expectFile(git, "Notes/Untracked.txt", "keep untracked\n");

    const collision = try ctx.repo("untracked-collision", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
    try collision.ok(&.{ "switch", "-q", "remote" });
    try write(collision, "Incoming.txt", "incoming\n");
    try collision.ok(&.{ "add", "Incoming.txt" });
    try collision.ok(&.{ "commit", "-qm", "Add incoming file" });
    try collision.ok(&.{ "switch", "-q", "local" });
    try write(collision, "Incoming.txt", "untracked work\n");
    try t.expectNonzero(try collision.run(&.{ "merge", "--no-edit", "remote" }), "untracked collision");
    try expectFile(collision, "Incoming.txt", "untracked work\n");
    try expectFile(collision, "Assets/A.prefab", ours);
}

fn concurrentContent(ctx: Context) !void {
    const manual = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 99\n  m_Right: 1\n";
    const Change = enum { index, source, later_file, later_mode };
    for ([_]Change{ .index, .source, .later_file, .later_mode }) |change| {
        const later_file = change == .later_file or change == .later_mode;
        const files = [_]t.FileSides{
            .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
            .{ .path = "Assets/B.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
        };
        const git = try ctx.repo(switch (change) {
            .index => "concurrent-index",
            .source => "concurrent-source",
            .later_file => "later-file-edit",
            .later_mode => "later-mode-edit",
        }, files[0..if (later_file) @as(usize, 2) else 1]);
        try write(git, ".git/manual-choice", manual);
        const oid = merge_git.trim(try git.output(&.{ "hash-object", "-w", "--no-filters", ".git/manual-choice" }));
        const edit = switch (change) {
            .later_file => "cp .git/manual-choice Assets/B.prefab",
            .later_mode => "chmod 0755 Assets/B.prefab",
            .index => try std.fmt.allocPrint(git.arena, "git update-index --cacheinfo 100644,{s},Assets/A.prefab", .{oid}),
            .source => try std.fmt.allocPrint(git.arena, "git update-index --add --cacheinfo 100644,{s},Assets/Source.cs", .{oid}),
        };
        // Hold the first UI open while another process changes the index or a later file.
        const inner = try std.fmt.allocPrint(git.arena, "(sleep 3; {s}) & exec git merge --no-edit remote", .{edit});
        const command = try std.fmt.allocPrint(git.arena, "env PATH={s} sh -c {s}", .{ try t.shellQuote(git.arena, git.env.get("PATH").?), try t.shellQuote(git.arena, inner) });
        const result = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, "", "\x1b[C\r\r", 30);
        try t.expectCode(result, 1, "preserve changes made while merge UI waits");
        if (later_file) {
            try expectFile(git, "Assets/A.prefab", ours);
            if (change == .later_file) {
                try expectFile(git, "Assets/B.prefab", manual);
            } else {
                try markers(git, "Assets/B.prefab");
                if (std.Io.File.Permissions.has_executable_bit) {
                    const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path("Assets/B.prefab"), .{});
                    try t.require(stat.permissions.toMode() & 0o100 != 0, "Complete removed a concurrent executable-mode change");
                }
            }
            try t.require((try git.output(&.{ "ls-files", "-u", "--", "Assets/B.prefab" })).len != 0, "manual later file was staged by PrefabLens");
        } else {
            try t.require(std.mem.eql(u8, manual, try git.output(&.{ "show", if (change == .source) ":Assets/Source.cs" else ":Assets/A.prefab" })), "Complete overwrote a concurrent index decision");
            try markers(git, "Assets/A.prefab");
        }
    }
}

fn privatePermissions(ctx: Context) !void {
    if (!std.Io.File.Permissions.has_executable_bit) return;
    const git = try ctx.repo("private-mode", &.{
        .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
        .{ .path = "Assets/B.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
    });
    // Delay the real driver so a fixed timer races with checkout even on a fast runner.
    const driver = merge_git.trim(try git.output(&.{ "config", "merge.prefablens.driver" }));
    try git.ok(&.{ "config", "merge.prefablens.driver", try std.fmt.allocPrint(git.arena, "sleep 3; {s}", .{driver}) });
    try git.ok(&.{ "config", "core.trustctime", "true" });
    // Changing the later file while the first UI is open avoids racing with Git's checkout.
    // The second UI's content choice must preserve those private permissions.
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPtyWithUiAction(git.io, git.arena, git.cwd, command, "chmod 0600 Assets/B.prefab", "\x1b[C\r\r", "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "retain private permissions during content resolution");
    try expectFile(git, "Assets/B.prefab", ours);
    const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path("Assets/B.prefab"), .{});
    try t.require(stat.permissions.toMode() & 0o777 == 0o600, "content resolution changed private permissions");
}

fn nativeFixtures(ctx: Context) !void {
    const Case = struct { name: []const u8, conflict: bool, choice: ?[]const u8 = null };
    const Manifest = struct { cases: []const Case };
    const parsed = try std.json.parseFromSlice(Manifest, ctx.git.arena, try readCollectionFile(ctx, ctx.fixture_root, "expected-runtime.json"), .{ .ignore_unknown_fields = true });
    const script = try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/AuditBehaviour.cs");
    const meta = try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/AuditBehaviour.cs.meta");
    for (parsed.value.cases) |case| {
        const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", case.name });
        var files: std.ArrayList(t.FileSides) = .empty;
        var prefab_sides: [3][]const u8 = undefined;
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |side_name, i| {
            prefab_sides[i] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}.prefab", .{side_name}));
        }
        try files.append(ctx.git.arena, .{ .path = "Assets/Plain.prefab", .base = prefab_sides[0], .ours = prefab_sides[1], .theirs = prefab_sides[2] });
        try files.append(ctx.git.arena, .{ .path = "Assets/AuditBehaviour.cs", .base = script, .ours = script, .theirs = script });
        try files.append(ctx.git.arena, .{ .path = "Assets/AuditBehaviour.cs.meta", .base = meta, .ours = meta, .theirs = meta });
        const git = try ctx.repo(try std.fmt.allocPrint(ctx.git.arena, "native-{s}", .{case.name}), files.items);
        std.debug.print("native fixture: {s}\n", .{case.name});
        if (case.conflict) {
            try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "native array fixture retains local choice");
            try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/Plain.prefab" })).len != 0, "native array fixture lost local stages");
            try git.ok(&.{ "merge", "--abort" });
            try expectFile(git, "Assets/Plain.prefab", prefab_sides[1]);
            if (!supports_pty) continue;
            const keys: []const u8 = if (std.mem.eql(u8, case.choice.?, "ours_first")) "\x1b[CT\r\r" else "\x1b[C\x1b[C\r\r";
            const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
            try t.expectCode(try pty.runCommandInPty(git.io, git.arena, git.cwd, command, keys, 30), 0, "native array fixture local choice");
        } else try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "native automatic array fixture");
        try expectFile(git, "Assets/Plain.prefab", try readCollectionFile(ctx, root, "expected.prefab"));
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "native array fixture retained stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, "Assets/Plain.prefab", prefab_sides[1]);
    }
}

fn nativeLocalChoices(ctx: Context) !void {
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n";
    const cases = [_]struct { name: []const u8, base_items: []const u8, ours_items: []const u8, theirs_items: []const u8, expected: []const u8, keys: []const u8 }{
        .{ .name = "native-ours-first", .base_items = "[A]", .ours_items = "[A, Ours]", .theirs_items = "[A, Theirs]", .expected = "[A, Ours, Theirs]", .keys = "\x1b[CT\r\r" },
        .{ .name = "native-theirs-first", .base_items = "[A]", .ours_items = "[A, Ours]", .theirs_items = "[A, Theirs]", .expected = "[A, Theirs, Ours]", .keys = "\x1b[CT\x1b[C\r\r" },
        .{ .name = "native-delete-edit", .base_items = "[A, B, C]", .ours_items = "[A]", .theirs_items = "[A, B, Edited]", .expected = "[A, Edited]", .keys = "\x1b[C\x1b[C\r\r" },
        .{ .name = "native-custom", .base_items = "[A]", .ours_items = "[A, Ours]", .theirs_items = "[A, Theirs]", .expected = "[A, Custom]", .keys = "\x1b[<0;83;5M[Custom]\r\r" },
    };
    for (cases) |case| {
        const git = try ctx.repo(case.name, &.{.{ .path = "Assets/A.prefab", .base = try std.fmt.allocPrint(ctx.git.arena, prefix ++ "  m_Items: {s}\n  m_Left: 1\n  m_Right: 1\n", .{case.base_items}), .ours = try std.fmt.allocPrint(ctx.git.arena, prefix ++ "  m_Items: {s}\n  m_Left: 2\n  m_Right: 1\n", .{case.ours_items}), .theirs = try std.fmt.allocPrint(ctx.git.arena, prefix ++ "  m_Items: {s}\n  m_Left: 1\n  m_Right: 3\n", .{case.theirs_items}) }});
        try t.expectCode(try runPty(git, case.keys), 0, "native local collection choice");
        try expectFile(git, "Assets/A.prefab", try std.fmt.allocPrint(git.arena, prefix ++ "  m_Items: {s}\n  m_Left: 2\n  m_Right: 3\n", .{case.expected}));
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "native local choice retained stages");
    }
}

fn addedUnity(ctx: Context) !void {
    const git = try ctx.repo("added-unity", &.{.{ .path = "Assets/Original.prefab", .base = base, .ours = ours, .theirs = theirs }});
    try git.ok(&.{ "switch", "-q", "remote" });
    const bytes = "--- !u!114 &1\nMonoBehaviour:\n  values: [A, B]\n";
    try write(git, "Assets/Added.prefab", bytes);
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "add collection asset" });
    try git.ok(&.{ "switch", "-q", "local" });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "one-sided added Unity asset");
    try expectFile(git, "Assets/Added.prefab", bytes);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "clean added Unity acquired stages");
    try git.ok(&.{ "merge", "--abort" });
}

fn candidateEncoding(ctx: Context) !void {
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "array-separate-insert" });
    const path = if (builtin.os.tag == .windows) "Assets/CRLF.prefab" else "Assets/a\tb\nc.prefab";
    for ([_]bool{ false, true }) |filtered| {
        var sides: [3][]const u8 = undefined;
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |name, i| {
            const bytes = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}.prefab", .{name}));
            sides[i] = if (filtered)
                try std.fmt.allocPrint(ctx.git.arena, "{s}# canonical-token\n", .{bytes})
            else
                try std.mem.replaceOwned(u8, ctx.git.arena, bytes, "\n", "\r\n");
        }
        const git = try ctx.repo(if (filtered) "candidate-filter" else "candidate-crlf-path-mode", &.{.{ .path = path, .base = sides[0], .ours = sides[1], .theirs = sides[2] }});
        const source_expected = try readCollectionFile(ctx, root, "expected.prefab");
        const expected = if (filtered)
            try std.fmt.allocPrint(git.arena, "{s}# canonical-token\n", .{source_expected})
        else
            try std.mem.replaceOwned(u8, git.arena, source_expected, "\n", "\r\n");
        if (filtered) {
            try git.ok(&.{ "config", "filter.fixture.clean", "sed s/worktree-token/canonical-token/g" });
            try git.ok(&.{ "config", "filter.fixture.smudge", "sed s/canonical-token/worktree-token/g" });
            const attributes = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(".git/info/attributes"), git.arena, .limited(1024 * 1024));
            try write(git, ".git/info/attributes", try std.fmt.allocPrint(git.arena, "{s}\n*.prefab filter=fixture\n", .{attributes}));
        } else {
            try git.ok(&.{ "update-index", "--chmod=+x", "--", path });
            try git.ok(&.{ "commit", "-qm", "executable array" });
        }
        try git.ok(&.{ "checkout-index", "--force", "--all" });
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "canonical candidate and worktree encoding");
        const indexed = try git.output(&.{ "show", try std.fmt.allocPrint(git.arena, ":{s}", .{path}) });
        try t.require(std.mem.eql(u8, expected, indexed), "candidate canonical bytes changed by filters or line endings");
        const worktree_expected = if (filtered) try std.mem.replaceOwned(u8, git.arena, expected, "canonical-token", "worktree-token") else expected;
        try expectFile(git, path, worktree_expected);
        if (!filtered) try t.require(std.mem.startsWith(u8, try git.output(&.{ "ls-files", "--stage", "-z", "--", path }), "100755 "), "candidate lost executable mode");
        try git.ok(&.{ "merge", "--abort" });
        const worktree_ours = if (filtered) try std.mem.replaceOwned(u8, git.arena, sides[1], "canonical-token", "worktree-token") else sides[1];
        try expectFile(git, path, worktree_ours);
        if (!filtered) try t.require(std.mem.startsWith(u8, try git.output(&.{ "ls-files", "--stage", "-z", "--", path }), "100755 "), "abort lost executable index mode");
    }
}

fn cleanRenames(ctx: Context) !void {
    try independentAdditions(ctx);
    const plain_base = "--- !u!114 &1\nMonoBehaviour:\n  m_Items: [A, B]\n";
    const plain_edit = "--- !u!114 &1\nMonoBehaviour:\n  m_Items: [A, C]\n";
    for ([_]bool{ false, true }) |reverse| {
        const name = if (reverse) "clean-rename-incoming" else "clean-rename-ours";
        const git = try ctx.repo(name, &.{ .{ .path = "Assets/A.prefab", .base = plain_base, .ours = if (reverse) plain_edit else plain_base, .theirs = if (reverse) plain_base else plain_edit }, .{ .path = "Assets/History.prefab", .base = base, .ours = ours, .theirs = theirs } });
        if (reverse) try git.ok(&.{ "switch", "-q", "remote" });
        try git.ok(&.{ "mv", "Assets/A.prefab", "Assets/B.prefab" });
        try git.ok(&.{ "commit", "-qm", "rename array" });
        if (reverse) try git.ok(&.{ "switch", "-q", "local" });
        std.debug.print("native rename: {s}\n", .{name});
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "clean rename preserves opposite array edit");
        try expectFile(git, "Assets/B.prefab", plain_edit);
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":0:Assets/B.prefab" }), plain_edit), "renamed canonical array lost opposite edit");
        try t.require((try git.output(&.{ "ls-files", "--", "Assets/A.prefab" })).len == 0, "clean rename restored old path");
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "clean rename left stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, if (reverse) "Assets/A.prefab" else "Assets/B.prefab", if (reverse) plain_edit else plain_base);
    }
    // Disabling rename detection leaves the delete/edit relationship explicit.
    for ([_][]const u8{ "merge.renames", "diff.renames" }) |setting| {
        const git = try ctx.repo(setting, &.{ .{ .path = "Assets/A.prefab", .base = plain_base, .ours = plain_base, .theirs = plain_edit }, .{ .path = "Assets/History.prefab", .base = base, .ours = ours, .theirs = theirs } });
        try git.ok(&.{ "mv", "Assets/A.prefab", "Assets/B.prefab" });
        try git.ok(&.{ "commit", "-qm", "rename array" });
        try git.ok(&.{ "config", setting, "false" });
        std.debug.print("native rename setting: {s}=false\n", .{setting});
        const candidate = try git.run(&.{ "merge-tree", "--write-tree", "-z", "--messages", "HEAD", "remote" });
        const tree_end = std.mem.indexOfScalar(u8, candidate.stdout, 0) orelse return error.InvalidMergeOutput;
        const candidate_spec = try std.fmt.allocPrint(git.arena, "{s}:Assets/B.prefab", .{candidate.stdout[0..tree_end]});
        const accepted = try git.output(&.{ "show", candidate_spec });
        const old_candidate_path = try git.output(&.{ "ls-tree", "-z", candidate.stdout[0..tree_end], "--", "Assets/A.prefab" });
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "disabled or unproved rename stays explicit");
        try expectFile(git, "Assets/B.prefab", accepted);
        if (old_candidate_path.len == 0) {
            try t.require(std.mem.eql(u8, accepted, plain_edit), "Git rename candidate lost its accepted array edit");
            try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/B.prefab" })).len != 0, "unproved historical path silently completed");
            try t.expectNonzero(try git.run(&.{ "show", ":1:Assets/B.prefab" }), "unproved rename invented base stage");
        } else {
            try t.require(std.mem.eql(u8, accepted, plain_base), "disabled rename produced unexpected Git content");
            try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/A.prefab" })).len != 0, "disabled rename lost original structural stages");
            try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/B.prefab" })).len == 0, "disabled rename inferred a relationship for the addition");
        }
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, "Assets/B.prefab", plain_base);
    }
}

fn independentAdditions(ctx: Context) !void {
    const old = "--- !u!114 &1\nMonoBehaviour:\n  m_Items: [A, B]\n";
    const added = "--- !u!114 &987\nMonoBehaviour:\n  completelyDifferentCollection: [100, 200, 300, 400, 500, 600, 700, 800, 900]\n";
    for ([_]bool{ false, true }) |reverse| {
        const name = if (reverse) "independent-addition-incoming" else "independent-addition-ours";
        const git = try ctx.repo(name, &.{ .{ .path = "Assets/Old.prefab", .base = old, .ours = old, .theirs = old }, .{ .path = "Assets/History.prefab", .base = base, .ours = ours, .theirs = theirs } });
        if (reverse) try git.ok(&.{ "switch", "-q", "remote" });
        try git.ok(&.{ "rm", "Assets/Old.prefab" });
        try write(git, "Assets/New.prefab", added);
        try git.ok(&.{ "add", "Assets/New.prefab" });
        try git.ok(&.{ "commit", "-qm", "delete old asset and add independent collection" });
        const changed_side = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
        if (reverse) try git.ok(&.{ "switch", "-q", "local" });
        const ancestor = merge_git.trim(try git.output(&.{ "merge-base", "HEAD", "remote" }));
        const relationships = try git.output(&.{ "diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames", ancestor, changed_side });
        try t.require(std.mem.indexOf(u8, relationships, "A\x00Assets/New.prefab\x00") != null and std.mem.indexOf(u8, relationships, "D\x00Assets/Old.prefab\x00") != null, "independent addition fixture became a Git rename");
        std.debug.print("native independent addition: {s}\n", .{name});
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "unrelated deletion cannot block a collection addition");
        try expectFile(git, "Assets/New.prefab", added);
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":0:Assets/New.prefab" }), added), "independent canonical addition changed");
        try expectFile(git, "Assets/History.prefab", merged);
        try t.require((try git.output(&.{ "ls-files", "--", "Assets/Old.prefab" })).len == 0, "independent deletion was reverted");
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "independent addition retained stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, if (reverse) "Assets/Old.prefab" else "Assets/New.prefab", if (reverse) old else added);
        try expectFile(git, "Assets/History.prefab", ours);
    }
}
