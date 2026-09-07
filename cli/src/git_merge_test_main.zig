const std = @import("std");
const builtin = @import("builtin");
const support = @import("testing/git.zig");

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

const standalone_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 1
++ "\n";
const standalone_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 2
++ "\n";
const standalone_theirs = standalone_base ++
    \\--- !u!21 &2
    \\Material:
    \\  m_Name: Added
++ "\n";
const standalone_expected = standalone_ours ++
    \\--- !u!21 &2
    \\Material:
    \\  m_Name: Added
++ "\n";

const header_theirs =
    \\--- !u!114 &1 stripped
    \\MonoBehaviour:
    \\  m_Value: 1
++ "\n";
const header_expected =
    \\--- !u!114 &1 stripped
    \\MonoBehaviour:
    \\  m_Value: 2
++ "\n";

const comment_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  # Base comment.
    \\  m_Value: 1
++ "\n";
const comment_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  # Base comment.
    \\  m_Value: 2
++ "\n";
const comment_theirs =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  # Theirs comment.
    \\  m_Value: 1
++ "\n";

const document_delete_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  # Base comment.
    \\  m_Value: 1
++ "\n";
const document_delete_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  # Ours comment.
    \\  m_Value: 1
++ "\n";

const sequence_comment_base =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  # Base comment.
    \\  - component: {fileID: 54}
    \\  m_Name: Base
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
const sequence_comment_ours =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  # Base comment.
    \\  - component: {fileID: 54}
    \\  m_Name: Ours
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
const sequence_comment_theirs =
    \\--- !u!1 &1
    \\GameObject:
    \\  m_Component:
    \\  - component: {fileID: 4}
    \\  # Theirs comment.
    \\  - component: {fileID: 54}
    \\  m_Name: Base
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

const duplicate_key_ours =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 2
    \\  m_Value: duplicate
++ "\n";

const order_base =
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 1
++ "\n";
const order_theirs =
    \\--- !u!21 &2
    \\Material:
    \\  m_Name: Added
    \\--- !u!114 &1
    \\MonoBehaviour:
    \\  m_Value: 2
++ "\n";
pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testGitShellExecutablePath(arena);
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    try support.require(args.len == 2, "expected the prefablens executable path");
    const native_prefablens = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const prefablens = try support.normalizeExecutablePathForGitShell(
        arena,
        native_prefablens,
        builtin.os.tag == .windows,
    );

    const scratch = try support.scratchDirectory(io, arena, "git");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    inline for (.{ support.AttributeMode.local, support.AttributeMode.tracked }) |mode| {
        try testAutomaticMerge(io, arena, scratch, prefablens, mode);
        try testSemanticConflict(io, arena, scratch, prefablens, mode);
    }
    try testStandaloneDocumentMerge(io, arena, scratch, prefablens, false);
    try testStandaloneDocumentMerge(io, arena, scratch, prefablens, true);
    try testDocumentOrderConflict(io, arena, scratch, prefablens);
    try testHeaderMerge(io, arena, scratch, prefablens);
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "source-comment", .{
        .path = "Assets/A.prefab",
        .base = comment_base,
        .ours = comment_ours,
        .theirs = comment_theirs,
    });
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "sequence-comment", .{
        .path = "Assets/Conflict.prefab",
        .base = sequence_comment_base,
        .ours = sequence_comment_ours,
        .theirs = sequence_comment_theirs,
    });
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "document-delete-source", .{
        .path = "Assets/A.prefab",
        .base = document_delete_base,
        .ours = document_delete_ours,
        .theirs = "",
    });
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "malformed", .{
        .path = "Assets/A.prefab",
        .base = automatic_base,
        .ours = "not Unity YAML\n",
        .theirs = automatic_theirs,
    });
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "duplicate-key", .{
        .path = "Assets/A.prefab",
        .base = automatic_base,
        .ours = duplicate_key_ours,
        .theirs = automatic_theirs,
    });
    try testUnsupportedConflictPreservesSources(io, arena, scratch, prefablens, "unknown-sequence", .{
        .path = "Assets/A.prefab",
        .base = sequence_base,
        .ours = sequence_ours,
        .theirs = sequence_theirs,
    });
    try testTextConflictUsesDefaultDriver(io, arena, scratch, prefablens);
    try testConflictStyles(io, arena, scratch, prefablens);

    try std.Io.File.stdout().writeStreamingAll(io, "git merge integration: passed\n");
    return 0;
}

fn testGitShellExecutablePath(arena: std.mem.Allocator) !void {
    const windows_path = "C:\\Prefab Lens\\prefablens's.exe";
    const normalized = try support.normalizeExecutablePathForGitShell(arena, windows_path, true);
    try support.require(
        std.mem.eql(u8, normalized, "C:/Prefab Lens/prefablens's.exe"),
        "Windows executable path was not normalized for Git's POSIX shell",
    );
    const quoted = try support.shellQuote(arena, normalized);
    try support.require(
        std.mem.eql(u8, quoted, "'C:/Prefab Lens/prefablens'\\''s.exe'"),
        "normalized executable path lost shell quoting",
    );

    const posix_path = "/tmp/prefablens\\literal";
    const preserved = try support.normalizeExecutablePathForGitShell(arena, posix_path, false);
    try support.require(
        std.mem.eql(u8, preserved, posix_path),
        "non-Windows executable path was modified",
    );
}

fn testAutomaticMerge(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    mode: support.AttributeMode,
) !void {
    const name = if (mode == .local) "automatic-local" else "automatic-tracked";
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = automatic_base,
        .ours = automatic_ours,
        .theirs = automatic_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, mode, &files);
    try support.checkAttributes(io, arena, repo);

    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectCode(result, 0, "automatic merge");
    const unmerged = try support.gitRun(io, arena, repo, &.{ "ls-files", "-u" });
    try support.expectCode(unmerged, 0, "list automatic merge index");
    try support.require(unmerged.stdout.len == 0, "automatic merge left unmerged index entries");
    try support.expectFile(io, arena, repo, "Assets/A.prefab", automatic_expected);
}

fn testSemanticConflict(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    mode: support.AttributeMode,
) !void {
    const name = if (mode == .local) "conflict-local" else "conflict-tracked";
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = conflict_base,
        .ours = conflict_ours,
        .theirs = conflict_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, mode, &files);
    try support.checkAttributes(io, arena, repo);

    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectNonzero(result, "semantic conflict merge");
    const unmerged = try support.gitRun(io, arena, repo, &.{ "ls-files", "-u", "--", "Assets/A.prefab" });
    try support.expectCode(unmerged, 0, "list semantic conflict index");
    try support.require(std.mem.indexOf(u8, unmerged.stdout, " 1\tAssets/A.prefab\n") != null, "missing stage 1");
    try support.require(std.mem.indexOf(u8, unmerged.stdout, " 2\tAssets/A.prefab\n") != null, "missing stage 2");
    try support.require(std.mem.indexOf(u8, unmerged.stdout, " 3\tAssets/A.prefab\n") != null, "missing stage 3");
    const markers = try support.expectMarkers(io, arena, repo, "Assets/A.prefab");
    try support.require(std.mem.indexOf(u8, markers, "m_Mass: 2") != null, "markers lost the conflicting edit");
    // The full original component list and document remain available in the index.
    try support.expectStage(io, arena, repo, "Assets/A.prefab", 1, conflict_base);
    try support.expectStage(io, arena, repo, "Assets/A.prefab", 2, conflict_ours);
    try support.expectStage(io, arena, repo, "Assets/A.prefab", 3, conflict_theirs);
}

fn testStandaloneDocumentMerge(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    swap_sides: bool,
) !void {
    const repo = try std.fs.path.join(arena, &.{
        scratch,
        if (swap_sides) "standalone-ours" else "standalone-theirs",
    });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = standalone_base,
        .ours = if (swap_sides) standalone_theirs else standalone_ours,
        .theirs = if (swap_sides) standalone_ours else standalone_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);

    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectCode(result, 0, "standalone document merge");
    try support.expectFile(io, arena, repo, "Assets/A.prefab", standalone_expected);
}

fn testDocumentOrderConflict(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, "document-order" });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = order_base,
        .ours = "",
        .theirs = order_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);

    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectCode(result, 1, "document order conflict");
    const merged = try support.expectMarkers(io, arena, repo, "Assets/A.prefab");
    const material = std.mem.indexOf(u8, merged, "--- !u!21 &2") orelse
        return error.TestUnexpectedResult;
    const behaviour = std.mem.indexOf(u8, merged, "--- !u!114 &1") orelse
        return error.TestUnexpectedResult;
    try support.require(material < behaviour, "document headers have the wrong order");
}

fn testHeaderMerge(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, "header" });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = standalone_base,
        .ours = standalone_ours,
        .theirs = header_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);

    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectCode(result, 0, "header merge");
    try support.expectFile(io, arena, repo, "Assets/A.prefab", header_expected);
}

fn testUnsupportedConflictPreservesSources(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
    name: []const u8,
    file: support.FileSides,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, name });
    const files = [_]support.FileSides{file};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);
    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectNonzero(result, name);
    _ = try support.expectMarkers(io, arena, repo, file.path);
    try support.expectStage(io, arena, repo, file.path, 1, file.base);
    try support.expectStage(io, arena, repo, file.path, 2, file.ours);
    try support.expectStage(io, arena, repo, file.path, 3, file.theirs);
}

fn testTextConflictUsesDefaultDriver(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, "text-default" });
    const files = [_]support.FileSides{.{
        .path = "Notes/A.txt",
        .base = "base\n",
        .ours = "ours\n",
        .theirs = "theirs\n",
    }};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);
    try support.checkAttributes(io, arena, repo);
    const result = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
    try support.expectNonzero(result, "text conflict merge");
    const merged = try support.readFile(io, arena, repo, "Notes/A.txt");
    try support.require(std.mem.indexOf(u8, merged, "<<<<<<<") != null, "text conflict did not use Git's default driver");
}

fn testConflictStyles(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: []const u8,
    prefablens: []const u8,
) !void {
    for ([_][]const u8{ "merge", "diff3", "zdiff3" }) |style| {
        const repo = try std.fs.path.join(arena, &.{ scratch, style });
        const file: support.FileSides = .{
            .path = "Assets/Style.prefab",
            .base = standalone_base,
            .ours = standalone_ours,
            .theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Value: 3\n",
        };
        try support.prepareRepository(io, arena, repo, prefablens, .local, &.{file});
        try support.gitOk(io, arena, repo, &.{ "config", "merge.conflictStyle", style });
        try support.writeFile(io, arena, repo, ".git/info/attributes", "*.prefab merge=prefablens conflict-marker-size=11\n");
        const merged = try support.gitRun(io, arena, repo, &.{ "merge", "--no-edit", "remote" });
        try support.expectCode(merged, 1, "merge with conflict style");
        const expected = try std.fmt.allocPrint(arena, "--- !u!114 &1\nMonoBehaviour:\n<<<<<<<<<<< ours\n  m_Value: 2\n{s}===========\n  m_Value: 3\n>>>>>>>>>>> theirs\n", .{if (std.mem.eql(u8, style, "merge")) "" else "||||||||||| base\n  m_Value: 1\n"});
        try support.expectFile(io, arena, repo, file.path, expected);
    }
}
