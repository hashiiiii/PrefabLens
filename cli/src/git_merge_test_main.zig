const std = @import("std");

pub const AttributeMode = enum { local, tracked };
const RevisionSide = enum { base, ours, theirs };

pub const FileSides = struct {
    path: []const u8,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
};

const automatic_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Left: 1
    \\  m_Right: 1
++ "\n";
const automatic_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Left: 2
    \\  m_Right: 1
++ "\n";
const automatic_theirs =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Left: 1
    \\  m_Right: 3
++ "\n";
const automatic_expected =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Left: 2
    \\  m_Right: 3
++ "\n";

const conflict_base =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  - component: {fileID: 54}
    \\  m_Name: Root
    \\--- !u!4 &4
    \\Transform:
    \\  m_GameObject: {fileID: 1}
    \\  m_Children: []
    \\  m_Father: {fileID: 0}
    \\--- !u!54 &54
    \\Rigidbody:
    \\  m_GameObject: {fileID: 1}
    \\  m_Mass: 1
++ "\n";
const conflict_ours =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  m_Name: Root
    \\--- !u!4 &4
    \\Transform:
    \\  m_GameObject: {fileID: 1}
    \\  m_Children: []
    \\  m_Father: {fileID: 0}
++ "\n";
const conflict_theirs =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  - component: {fileID: 54}
    \\  m_Name: Root
    \\--- !u!4 &4
    \\Transform:
    \\  m_GameObject: {fileID: 1}
    \\  m_Children: []
    \\  m_Father: {fileID: 0}
    \\--- !u!54 &54
    \\Rigidbody:
    \\  m_GameObject: {fileID: 1}
    \\  m_Mass: 2
++ "\n";

const sequence_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Unknown:
    \\  - 1
    \\  - 2
++ "\n";
const sequence_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Unknown:
    \\  - 1
    \\  - 3
++ "\n";
const sequence_theirs =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Unknown:
    \\  - 1
    \\  - 4
++ "\n";

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    try require(args.len == 2, "expected the prefablens executable path");
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);

    const scratch = try scratchDirectory(io, arena, "git");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    inline for (.{ AttributeMode.local, AttributeMode.tracked }) |mode| {
        try testAutomaticMerge(io, arena, scratch, prefablens, mode);
        try testSemanticConflict(io, arena, scratch, prefablens, mode);
    }
    try testFailurePreservesOurs(io, arena, scratch, prefablens, "malformed", .{
        .path = "Assets/A.prefab",
        .base = automatic_base,
        .ours = "not Unity YAML\n",
        .theirs = automatic_theirs,
    });
    try testFailurePreservesOurs(io, arena, scratch, prefablens, "unknown-sequence", .{
        .path = "Assets/A.prefab",
        .base = sequence_base,
        .ours = sequence_ours,
        .theirs = sequence_theirs,
    });
    try testTextConflictUsesDefaultDriver(io, arena, scratch, prefablens);

    try std.Io.File.stdout().writeStreamingAll(io, "git merge integration: passed\n");
    return 0;
}

fn testAutomaticMerge(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    mode: AttributeMode,
) !void {
    const name = if (mode == .local) "automatic-local" else "automatic-tracked";
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]FileSides{.{
        .path = "Assets/A.prefab",
        .base = automatic_base,
        .ours = automatic_ours,
        .theirs = automatic_theirs,
    }};
    try prepareRepository(io, arena, repo, prefablens, mode, &files);
    try checkAttributes(io, arena, repo);

    const result = try gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try expectCode(result, 0, "automatic merge");
    const unmerged = try gitRun(io, arena, repo, &.{ "ls-files", "-u" });
    try expectCode(unmerged, 0, "list automatic merge index");
    try require(unmerged.stdout.len == 0, "automatic merge left unmerged index entries");
    try expectFile(io, arena, repo, "Assets/A.prefab", automatic_expected);
}

fn testSemanticConflict(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    mode: AttributeMode,
) !void {
    const name = if (mode == .local) "conflict-local" else "conflict-tracked";
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]FileSides{.{
        .path = "Assets/A.prefab",
        .base = conflict_base,
        .ours = conflict_ours,
        .theirs = conflict_theirs,
    }};
    try prepareRepository(io, arena, repo, prefablens, mode, &files);
    try checkAttributes(io, arena, repo);

    const result = try gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try expectNonzero(result, "semantic conflict merge");
    const unmerged = try gitRun(io, arena, repo, &.{ "ls-files", "-u", "--", "Assets/A.prefab" });
    try expectCode(unmerged, 0, "list semantic conflict index");
    try require(std.mem.indexOf(u8, unmerged.stdout, " 1\tAssets/A.prefab\n") != null, "missing stage 1");
    try require(std.mem.indexOf(u8, unmerged.stdout, " 2\tAssets/A.prefab\n") != null, "missing stage 2");
    try require(std.mem.indexOf(u8, unmerged.stdout, " 3\tAssets/A.prefab\n") != null, "missing stage 3");
    if (!std.mem.eql(u8, conflict_base, try readFile(io, arena, repo, "Assets/A.prefab"))) {
        std.debug.print("semantic merge stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
    }
    try expectFile(io, arena, repo, "Assets/A.prefab", conflict_base);

    const partial = try readFile(io, arena, repo, "Assets/A.prefab");
    // The delete/edit component is atomic: neither the reference nor its document may disappear alone.
    try require(std.mem.indexOf(u8, partial, "component: {fileID: 54}") != null, "partial leaked the component-list deletion");
    try require(std.mem.indexOf(u8, partial, "--- !u!54 &54") != null, "partial leaked the component document deletion");
    try require(std.mem.indexOf(u8, partial, "m_Mass: 2") == null, "partial leaked the conflicting edit");
}

fn testFailurePreservesOurs(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    name: []const u8,
    file: FileSides,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]FileSides{file};
    try prepareRepository(io, arena, repo, prefablens, .local, &files);
    const result = try gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try expectNonzero(result, name);
    try expectFile(io, arena, repo, file.path, file.ours);
}

fn testTextConflictUsesDefaultDriver(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, "text-default" });
    const files = [_]FileSides{.{
        .path = "Notes/A.txt",
        .base = "base\n",
        .ours = "ours\n",
        .theirs = "theirs\n",
    }};
    try prepareRepository(io, arena, repo, prefablens, .local, &files);
    try checkAttributes(io, arena, repo);
    const result = try gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try expectNonzero(result, "text conflict merge");
    const merged = try readFile(io, arena, repo, "Notes/A.txt");
    try require(std.mem.indexOf(u8, merged, "<<<<<<<") != null, "text conflict did not use Git's default driver");
}

pub fn prepareRepository(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    prefablens: []const u8,
    mode: AttributeMode,
    files: []const FileSides,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ repo, "Assets" }));
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ repo, "Notes" }));
    try gitOk(io, arena, repo, &.{ "init", "-q", "-b", "base" });
    try gitOk(io, arena, repo, &.{ "config", "user.email", "prefablens-tests@example.invalid" });
    try gitOk(io, arena, repo, &.{ "config", "user.name", "PrefabLens tests" });
    try gitOk(io, arena, repo, &.{ "config", "merge.prefablens.name", "PrefabLens semantic merge" });
    const driver = try std.fmt.allocPrint(
        arena,
        "{s} merge-driver %O %A %B %P",
        .{try shellQuote(arena, prefablens)},
    );
    try gitOk(io, arena, repo, &.{ "config", "merge.prefablens.driver", driver });
    try installAttributes(io, arena, repo, mode);
    try writeRevision(io, arena, repo, files, .base);
    try gitOk(io, arena, repo, &.{ "add", "--all" });
    try gitOk(io, arena, repo, &.{ "commit", "-q", "-m", "base" });

    try gitOk(io, arena, repo, &.{ "switch", "-q", "-c", "local" });
    try writeRevision(io, arena, repo, files, .ours);
    try gitOk(io, arena, repo, &.{ "add", "--all" });
    try gitOk(io, arena, repo, &.{ "commit", "-q", "-m", "local" });

    try gitOk(io, arena, repo, &.{ "switch", "-q", "base" });
    try gitOk(io, arena, repo, &.{ "switch", "-q", "-c", "remote" });
    try writeRevision(io, arena, repo, files, .theirs);
    try gitOk(io, arena, repo, &.{ "add", "--all" });
    try gitOk(io, arena, repo, &.{ "commit", "-q", "-m", "remote" });
    try gitOk(io, arena, repo, &.{ "switch", "-q", "local" });
}

fn installAttributes(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    mode: AttributeMode,
) !void {
    const relative = if (mode == .local) ".git/info/attributes" else ".gitattributes";
    try writeFile(io, arena, repo, relative, "*.prefab merge=prefablens\n");
}

fn checkAttributes(io: std.Io, arena: std.mem.Allocator, repo: []const u8) !void {
    const result = try gitRun(
        io,
        arena,
        repo,
        &.{ "check-attr", "merge", "--", "Assets/A.prefab", "Notes/A.txt" },
    );
    try expectCode(result, 0, "check merge attributes");
    try require(
        std.mem.indexOf(u8, result.stdout, "Assets/A.prefab: merge: prefablens") != null,
        "prefab attribute did not select PrefabLens",
    );
    try require(
        std.mem.indexOf(u8, result.stdout, "Notes/A.txt: merge: unspecified") != null,
        "text attribute unexpectedly selected PrefabLens",
    );
}

fn writeRevision(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    files: []const FileSides,
    side: RevisionSide,
) !void {
    for (files) |file| {
        const bytes = switch (side) {
            .base => file.base,
            .ours => file.ours,
            .theirs => file.theirs,
        };
        try writeFile(io, arena, repo, file.path, bytes);
    }
}

pub fn scratchDirectory(io: std.Io, arena: std.mem.Allocator, label: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const relative = try std.fmt.allocPrint(
        arena,
        ".zig-cache/tmp/prefablens-{s}-{x}",
        .{ label, std.mem.readInt(u64, &random_bytes, .little) },
    );
    try std.Io.Dir.cwd().createDirPath(io, relative);
    return std.Io.Dir.cwd().realPathFileAlloc(io, relative, arena);
}

pub fn shellQuote(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(arena, "'\\''");
        } else {
            try quoted.append(arena, byte);
        }
    }
    try quoted.append(arena, '\'');
    return quoted.toOwnedSlice(arena);
}

fn writeFile(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    relative: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ repo, relative });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readFile(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    relative: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(arena, &.{ repo, relative });
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
}

pub fn expectFile(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    relative: []const u8,
    expected: []const u8,
) !void {
    const actual = try readFile(io, arena, repo, relative);
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("integration file mismatch for {s}\nexpected:\n{s}\nactual:\n{s}\n", .{ relative, expected, actual });
        return error.IntegrationFileMismatch;
    }
}

pub fn gitRun(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, args);
    return std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
    });
}

pub fn gitOk(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    args: []const []const u8,
) !void {
    try expectCode(try gitRun(io, arena, repo, args), 0, args[0]);
}

pub fn expectCode(result: std.process.RunResult, expected: u8, context: []const u8) !void {
    const actual = switch (result.term) {
        .exited => |code| code,
        else => {
            std.debug.print("{s}: unexpected termination: {any}\n", .{ context, result.term });
            return error.UnexpectedProcessTermination;
        },
    };
    if (actual != expected) {
        std.debug.print(
            "{s}: expected exit {d}, got {d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ context, expected, actual, result.stdout, result.stderr },
        );
        return error.UnexpectedProcessExit;
    }
}

pub fn expectNonzero(result: std.process.RunResult, context: []const u8) !void {
    const actual = switch (result.term) {
        .exited => |code| code,
        else => {
            std.debug.print("{s}: unexpected termination: {any}\n", .{ context, result.term });
            return error.UnexpectedProcessTermination;
        },
    };
    if (actual == 0) {
        std.debug.print("{s}: expected failure\nstdout:\n{s}\nstderr:\n{s}\n", .{ context, result.stdout, result.stderr });
        return error.UnexpectedProcessExit;
    }
}

pub fn require(condition: bool, message: []const u8) !void {
    if (condition) return;
    std.debug.print("git merge integration: {s}\n", .{message});
    return error.IntegrationExpectationFailed;
}
