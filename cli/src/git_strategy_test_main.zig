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
    if (args.len == 5 and std.mem.eql(u8, args[4], "required-promotion")) {
        if (supports_pty) try requiredPromotion(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "candidate-safety")) {
        try addedUnity(ctx);
        try unresolvedSchema(ctx);
        try replacedGuid(ctx);
        try zeroStageSource(ctx);
        try uncertainMetadata(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "native-fixtures")) {
        try nativeFixtures(ctx);
        if (supports_pty) try nativeLocalChoices(ctx);
        try candidateEncoding(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "dependency-seams")) {
        if (supports_pty) {
            try transitiveSource(ctx);
            try structuralSource(ctx);
        }
        try replacedGuid(ctx);
        try addedUnity(ctx);
        try unresolvedSchema(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "candidate-boundaries")) {
        try collectionSourceConflict(ctx);
        if (supports_pty) try unknownAncestry(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "collections")) {
        try collectionSources(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "collection-conflict")) {
        try collectionSourceConflict(ctx);
        if (supports_pty) try collectionSourceConflictPty(ctx);
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[4], "collection-source-choices")) {
        if (supports_pty) try collectionAuthoredSourceChoicesPty(ctx);
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
    try cleanRenames(ctx);
    try collectionSourceConflict(ctx);
    try nativeFixtures(ctx);
    try candidateEncoding(ctx);
    try replacedGuid(ctx);
    try addedUnity(ctx);
    try unresolvedSchema(ctx);
    try zeroStageSource(ctx);
    try uncertainMetadata(ctx);
    if (supports_pty) {
        try collectionSourceConflictPty(ctx);
        try collectionAuthoredSourceChoicesPty(ctx);
        try transitiveSource(ctx);
        try structuralSource(ctx);
        try unknownAncestry(ctx);
        try nativeLocalChoices(ctx);
        try requiredPromotion(ctx);
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
    variant_asset: []const u8 = "Variant.prefab",
    history_only: bool = false,
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
        if (std.mem.eql(u8, entry.path, inputs.variant_asset)) {
            path = inputs.variant_path;
            sides = inputs.variant;
        } else if (std.mem.eql(u8, entry.path, "Source.prefab")) {
            path = inputs.source_path;
            sides = inputs.source;
        } else if (std.mem.eql(u8, entry.path, try std.fmt.allocPrint(arena, "{s}.meta", .{inputs.variant_asset}))) {
            path = try std.fmt.allocPrint(arena, "{s}.meta", .{inputs.variant_path});
        } else if (std.mem.eql(u8, entry.path, "Source.prefab.meta")) {
            path = try std.fmt.allocPrint(arena, "{s}.meta", .{inputs.source_path});
        }
        try files.append(arena, .{ .path = path, .base = sides[0], .ours = sides[1], .theirs = sides[2] });
        const target = try std.fs.path.join(arena, &.{ ctx.scratch, name, path });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(target).?);
    }
    if (inputs.history_only) try files.append(arena, .{ .path = "Assets/History.prefab", .base = base, .ours = ours, .theirs = theirs });
    return ctx.repo(name, files.items);
}

fn collectionSources(ctx: Context) !void {
    const arena = ctx.git.arena;
    for ([_][]const u8{ "variant-source-and-override", "variant-source-only-remove-and-edit" }) |name| {
        const case_root = try std.fs.path.join(arena, &.{ ctx.fixture_root, "cases", name });
        var inputs: CollectionInputs = .{ .variant = undefined, .source = undefined };
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
    try markers(git, inputs.variant_path);
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
    // The second file has private permissions before its UI begins. A content choice must keep them.
    const inner = "(sleep 1.5; chmod 0600 Assets/B.prefab) & exec git merge --no-edit remote";
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} sh -c {s}", .{ try t.shellQuote(git.arena, git.env.get("PATH").?), try t.shellQuote(git.arena, inner) });
    const result = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, "\x1b[C\r\r", "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "retain private permissions during content resolution");
    try expectFile(git, "Assets/B.prefab", ours);
    const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path("Assets/B.prefab"), .{});
    try t.require(stat.permissions.toMode() & 0o777 == 0o600, "content resolution changed private permissions");
}

fn graphCommit(git: merge_git.Git, tree: []const u8, parents: []const []const u8, message: []const u8) ![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "commit-tree", tree, "-m", message });
    for (parents) |parent| try args.appendSlice(git.arena, &.{ "-p", parent });
    return merge_git.trim(try git.output(args.items));
}

fn unknownAncestry(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "unknown-ancestry", inputs);
    const local = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    const original_remote = merge_git.trim(try git.output(&.{ "rev-parse", "remote" }));
    const local_tree = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD^{tree}" }));
    const remote_tree = merge_git.trim(try git.output(&.{ "rev-parse", "remote^{tree}" }));
    try git.ok(&.{ "checkout", "-q", "--detach", original_remote });
    try write(git, inputs.variant_path, try std.fmt.allocPrint(git.arena, "{s}# distinct ancestor\n", .{inputs.variant[0]}));
    try git.ok(&.{ "commit", "-qam", "different ancestral Variant" });
    const remote = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    const left = try graphCommit(git, local_tree, &.{ local, remote }, "left crisscross");
    const right = try graphCommit(git, remote_tree, &.{ remote, local }, "right crisscross");
    try git.ok(&.{ "reset", "--hard", left });
    try git.ok(&.{ "update-ref", "refs/heads/remote", right });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "multiple bases retain semantic choices");
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", inputs.variant_path })).len != 0, "multiple-base dependent must stay unmerged");
    try t.expectNonzero(try git.run(&.{ "show", ":1:Assets/AVariant.prefab" }), "different ancestral Variant blobs cannot invent stage one");
    try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":2:Assets/ZSource.prefab" }), inputs.source[1]), "unknown base changed ours stage");
    try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":3:Assets/ZSource.prefab" }), inputs.source[2]), "unknown base changed theirs stage");
    try t.expectNonzero(try git.run(&.{ "commit", "-m", "must remain unresolved" }), "unknown context prevents commit");
    try git.ok(&.{ "merge", "--abort" });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, "a\r", "a\r", 30);
    try t.expectCode(result, 0, "explicit sides with unknown ancestry");
    try t.require(pty.terminalCaptureContains(result.stdout, "Unknown base/context"), "unknown ancestry was mislabeled as a normal merge");
    try expectFile(git, inputs.source_path, inputs.source[1]);
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "explicit unknown choices left stages");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, inputs.source_path, inputs.source[1]);
    // Resuming through Git must discover unknown ancestry without strategy env.
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "resume unknown context");
    const custom = try std.mem.replaceOwned(u8, git.arena, inputs.source[1], "speed: 10", "speed: 77");
    try write(git, ".git/custom-source", custom);
    try git.ok(&.{ "config", "core.editor", "cp .git/custom-source" });
    const configured_tool = try std.fmt.allocPrint(git.arena, "{s} mergetool \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\"", .{try t.shellQuote(git.arena, ctx.prefablens)});
    try git.ok(&.{ "config", "mergetool.prefablens.cmd", configured_tool });
    try git.ok(&.{ "config", "mergetool.prefablens.trustExitCode", "true" });
    const tool_command = try std.fmt.allocPrint(git.arena, "env PATH={s} git mergetool --tool=prefablens --no-prompt -- Assets/ZSource.prefab Assets/AVariant.prefab", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const resumed = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, tool_command, "a\r", "e\r", 30);
    try t.expectCode(resumed, 0, "resumed unknown whole-file custom choice");
    try t.require(pty.terminalCaptureContains(resumed.stdout, "Unknown base/context"), "resumed tool guessed ancestry");
    try expectFile(git, inputs.source_path, custom);
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "resumed unknown choices retained stages");
    try git.ok(&.{ "merge", "--abort" });
}

fn nativeFixtures(ctx: Context) !void {
    const Case = struct { name: []const u8, conflict: bool, choice: ?[]const u8 = null, sourceContext: bool = false };
    const Manifest = struct { cases: []const Case };
    const parsed = try std.json.parseFromSlice(Manifest, ctx.git.arena, try readCollectionFile(ctx, ctx.fixture_root, "expected-runtime.json"), .{ .ignore_unknown_fields = true });
    const fixed_source = try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/Source.prefab");
    for (parsed.value.cases) |case| {
        const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", case.name });
        const asset = if (std.mem.startsWith(u8, case.name, "replay-")) "ReplayVariant.prefab" else if (std.mem.startsWith(u8, case.name, "variant-dictionary-")) "DictionaryVariant.prefab" else if (std.mem.startsWith(u8, case.name, "variant-")) "Variant.prefab" else "Plain.prefab";
        var inputs: CollectionInputs = .{ .variant = undefined, .source = .{ fixed_source, fixed_source, fixed_source }, .variant_asset = asset, .variant_path = try std.fmt.allocPrint(ctx.git.arena, "Assets/{s}", .{asset}) };
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |side_name, i| {
            inputs.variant[i] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}.prefab", .{side_name}));
            if (case.sourceContext) inputs.source[i] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}-source.prefab", .{side_name}));
        }
        const git = try collectionRepository(ctx, try std.fmt.allocPrint(ctx.git.arena, "native-{s}", .{case.name}), inputs);
        std.debug.print("native fixture: {s}\n", .{case.name});
        if (case.conflict) {
            try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "native fixture retains local choice");
            try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", inputs.variant_path })).len != 0, "native fixture lost local stages");
            try git.ok(&.{ "merge", "--abort" });
            try expectFile(git, inputs.variant_path, inputs.variant[1]);
            try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "native fixture abort retained stages");
            // All platforms check the unresolved transaction. Only POSIX hosts
            // can make the real terminal choice and check its resolved output.
            if (!supports_pty) continue;
            const keys: []const u8 = if (std.mem.eql(u8, case.choice.?, "ours_first")) "\x1b[CT\r\r" else "\x1b[C\x1b[C\r\r";
            const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
            try t.expectCode(try pty.runCommandInPty(git.io, git.arena, git.cwd, command, keys, 30), 0, "native fixture local choice");
        } else try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "native automatic fixture");
        try expectFile(git, inputs.variant_path, try readCollectionFile(ctx, root, "expected.prefab"));
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "native exact fixture retained stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, inputs.variant_path, inputs.variant[1]);
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

fn transitiveSource(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "transitive-source", inputs);
    const source_meta = try git.output(&.{ "show", "HEAD:Assets/ZSource.prefab.meta" });
    const variant_meta = try git.output(&.{ "show", "HEAD:Assets/AVariant.prefab.meta" });
    const source_guid = try fixtureGuid(source_meta);
    const variant_guid = try fixtureGuid(variant_meta);
    const outer = try std.mem.replaceOwned(u8, git.arena, inputs.variant[0], source_guid, variant_guid);
    const local = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    const remote = merge_git.trim(try git.output(&.{ "rev-parse", "remote" }));
    const ancestor = merge_git.trim(try git.output(&.{ "merge-base", local, remote }));
    try git.ok(&.{ "checkout", "-q", "--detach", ancestor });
    try write(git, "Assets/00Outer.prefab", outer);
    try write(git, "Assets/00Outer.prefab.meta", "guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "outer source" });
    const new_base = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try write(git, inputs.source_path, inputs.source[1]);
    try git.ok(&.{ "commit", "-qam", "ours" });
    const new_local = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try git.ok(&.{ "checkout", "-q", "--detach", new_base });
    try write(git, inputs.source_path, inputs.source[2]);
    try git.ok(&.{ "commit", "-qam", "theirs" });
    try git.ok(&.{ "update-ref", "refs/heads/remote", merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" })) });
    try git.ok(&.{ "checkout", "-q", "--detach", new_local });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "transitive pending source");
    try t.require(std.mem.count(u8, try git.output(&.{ "ls-files", "--unmerged", "-z", "--", "Assets/00Outer.prefab" }), "\x00") == 3, "transitive unchanged Variant lacks stages");
    try git.ok(&.{ "merge", "--abort" });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "transitive source ordering");
    try t.require(!pty.terminalCaptureContains(result.stdout, "Assets/00Outer.prefab"), "pure outer inheritance repeated inner decisions");
    try expectFile(git, "Assets/00Outer.prefab", outer);
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "transitive source choice left stages");
    try git.ok(&.{ "merge", "--abort" });
}

fn structuralSource(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "structural-source", inputs);
    const renamed = "Assets/RenamedSource.prefab";
    const renamed_meta = "Assets/RenamedSource.prefab.meta";
    try git.ok(&.{ "mv", inputs.source_path, renamed });
    try git.ok(&.{ "mv", "Assets/ZSource.prefab.meta", renamed_meta });
    try git.ok(&.{ "commit", "-qm", "rename source and metadata" });
    try git.ok(&.{ "switch", "-q", "remote" });
    try git.ok(&.{ "rm", inputs.source_path, "Assets/ZSource.prefab.meta" });
    try git.ok(&.{ "commit", "-qm", "delete source and metadata" });
    try git.ok(&.{ "switch", "-q", "local" });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "k\r", 30);
    try t.expectCode(result, 0, "structural source before dependent");
    try t.require(pty.terminalCaptureContains(result.stdout, "matching .meta"), "source path decision omitted paired metadata");
    try expectFile(git, renamed, inputs.source[1]);
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "structural source left dependent stages");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, renamed, inputs.source[1]);
}

fn fixtureGuid(bytes: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, bytes, "guid: ") orelse return error.MissingFixtureGuid) + 6;
    return bytes[start .. start + 32];
}

fn replacedGuid(ctx: Context) !void {
    const original = try sourceConflictInputs(ctx);
    const source = original.source[0];
    const inputs: CollectionInputs = .{ .variant = original.variant, .source = .{ source, source, source }, .history_only = true };
    const git = try collectionRepository(ctx, "replaced-guid", inputs);
    try git.ok(&.{ "switch", "-q", "remote" });
    const meta = try git.output(&.{ "show", "HEAD:Assets/Source.prefab.meta" });
    const changed = try std.mem.replaceOwned(u8, git.arena, meta, try fixtureGuid(meta), "abababababababababababababababab");
    try write(git, "Assets/Source.prefab.meta", changed);
    try git.ok(&.{ "commit", "-qam", "replace source GUID" });
    try git.ok(&.{ "switch", "-q", "local" });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "old source GUID remains a dependency");
    try t.require(std.mem.count(u8, try git.output(&.{ "ls-files", "--unmerged", "-z", "--", inputs.variant_path }), "\x00") == 3, "GUID replacement lost unchanged dependent stages");
    try expectFile(git, "Assets/Plain.prefab", try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/Plain.prefab"));
    try git.ok(&.{ "merge", "--abort" });
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

fn unresolvedSchema(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "unresolved-schema", .{ .variant = inputs.variant, .source = .{ inputs.source[0], inputs.source[0], inputs.source[0] }, .history_only = true });
    // A competing declaration can change name resolution despite having no own
    // script GUID. Both the typed source and its unchanged Variant need review.
    const ancestor = merge_git.trim(try git.output(&.{ "merge-base", "HEAD", "remote" }));
    try git.ok(&.{ "checkout", "-q", "--detach", ancestor });
    try write(git, "Assets/Shadow.cs", "class Shadow { int value = 1; }\n");
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "declaration" });
    const base_commit = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try write(git, "Assets/Shadow.cs", "class Shadow { int value = 2; }\n");
    try git.ok(&.{ "commit", "-qam", "ours declaration" });
    const local = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try git.ok(&.{ "checkout", "-q", "--detach", base_commit });
    try write(git, "Assets/Shadow.cs", "class Shadow { int value = 3; }\n");
    try git.ok(&.{ "commit", "-qam", "theirs declaration" });
    try git.ok(&.{ "update-ref", "refs/heads/remote", merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" })) });
    try git.ok(&.{ "checkout", "-q", "--detach", local });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "unresolved schema evidence");
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/Variant.prefab" })).len != 0, "unresolved declaration silently proved dependent type");
    try markers(git, "Assets/Shadow.cs");
    try git.ok(&.{ "merge", "--abort" });
}

fn zeroStageSource(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "zero-stage-source", inputs);
    const ancestor = merge_git.trim(try git.output(&.{ "merge-base", "HEAD", "remote" }));
    const meta = try git.output(&.{ "show", "HEAD:Assets/ZSource.prefab.meta" });
    try git.ok(&.{ "checkout", "-q", "--detach", ancestor });
    try git.ok(&.{ "rm", inputs.source_path, "Assets/ZSource.prefab.meta" });
    try write(git, "Notes/A.txt", "unchanged A\n");
    try write(git, "Notes/B.txt", "unchanged B\n");
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "directory base without source" });
    const base_commit = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try std.Io.Dir.cwd().createDirPath(git.io, try git.path("Left"));
    try std.Io.Dir.cwd().createDirPath(git.io, try git.path("Right"));
    try git.ok(&.{ "mv", "Notes/A.txt", "Left/A.txt" });
    try git.ok(&.{ "mv", "Notes/B.txt", "Right/B.txt" });
    try git.ok(&.{ "commit", "-qm", "split directory" });
    const local = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try git.ok(&.{ "checkout", "-q", "--detach", base_commit });
    try write(git, "Notes/Source.prefab", inputs.source[0]);
    try write(git, "Notes/Source.prefab.meta", meta);
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "add source under split directory" });
    const remote = merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
    try git.ok(&.{ "update-ref", "refs/heads/remote", remote });
    try git.ok(&.{ "checkout", "-q", "--detach", local });
    try git.ok(&.{ "config", "merge.directoryRenames", "conflict" });
    const parsed = try git.run(&.{ "merge-tree", "--write-tree", "-z", "--messages", local, remote });
    try t.expectCode(parsed, 1, "real Git zero-stage structural conflict");
    const tree_end = std.mem.indexOfScalar(u8, parsed.stdout, 0) orelse return error.InvalidMergeOutput;
    try t.require(parsed.stdout[tree_end + 1] == 0, "zero-stage fixture unexpectedly has Git stages");
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "zero-stage source remains unresolved");
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Notes/Source.prefab" })).len == 0, "unsupported structure invented source stages");
    try t.require(std.mem.count(u8, try git.output(&.{ "ls-files", "--unmerged", "-z", "--", inputs.variant_path }), "\x00") == 3, "zero-stage structural source was used as selected evidence");
    try expectFile(git, "Assets/Plain.prefab", try readCollectionFile(ctx, ctx.fixture_root, "unity/Assets/Plain.prefab"));
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
}

fn uncertainMetadata(ctx: Context) !void {
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "uncertain-metadata", .{ .variant = inputs.variant, .source = .{ inputs.source[0], inputs.source[0], inputs.source[0] }, .history_only = true });
    try git.ok(&.{ "switch", "-q", "remote" });
    try write(git, "Assets/Unknown.meta", "guid: not-a-proven-identity\n");
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "unknown metadata identity" });
    try git.ok(&.{ "switch", "-q", "local" });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "unknown metadata suspends selected identity proof");
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", "Assets/Variant.prefab" })).len != 0, "unknown metadata hid a possible duplicate source GUID");
    try git.ok(&.{ "merge", "--abort" });
}

fn requiredPromotion(ctx: Context) !void {
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-and-override" });
    const original_source = try readCollectionFile(ctx, root, "base-source.prefab");
    const item_b = "  - name: B\n    power: 1\n    speed: 1\n";
    const item_c = "  - name: C\n    power: 1\n    speed: 1\n";
    const source = try std.mem.replaceOwned(u8, ctx.git.arena, try std.mem.replaceOwned(u8, ctx.git.arena, original_source, item_c, ""), item_b, "  - name: B\n    power: 1\n    speed: 2\n");
    const short_source = try std.mem.replaceOwned(u8, ctx.git.arena, source, "  - name: B\n    power: 1\n    speed: 2\n", "");
    const changed_source = try std.mem.replaceOwned(u8, ctx.git.arena, source, "  - name: B\n    power: 1\n    speed: 2\n", "  - name: C\n    power: 1\n    speed: 3\n");
    const authored = try std.mem.replaceOwned(u8, ctx.git.arena, try readCollectionFile(ctx, root, "ours.prefab"), "items.Array.data[1].speed", "items.Array.data[0].speed");
    const size = "    - target: {fileID: 6274539545266883574, guid: 0464d347790434a4898eef837430e91e, type: 3}\n      propertyPath: items.Array.size\n      value: 2\n      objectReference: {fileID: 0}\n";
    const sized = try std.mem.replaceOwned(u8, ctx.git.arena, authored, "    m_RemovedComponents:", size ++ "    m_RemovedComponents:");
    // The short branch resets a real size override. The user's local custom
    // deletion then freezes length one against a selected source of length two.
    const inputs: CollectionInputs = .{ .variant = .{ sized, authored, sized }, .source = .{ source, short_source, changed_source }, .variant_path = "Assets/AVariant.prefab", .source_path = "Assets/ZSource.prefab" };
    const git = try collectionRepository(ctx, "required-promotion", inputs);
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "required promotion cannot auto-complete");
    try t.require((try git.output(&.{ "ls-files", "--unmerged", "--", inputs.variant_path })).len != 0, "promotion lost semantic stages");
    try git.ok(&.{ "merge", "--abort" });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const result = try pty.runCommandInPtyThreeBatches(git.io, git.arena, git.cwd, command, "\x1b[<0;83;5M[{name: B, power: 1, speed: 2}]\r\r", "\x1b[<0;83;5M[]\r", "\x1b[C\r\r", 30);
    try t.expectCode(result, 0, "explicit required promotion decision");
    try t.require(pty.terminalCaptureContains(result.stdout, "items.length: inherited 2 -> override 1"), "required size promotion omitted exact effect");
    const output = try git.output(&.{ "show", ":Assets/AVariant.prefab" });
    try t.require(std.mem.count(u8, output, "propertyPath: items.Array.size\n      value: 1\n") == 1, "explicit size choice lost length one");
    try t.require(std.mem.count(u8, output, "propertyPath: items.Array.data[0].speed\n      value: 99\n") == 1, "promotion lost the independent authored speed99");
    try expectFile(git, inputs.source_path, source);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "reviewed promotion left stages");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, inputs.variant_path, inputs.variant[1]);
}

fn candidateEncoding(ctx: Context) !void {
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-and-override" });
    const crlf_path = if (builtin.os.tag == .windows) "Assets/CRLF.prefab" else "Assets/a\tb\nc.prefab";
    for ([_]bool{ false, true }) |filtered| {
        var inputs: CollectionInputs = .{ .variant = undefined, .source = undefined, .variant_path = if (filtered) "Assets/Filtered.prefab" else crlf_path };
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |name, i| {
            const bytes = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}.prefab", .{name}));
            inputs.variant[i] = if (filtered) try std.fmt.allocPrint(ctx.git.arena, "{s}# canonical-token\n", .{bytes}) else try std.mem.replaceOwned(u8, ctx.git.arena, bytes, "\n", "\r\n");
            inputs.source[i] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}-source.prefab", .{name}));
        }
        const git = try collectionRepository(ctx, if (filtered) "candidate-filter" else "candidate-crlf-path-mode", inputs);
        const bytes = try readCollectionFile(ctx, root, "expected.prefab");
        const expected = if (filtered) try std.fmt.allocPrint(git.arena, "{s}# canonical-token\n", .{bytes}) else try std.mem.replaceOwned(u8, git.arena, bytes, "\n", "\r\n");
        if (filtered) {
            try git.ok(&.{ "config", "filter.fixture.clean", "sed s/worktree-token/canonical-token/g" });
            try git.ok(&.{ "config", "filter.fixture.smudge", "sed s/canonical-token/worktree-token/g" });
        } else {
            try git.ok(&.{ "update-index", "--chmod=+x", "--", inputs.variant_path });
            try git.ok(&.{ "commit", "-qm", "executable Variant" });
        }
        if (filtered) {
            const attributes = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(".git/info/attributes"), git.arena, .limited(1024 * 1024));
            try write(git, ".git/info/attributes", try std.fmt.allocPrint(git.arena, "{s}\n*.prefab filter=fixture\n", .{attributes}));
        }
        try git.ok(&.{ "checkout-index", "--force", "--all" });
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "canonical candidate and worktree encoding");
        const indexed = try git.output(&.{ "show", try std.fmt.allocPrint(git.arena, ":{s}", .{inputs.variant_path}) });
        try t.require(std.mem.eql(u8, expected, indexed), "candidate canonical bytes changed by filters or line endings");
        try expectFile(git, inputs.variant_path, if (filtered) try std.mem.replaceOwned(u8, git.arena, expected, "canonical-token", "worktree-token") else expected);
        if (!filtered) try t.require(std.mem.startsWith(u8, try git.output(&.{ "ls-files", "--stage", "-z", "--", inputs.variant_path }), "100755 "), "candidate lost executable mode");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, inputs.variant_path, if (filtered) try std.mem.replaceOwned(u8, git.arena, inputs.variant[1], "canonical-token", "worktree-token") else inputs.variant[1]);
        if (!filtered) try t.require(std.mem.startsWith(u8, try git.output(&.{ "ls-files", "--stage", "-z", "--", inputs.variant_path }), "100755 "), "abort lost executable index mode");
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
        try git.ok(&.{ "commit", "-qm", "rename collection" });
        if (reverse) try git.ok(&.{ "switch", "-q", "local" });
        std.debug.print("native rename: {s}\n", .{name});
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "clean rename preserves opposite collection edit");
        try expectFile(git, "Assets/B.prefab", plain_edit);
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":0:Assets/B.prefab" }), plain_edit), "renamed canonical collection lost opposite edit");
        try t.require((try git.output(&.{ "ls-files", "--", "Assets/A.prefab" })).len == 0, "clean rename restored old path");
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "clean rename left stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, if (reverse) "Assets/A.prefab" else "Assets/B.prefab", if (reverse) plain_edit else plain_base);
    }
    // Disabling rename detection makes B an addition and leaves A's delete/edit
    // relationship unresolved. A candidate-side diff must not re-enable renames.
    for ([_][]const u8{ "merge.renames", "diff.renames" }) |setting| {
        const git = try ctx.repo(setting, &.{ .{ .path = "Assets/A.prefab", .base = plain_base, .ours = plain_base, .theirs = plain_edit }, .{ .path = "Assets/History.prefab", .base = base, .ours = ours, .theirs = theirs } });
        try git.ok(&.{ "mv", "Assets/A.prefab", "Assets/B.prefab" });
        try git.ok(&.{ "commit", "-qm", "rename collection" });
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
            try t.require(std.mem.eql(u8, accepted, plain_edit), "Git rename candidate lost its accepted collection edit");
            // Git 2.39 merge-tree can propagate the rename despite this config.
            // Preserve its accepted edit without claiming a historical mapping.
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
    const root = try std.fs.path.join(ctx.git.arena, &.{ ctx.fixture_root, "cases", "variant-source-and-override" });
    for ([_]bool{ false, true }) |reverse| {
        var inputs: CollectionInputs = .{ .variant = undefined, .source = undefined };
        for ([_][]const u8{ "base", "ours", "theirs" }, 0..) |side_name, i| {
            const target = if (reverse and i != 0) 3 - i else i;
            inputs.variant[target] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}.prefab", .{side_name}));
            inputs.source[target] = try readCollectionFile(ctx, root, try std.fmt.allocPrint(ctx.git.arena, "{s}-source.prefab", .{side_name}));
        }
        const name = if (reverse) "clean-variant-rename-incoming" else "clean-variant-rename-ours";
        const git = try collectionRepository(ctx, name, inputs);
        const meta = try git.output(&.{ "show", "HEAD:Assets/Variant.prefab.meta" });
        if (reverse) try git.ok(&.{ "switch", "-q", "remote" });
        try git.ok(&.{ "mv", "Assets/Variant.prefab", "Assets/Renamed.prefab" });
        try git.ok(&.{ "mv", "Assets/Variant.prefab.meta", "Assets/Renamed.prefab.meta" });
        try git.ok(&.{ "commit", "-qm", "rename authored Variant with metadata" });
        if (reverse) try git.ok(&.{ "switch", "-q", "local" });
        std.debug.print("native rename: {s}\n", .{name});
        try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 0, "renamed Variant uses exact source histories");
        const expected = try readCollectionFile(ctx, root, "expected.prefab");
        try expectFile(git, "Assets/Renamed.prefab", expected);
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", ":0:Assets/Renamed.prefab" }), expected), "renamed Variant canonical override target is wrong");
        try expectFile(git, "Assets/Source.prefab", try readCollectionFile(ctx, root, "output-source.prefab"));
        try expectFile(git, "Assets/Renamed.prefab.meta", meta);
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "renamed Variant retained stages");
        try t.require((try git.output(&.{ "ls-files", "--", "Assets/Variant.prefab", "Assets/Variant.prefab.meta" })).len == 0, "renamed Variant restored historical paths");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, if (reverse) "Assets/Variant.prefab" else "Assets/Renamed.prefab", inputs.variant[1]);
        try expectFile(git, "Assets/Source.prefab", inputs.source[1]);
    }
    const inputs = try sourceConflictInputs(ctx);
    const git = try collectionRepository(ctx, "renamed-pending-variant", inputs);
    try git.ok(&.{ "mv", inputs.variant_path, "Assets/Renamed.prefab" });
    try git.ok(&.{ "mv", "Assets/AVariant.prefab.meta", "Assets/Renamed.prefab.meta" });
    try git.ok(&.{ "commit", "-qm", "rename dependent before source conflict" });
    try t.expectCode(try git.run(&.{ "merge", "--no-commit", "remote" }), 1, "renamed dependent retains source decision");
    for ([_][]const u8{ "1", "2", "3" }, 0..) |number, i| {
        const spec = try std.fmt.allocPrint(git.arena, ":{s}:Assets/Renamed.prefab", .{number});
        try t.require(std.mem.eql(u8, try git.output(&.{ "show", spec }), inputs.variant[i]), "renamed synthetic stage lost original side bytes");
    }
    try git.ok(&.{ "merge", "--abort" });
    if (!supports_pty) return;
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    const selected = try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "\x1b[C\r\r", 30);
    try t.expectCode(selected, 0, "renamed dependent uses selected source");
    try expectFile(git, "Assets/Renamed.prefab", inputs.variant[1]);
    try expectFile(git, inputs.source_path, inputs.source[1]);
    try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len == 0, "renamed selected source left stages");
    try git.ok(&.{ "merge", "--abort" });
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
