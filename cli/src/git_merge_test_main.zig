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

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
    }
    try testSemanticConflict(io, arena, scratch, prefablens);
    try testTextConflictUsesDefaultDriver(io, arena, scratch, prefablens);
    try testConflictStyles(io, arena, scratch, prefablens);

    try std.Io.File.stdout().writeStreamingAll(io, "git merge integration: passed\n");
    return 0;
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
) !void {
    const repo = try std.fs.path.join(arena, &.{ scratch, "conflict-local" });
    const files = [_]support.FileSides{.{
        .path = "Assets/A.prefab",
        .base = conflict_base,
        .ours = conflict_ours,
        .theirs = conflict_theirs,
    }};
    try support.prepareRepository(io, arena, repo, prefablens, .local, &files);
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
