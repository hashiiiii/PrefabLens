const std = @import("std");
const t = @import("testing/git.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

const path = "Assets/A.prefab";
const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n  m_Unpicked: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n  m_Unpicked: 1\n";
const parent = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n  m_Unpicked: 2\n";
const picked = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n  m_Unpicked: 2\n";
const expected = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n  m_Unpicked: 1\n";

const Context = struct {
    git: Git,
    scratch: []const u8,
    prefablens: []const u8,

    fn repo(self: Context, name: []const u8, remote: []const u8) !Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.scratch, name });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.prefablens, .local, &.{.{ .path = path, .base = base, .ours = ours, .theirs = remote }});
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        return git;
    }
};

pub fn run(git: Git, scratch: []const u8, prefablens: []const u8) !void {
    const ctx: Context = .{ .git = git, .scratch = scratch, .prefablens = prefablens };
    try pickedDelta(ctx);
    try repeatedReplay(ctx);
    try packedReplay(ctx);
    try rootPick(ctx);
    try multipleBases(ctx);
    try conflictLifecycle(ctx);
    try pull(ctx);
    try std.Io.File.stdout().writeStreamingAll(git.io, "git replay integration: passed\n");
}

fn multipleBases(ctx: Context) !void {
    const git = try ctx.repo("replay-multiple-bases", parent);
    const local = merge_git.trim(try git.output(&.{ "rev-parse", "local" }));
    try git.ok(&.{ "merge", "-s", "ort", "--no-edit", "remote" });
    _ = try commit(git, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n  m_Unpicked: 2\n");
    try git.ok(&.{ "switch", "-q", "remote" });
    try git.ok(&.{ "merge", "-s", "ort", "--no-edit", local });
    _ = try commit(git, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n  m_Unpicked: 3\n");
    try git.ok(&.{ "switch", "-q", "local" });
    const ancestors = try git.output(&.{ "merge-base", "--all", "local", "remote" });
    try t.require(std.mem.count(u8, ancestors, "\n") == 2, "criss-cross fixture lost its two merge bases");
    // Both supplied bases are needed to construct ort's virtual ancestor.
    // The adapter must not accidentally select one parent or invent a root.
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 0, "preserve multiple merge bases");
    try expect(git, path, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n  m_Unpicked: 3\n");
    try assertClean(git);
}

fn packedReplay(ctx: Context) !void {
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: 11111111111111111111111111111111, type: 3}\n  values: ";
    const script = "using UnityEngine; class Example : MonoBehaviour { public int[] values; }\n";
    const meta = "guid: 11111111111111111111111111111111\n";
    for ([_]bool{ false, true }) |no_commit| {
        var git = ctx.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ ctx.scratch, if (no_commit) "packed-pick-no-commit" else "packed-rebase" });
        try t.prepareRepository(git.io, git.arena, git.cwd, ctx.prefablens, .local, &.{
            .{ .path = path, .base = prefix ++ "0100000002000000i\n", .ours = prefix ++ "010000000200000003000000i\n", .theirs = prefix ++ "040000000100000002000000i\n" },
            .{ .path = "Assets/Example.cs", .base = script, .ours = script, .theirs = script },
            .{ .path = "Assets/Example.cs.meta", .base = meta, .ours = meta, .theirs = meta },
        });
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        const before = try git.output(&.{ "rev-parse", "HEAD" });
        // Packed int arrays need historical C# type evidence. Text merging the
        // scalar token cannot combine these independent prepend/append edits.
        try t.expectCode(try git.run(if (no_commit) &.{ "cherry-pick", "--no-commit", "remote" } else &.{ "rebase", "remote" }), 0, "semantic packed-array replay");
        try expect(git, path, prefix ++ "04000000010000000200000003000000i\n");
        if (no_commit) {
            try t.require(std.mem.eql(u8, before, try git.output(&.{ "rev-parse", "HEAD" })), "semantic no-commit moved HEAD");
        } else try assertClean(git);
    }
}

fn write(git: Git, name: []const u8, bytes: []const u8) !void {
    try t.writeFile(git.io, git.arena, git.cwd, name, bytes);
}

fn expect(git: Git, name: []const u8, bytes: []const u8) !void {
    try t.expectFile(git.io, git.arena, git.cwd, name, bytes);
}

fn commit(git: Git, bytes: []const u8) ![]const u8 {
    try write(git, path, bytes);
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "picked change" });
    return merge_git.trim(try git.output(&.{ "rev-parse", "HEAD" }));
}

fn assertClean(git: Git) !void {
    try t.require((try git.output(&.{ "status", "--porcelain" })).len == 0, "replay left a dirty index or worktree");
}

fn pickedDelta(ctx: Context) !void {
    const Mode = enum { pick, no_commit, mainline, onto };
    inline for (std.meta.tags(Mode)) |mode| {
        const git = try ctx.repo(try std.fmt.allocPrint(ctx.git.arena, "replay-delta-{s}", .{@tagName(mode)}), parent);
        try git.ok(&.{ "switch", "-q", "remote" });
        const tip = try commit(git, picked);
        try git.ok(&.{ "switch", "-q", "local" });
        const before = try git.output(&.{ "rev-parse", "HEAD" });
        // The selected parent changed m_Unpicked, but that earlier change is
        // outside this operation. A recomputed merge base imports it anyway.
        switch (mode) {
            .pick => try t.expectCode(try git.run(&.{ "cherry-pick", tip }), 0, "pick only the selected delta"),
            .no_commit => {
                try t.expectCode(try git.run(&.{ "cherry-pick", "--no-commit", tip }), 0, "pick without committing");
                try t.require(std.mem.eql(u8, before, try git.output(&.{ "rev-parse", "HEAD" })), "no-commit moved HEAD");
            },
            .mainline => {
                const tree = merge_git.trim(try git.output(&.{ "rev-parse", try std.fmt.allocPrint(git.arena, "{s}^{{tree}}", .{tip}) }));
                const merged = merge_git.trim(try git.output(&.{ "commit-tree", tree, "-p", "base", "-p", "remote^", "-m", "two parents" }));
                try t.expectCode(try git.run(&.{ "cherry-pick", "-m", "2", merged }), 0, "pick the selected merge mainline");
            },
            .onto => {
                try git.ok(&.{ "switch", "-q", "-c", "replay", tip });
                try t.expectCode(try git.run(&.{ "rebase", "--onto", "local", "remote^" }), 0, "rebase onto a different ancestry");
            },
        }
        try expect(git, path, expected);
        if (mode == .no_commit) {
            // The second --no-commit operation receives the staged tree as
            // Ours, rather than a commit. Its schema handoff must accept it.
            try git.ok(&.{ "switch", "-q", "--discard-changes", "remote" });
            const second = try commit(git, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 4\n  m_Unpicked: 2\n");
            try git.ok(&.{ "switch", "-q", "local" });
            try t.expectCode(try git.run(&.{ "cherry-pick", "--no-commit", tip, second }), 0, "accumulate two picks in the index");
            try expect(git, path, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 4\n  m_Unpicked: 1\n");
            try t.require(std.mem.eql(u8, before, try git.output(&.{ "rev-parse", "HEAD" })), "accumulated picks moved HEAD");
            try git.ok(&.{ "reset", "--hard", "HEAD" });
        } else try assertClean(git);
        if (mode == .pick) {
            // Revert uses Git's internal strategy even with pull.twohead set.
            // The shared file driver must reverse just this delta as well.
            try t.expectCode(try git.run(&.{ "revert", "--no-edit", tip }), 0, "revert the picked delta");
            try expect(git, path, ours);
            try assertClean(git);
        }
    }
}

fn repeatedReplay(ctx: Context) !void {
    for ([_]bool{ false, true }) |via_pull| {
        const git = try ctx.repo(if (via_pull) "pull-rebase" else "multi-rebase", parent);
        const final = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 4\n  m_Right: 1\n  m_Unpicked: 1\n";
        _ = try commit(git, final);
        // Replaying the second edit must compare 2 -> 4, not 1 -> 4.
        // The rebased first commit is no longer an ancestor of the old tip.
        try t.expectCode(try git.run(if (via_pull) &.{ "pull", "--rebase", ".", "remote" } else &.{ "rebase", "remote" }), 0, "replay successive edits to the same field");
        try expect(git, path, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 4\n  m_Right: 1\n  m_Unpicked: 2\n");
        try t.require(std.mem.eql(u8, merge_git.trim(try git.output(&.{ "rev-list", "--count", "remote..HEAD" })), "2"), "rebase changed the number of picked commits");
        try assertClean(git);
    }
}

fn rootPick(ctx: Context) !void {
    const git = try ctx.repo("root-pick", parent);
    try git.ok(&.{ "switch", "--orphan", "root-pick" });
    const added = "--- !u!114 &2\nMonoBehaviour:\n  values: [A, B]\n";
    try std.Io.Dir.cwd().createDirPath(git.io, try git.path("Assets"));
    try write(git, "Assets/Root.prefab", added);
    try git.ok(&.{ "add", "--all" });
    try git.ok(&.{ "commit", "-qm", "root asset" });
    try git.ok(&.{ "switch", "-q", "local" });
    // Git represents a root commit's absent parent with an empty tree OID.
    try t.expectCode(try git.run(&.{ "cherry-pick", "root-pick" }), 0, "pick a root commit with an empty-tree base");
    try expect(git, path, ours);
    try expect(git, "Assets/Root.prefab", added);
    try assertClean(git);
}

fn conflictLifecycle(ctx: Context) !void {
    const conflict = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 3\n  m_Right: 1\n  m_Unpicked: 1\n";
    const Operation = enum { pick, rebase, revert };
    inline for (std.meta.tags(Operation)) |operation| {
        const git = try ctx.repo(try std.fmt.allocPrint(ctx.git.arena, "replay-conflict-{s}", .{@tagName(operation)}), conflict);
        if (operation == .revert) _ = try commit(git, conflict);
        const head = try git.output(&.{ "rev-parse", "HEAD" });
        const args: []const []const u8 = switch (operation) {
            .pick => &.{ "cherry-pick", "remote" },
            .rebase => &.{ "rebase", "remote" },
            .revert => &.{ "revert", "--no-edit", "HEAD^" },
        };
        const name: []const u8 = switch (operation) {
            .pick => "cherry-pick",
            .rebase => "rebase",
            .revert => "revert",
        };
        try t.expectCode(try git.run(args), 1, "stop at a replay conflict");
        const actual_base = try git.output(&.{ "show", ":1:Assets/A.prefab" });
        try t.require(std.mem.eql(u8, actual_base, if (operation == .revert) ours else base), "conflict stage 1 lost the operation's supplied base");
        try t.require((try git.output(&.{ "ls-files", "--unmerged" })).len != 0, "replay discarded conflict stages");
        try git.ok(&.{ name, "--abort" });
        try t.require(std.mem.eql(u8, head, try git.output(&.{ "rev-parse", "HEAD" })), "abort did not restore HEAD");
        try expect(git, path, if (operation == .revert) conflict else ours);
        try assertClean(git);

        try t.expectCode(try git.run(args), 1, "retry replay conflict");
        const resolution = if (operation == .pick) conflict else if (operation == .rebase) ours else base;
        try write(git, path, resolution);
        try git.ok(&.{ "add", path });
        try t.expectCode(try git.run(&.{ "-c", "core.editor=true", name, "--continue" }), 0, "continue after resolving replay conflict");
        try expect(git, path, resolution);
        try assertClean(git);
    }
}

fn pull(ctx: Context) !void {
    const git = try ctx.repo("pull-merge", picked);
    try t.expectCode(try git.run(&.{ "pull", "--no-rebase", "--no-edit", ".", "remote" }), 0, "merge during pull");
    try expect(git, path, "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n  m_Unpicked: 2\n");
    try assertClean(git);
    try git.ok(&.{ "switch", "-q", "base" });
    try t.expectCode(try git.run(&.{ "pull", "--ff-only", ".", "remote" }), 0, "fast-forward pull");
    try expect(git, path, picked);
    try assertClean(git);
}
