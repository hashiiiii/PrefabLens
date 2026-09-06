const std = @import("std");
const builtin = @import("builtin");
const t = @import("git_merge_test_main.zig");
const pty = @import("pty_smoke_test_main.zig");
const merge_git = @import("merge_git.zig");

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
    var env = try init.environ_map.clone(a);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}{c}{s}", .{ std.fs.path.dirname(strategy_path).?, std.fs.path.delimiter, std.fs.path.dirname(prefablens).?, std.fs.path.delimiter, env.get("PATH") orelse "" }));
    const ctx: Context = .{ .git = .{ .io = init.io, .arena = a, .env = &env }, .scratch = scratch, .prefablens = prefablens, .fixture_root = args[3] };
    if (args.len == 5 and std.mem.eql(u8, args[4], "collections")) {
        try collectionSources(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "collection-conflict")) {
        try collectionSourceConflict(ctx);
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) try collectionSourceConflictPty(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "collection-source-choices")) {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) try collectionAuthoredSourceChoicesPty(ctx);
        return 0;
    }
    try setup(ctx);
    try automatic(ctx);
    try nonInteractive(ctx);
    try guards(ctx);
    try directoryConflict(ctx);
    try mergeOptions(ctx);
    try independentEdits(ctx);
    try collectionSources(ctx);
    try collectionSourceConflict(ctx);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try collectionSourceConflictPty(ctx);
        try collectionAuthoredSourceChoicesPty(ctx);
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

const CollectionInputs = struct {
    variant: [3][]const u8,
    source: [3][]const u8,
    variant_path: []const u8 = "Assets/Variant.prefab",
    source_path: []const u8 = "Assets/Source.prefab",
};

fn collectionRepository(ctx: Context, name: []const u8, inputs: CollectionInputs) !merge_git.Git {
    const arena = ctx.git.arena;
    const io = ctx.git.io;
    const assets = try std.fs.path.join(arena, &.{ ctx.fixture_root, "unity", "Assets" });
    var files: std.ArrayList(t.FileSides) = .empty;
    var directory = try std.Io.Dir.cwd().openDir(io, assets, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var path: []const u8 = try std.fmt.allocPrint(arena, "Assets/{s}", .{entry.path});
        const original = try directory.readFileAlloc(io, entry.path, arena, .limited(16 * 1024 * 1024));
        var sides: [3][]const u8 = .{ original, original, original };
        if (std.mem.eql(u8, entry.path, "Variant.prefab")) {
            path = inputs.variant_path;
            sides = inputs.variant;
        } else if (std.mem.eql(u8, entry.path, "Source.prefab")) {
            path = inputs.source_path;
            sides = inputs.source;
        } else if (std.mem.eql(u8, entry.path, "Variant.prefab.meta")) {
            path = try std.fmt.allocPrint(arena, "{s}.meta", .{inputs.variant_path});
        } else if (std.mem.eql(u8, entry.path, "Source.prefab.meta")) {
            path = try std.fmt.allocPrint(arena, "{s}.meta", .{inputs.source_path});
        }
        try files.append(arena, .{ .path = path, .base = sides[0], .ours = sides[1], .theirs = sides[2] });
        const target = try std.fs.path.join(arena, &.{ ctx.scratch, name, path });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(target).?);
    }
    return ctx.repo(name, files.items);
}

fn collectionSources(ctx: Context) !void {
    const arena = ctx.git.arena;
    for ([_][]const u8{ "variant-source-and-override", "variant-source-only-remove-and-edit" }) |name| {
        const case_root = try std.fs.path.join(arena, &.{ ctx.fixture_root, "cases", name });
        var inputs: CollectionInputs = undefined;
        inputs.variant_path = "Assets/Variant.prefab";
        inputs.source_path = "Assets/Source.prefab";
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |side_name, index| {
            inputs.variant[index] = try readCollectionFile(ctx, case_root, try std.fmt.allocPrint(arena, "{s}.prefab", .{side_name}));
            inputs.source[index] = try readCollectionFile(ctx, case_root, try std.fmt.allocPrint(arena, "{s}-source.prefab", .{side_name}));
        }
        const git = try collectionRepository(ctx, name, inputs);
        // Both fixtures contain paths that Git can accept without a file-driver call.
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "source-dependent collection merge");
        try expectFile(git, "Assets/Variant.prefab", try readCollectionFile(ctx, case_root, "expected.prefab"));
        try expectFile(git, "Assets/Source.prefab", try readCollectionFile(ctx, case_root, "output-source.prefab"));
        try expectFile(git, "Assets/Plain.prefab", try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/Plain.prefab"));
        try t.require((try git.output(&.{ "ls-files", "--unmerged", "-z" })).len == 0, "automatic collection merge retained conflict stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, "Assets/Variant.prefab", inputs.variant[1]);
        try expectFile(git, "Assets/Source.prefab", inputs.source[1]);
    }
}

fn sourceConflictInputs(ctx: Context) !CollectionInputs {
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-only-remove-and-edit" });
    const variant = try readCollectionFile(ctx, root, "base.prefab");
    const source = try readCollectionFile(ctx, root, "base-source.prefab");
    const item = "- name: A\n    power: 1\n    speed: 1\n";
    try t.require(std.mem.count(u8, source, item) == 1, "source conflict fixture lost its unique item span");
    return .{
        .variant = .{ variant, variant, variant },
        .source = .{
            source,
            try std.mem.replaceOwned(u8, ctx.git.arena, source, item, "- name: A\n    power: 1\n    speed: 10\n"),
            try std.mem.replaceOwned(u8, ctx.git.arena, source, item, "- name: A\n    power: 1\n    speed: 20\n"),
        },
        // The dependent sorts first by path. A source scheduler must reverse that order.
        .variant_path = "Assets/AVariant.prefab",
        .source_path = "Assets/ZSource.prefab",
    };
}

fn collectionSourceConflict(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "collection-source-conflict", inputs);
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "unresolved collection source");
    try markers(git, inputs.source_path);
    const stages = try git.output(&.{ "ls-files", "--unmerged", "-z", "--", inputs.variant_path });
    try t.require(std.mem.count(u8, stages, "\x00") == 3, "an unchanged dependent lost its semantic conflict stages");
    for ([_][]const u8{ ":1:", ":2:", ":3:" }, inputs.variant) |prefix, expected| {
        const entry = try std.fmt.allocPrint(git.arena, "{s}{s}", .{ prefix, inputs.variant_path });
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", entry }), expected), "dependent stages differ from historical bytes");
    }
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try expectFile(git, inputs.source_path, inputs.source[1]);
}

fn collectionSourceConflictPty(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "collection-source-order-pty", inputs);
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "resolve source before unchanged dependent");
    try t.require(pty.terminalCaptureContains(result.stdout, inputs.source_path), "source decision was not visible");
    try t.require(!pty.terminalCaptureContains(result.stdout, inputs.variant_path), "pure inheritance opened a second decision");
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try expectFile(git, inputs.source_path, inputs.source[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "-z" })).len == 0, "resolved source left a dependent unresolved");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try expectFile(git, inputs.source_path, inputs.source[1]);
}

fn authoredSourceConflictInputs(ctx: Context) !CollectionInputs {
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-and-override" });
    const source = try readCollectionFile(ctx, root, "base-source.prefab");
    const item = "  - name: A\n    power: 1\n    speed: 1\n";
    try t.require(std.mem.count(u8, source, item) == 1, "authored source fixture lost its unique A item");
    return .{
        .variant = .{
            try readCollectionFile(ctx, root, "base.prefab"),
            try readCollectionFile(ctx, root, "ours.prefab"),
            try readCollectionFile(ctx, root, "theirs.prefab"),
        },
        .source = .{
            source,
            try std.mem.replaceOwned(u8, ctx.git.arena, source, item, "  - name: A\n    power: 1\n    speed: 10\n"),
            try readCollectionFile(ctx, root, "theirs-source.prefab"),
        },
        // The dependent sorts first by path. A source scheduler must reverse that order.
        .variant_path = "Assets/AVariant.prefab",
        .source_path = "Assets/ZSource.prefab",
    };
}

fn collectionAuthoredSourceChoicesPty(ctx: Context) !void {
    const inputs = try authoredSourceConflictInputs(ctx);
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-and-override" });
    const expected_keep_a = try readCollectionFile(ctx, root, "ours.prefab");
    const expected_remove_a = try readCollectionFile(ctx, root, "expected.prefab");
    try t.require(!std.mem.eql(u8, expected_keep_a, expected_remove_a), "source choices must author different Variant bytes");

    const cases = [_]struct {
        name: []const u8,
        source_keys: []const u8,
        variant_keys: []const u8,
        expected_source: []const u8,
        expected_variant: []const u8,
        expected_path: []const u8,
        unexpected_path: []const u8,
    }{
        .{
            .name = "collection-source-keep-a-pty",
            .source_keys = "\x1b[C\r\r",
            .variant_keys = "",
            .expected_source = inputs.source[1],
            .expected_variant = expected_keep_a,
            .expected_path = "items.Array.data[1].speed",
            .unexpected_path = "items.Array.data[0].speed",
        },
        .{
            .name = "collection-source-remove-a-pty",
            .source_keys = "\x1b[C\x1b[C\r\r",
            // If the contextual core exposes a second choice, select Source.
            .variant_keys = "\x1b[C\x1b[C\r\r",
            .expected_source = inputs.source[2],
            .expected_variant = expected_remove_a,
            .expected_path = "items.Array.data[0].speed",
            .unexpected_path = "items.Array.data[1].speed",
        },
    };
    for (cases) |case| {
        const git = try collectionRepository(ctx, case.name, inputs);
        const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
        const result = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, case.source_keys, case.variant_keys, 30);
        try t.expectCode(result, 0, "resolve a source before its authored Variant");
        try t.require(pty.terminalCaptureContains(result.stdout, inputs.source_path), "source decision was not visible");
        try t.require(std.mem.count(u8, case.expected_variant, case.expected_path) == 1, "expected Variant lost the selected-source index");
        try t.require(std.mem.count(u8, case.expected_variant, case.unexpected_path) == 0, "expected Variant retained the other source choice's index");
        try expectFile(git, inputs.variant_path, case.expected_variant);
        try expectFile(git, inputs.source_path, case.expected_source);
        try t.require((try git.output(&.{ "ls-files", "--unmerged", "-z" })).len == 0, "source choice left authored Variant stages unresolved");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, inputs.variant_path, inputs.variant[1]);
        try expectFile(git, inputs.source_path, inputs.source[1]);
    }
}

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
fn setup(ctx: Context) !void {
    for ([_]bool{ false, true }) |team| {
        const git = try ctx.repo(if (team) "setup-team" else "setup-local", &.{.{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = theirs }});
        const path = if (team) ".gitattributes" else ".git/info/attributes";
        try write(git, path, "# Existing project rule.\n*.txt text\n");
        try git.ok(&.{ "config", "prefablens.test.setting", "keep" });
        for (0..2) |_| {
            const result = try std.process.run(git.arena, git.io, .{
                .argv = if (team) &.{ ctx.prefablens, "setup-merge", "--team" } else &.{ ctx.prefablens, "setup-merge" },
                .cwd = .{ .path = git.cwd },
                .environ_map = git.env,
            });
            try t.expectCode(result, 0, "repository merge setup");
        }
        const attributes = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(path), git.arena, .limited(1024 * 1024));
        try t.require(std.mem.startsWith(u8, attributes, "# Existing project rule.\n*.txt text\n"), "setup removed existing attributes");
        try t.require(std.mem.count(u8, attributes, "*.prefab merge=prefablens") == 1, "repeated setup duplicated attributes");
        try t.require(std.mem.eql(u8, merge_git.trim(try git.output(&.{ "config", "prefablens.test.setting" })), "keep"), "setup changed unrelated config");
        if (team) {
            try git.ok(&.{ "add", ".gitattributes" });
            try git.ok(&.{ "commit", "-qm", "Share merge attributes" });
        }
        try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 0, "merge after automatic setup");
        try expectFile(git, "Assets/A.prefab", merged);
    }
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
    const Change = enum { index, later_file, later_mode };
    for ([_]Change{ .index, .later_file, .later_mode }) |change| {
        const later_file = change != .index;
        const files = [_]t.FileSides{
            .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
            .{ .path = "Assets/B.prefab", .base = base, .ours = ours, .theirs = conflict_theirs },
        };
        const git = try ctx.repo(switch (change) {
            .index => "concurrent-index",
            .later_file => "later-file-edit",
            .later_mode => "later-mode-edit",
        }, files[0..if (later_file) @as(usize, 2) else 1]);
        try write(git, ".git/manual-choice", manual);
        const oid = merge_git.trim(try git.output(&.{ "hash-object", "-w", "--no-filters", ".git/manual-choice" }));
        const edit = switch (change) {
            .later_file => "cp .git/manual-choice Assets/B.prefab",
            .later_mode => "chmod 0755 Assets/B.prefab",
            .index => try std.fmt.allocPrint(git.arena, "git update-index --cacheinfo 100644,{s},Assets/A.prefab", .{oid}),
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
            try t.require(std.mem.eql(u8, manual, try git.output(&.{ "show", ":Assets/A.prefab" })), "Complete overwrote a concurrent index decision");
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
    // The second file has private permissions before its UI begins. A content choice must keep them.
    const inner = "(sleep 1.5; chmod 0600 Assets/B.prefab) & exec git merge --no-edit remote";
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} sh -c {s}", .{ try t.shellQuote(git.arena, git.env.get("PATH").?), try t.shellQuote(git.arena, inner) });
    const result = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, "\x1b[C\r\r", "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "retain private permissions during content resolution");
    try expectFile(git, "Assets/B.prefab", ours);
    const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path("Assets/B.prefab"), .{});
    try t.require(stat.permissions.toMode() & 0o777 == 0o600, "content resolution changed private permissions");
}
