const std = @import("std");
const builtin = @import("builtin");
const t = @import("testing/git.zig");
const pty = @import("testing/pty.zig");
const merge_git = @import("merge_git.zig");

const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Name: Structural fixture\n  m_Enabled: 1\n  m_EditorClassIdentifier: \n  m_Left: 1\n  m_Right: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Name: Structural fixture\n  m_Enabled: 1\n  m_EditorClassIdentifier: \n  m_Left: 2\n  m_Right: 1\n";
const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Name: Structural fixture\n  m_Enabled: 1\n  m_EditorClassIdentifier: \n  m_Left: 1\n  m_Right: 3\n";
const merged = "--- !u!114 &1\nMonoBehaviour:\n  m_Name: Structural fixture\n  m_Enabled: 1\n  m_EditorClassIdentifier: \n  m_Left: 2\n  m_Right: 3\n";
const metadata = "fileFormatVersion: 2\nguid: 1234567890abcdef1234567890abcdef\nPrefabImporter:\n  externalObjects: {}\n  userData: \n  assetBundleName: \n  assetBundleVariant: \n";
const old_path = "Assets/Original asset.prefab";
const ours_path = "Assets/Current asset.prefab";
const theirs_path = "Assets/Incoming asset.prefab";
const Kind = enum { modify_delete, rename_delete, rename_rename };

const Context = struct {
    git: merge_git.Git,
    scratch: []const u8,
    prefablens: []const u8,

    fn repo(self: Context, name: []const u8, kind: Kind, current_deleted: bool, with_meta: bool, mixed: bool) !merge_git.Git {
        var git = self.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ self.scratch, name });
        var files: std.ArrayList(t.FileSides) = .empty;
        try files.append(git.arena, .{ .path = old_path, .base = base, .ours = ours, .theirs = theirs });
        if (with_meta) try files.append(git.arena, .{ .path = old_path ++ ".meta", .base = metadata, .ours = metadata, .theirs = metadata });
        if (mixed) try files.append(git.arena, .{ .path = "Notes/conflict.txt", .base = "base\n", .ours = "ours\n", .theirs = "theirs\n" });
        try t.prepareRepository(git.io, git.arena, git.cwd, self.prefablens, .local, files.items);
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        for ([_]bool{ true, false }) |current| {
            try git.ok(&.{ "switch", "-q", if (current) "local" else "remote" });
            const deleted = kind != .rename_rename and current == current_deleted;
            if (deleted) {
                try git.ok(&.{ "rm", "-q", "--", old_path });
                if (with_meta) try git.ok(&.{ "rm", "-q", "--", old_path ++ ".meta" });
            } else if (kind != .modify_delete) {
                const destination = if (current) ours_path else theirs_path;
                try git.ok(&.{ "mv", "--", old_path, destination });
                if (with_meta) try git.ok(&.{ "mv", "--", old_path ++ ".meta", try std.fmt.allocPrint(git.arena, "{s}.meta", .{destination}) });
            }
            try git.ok(&.{ "commit", "-q", "--amend", "--no-edit" });
        }
        try git.ok(&.{ "switch", "-q", "local" });
        return git;
    }
};

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    try t.require(args.len == 3, "expected CLI and strategy executable paths");
    const scratch = try t.scratchDirectory(init.io, a, "structural");
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const prefablens = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a);
    const strategy = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a);
    var env = try init.environ_map.clone(a);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}{c}{s}", .{ std.fs.path.dirname(prefablens).?, std.fs.path.delimiter, std.fs.path.dirname(strategy).?, std.fs.path.delimiter, env.get("PATH") orelse "" }));
    const ctx: Context = .{ .git = .{ .io = init.io, .arena = a, .env = &env }, .scratch = scratch, .prefablens = prefablens };
    if (selected(&env, "no-terminal")) try noTerminal(ctx);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        if (selected(&env, "delete")) try deletionChoices(ctx);
        if (selected(&env, "rename")) try renameChoices(ctx);
        if (selected(&env, "quit")) try quitAndAbort(ctx);
        if (selected(&env, "guards")) try guardedPairs(ctx);
        if (selected(&env, "mixed")) try mixedAndNoMetadata(ctx);
        if (selected(&env, "no-commit")) try noCommitAndMode(ctx);
        if (selected(&env, "content")) try renameContent(ctx);
        if (selected(&env, "concurrent")) try concurrentChanges(ctx);
        if (selected(&env, "paths")) try escapedPaths(ctx);
        if (selected(&env, "crlf")) try crlf(ctx);
        if (selected(&env, "rollback")) try rollback(ctx);
        if (selected(&env, "meta-auto")) try metadataAutomatic(ctx);
        if (selected(&env, "mode")) try concurrentModes(ctx);
        if (selected(&env, "umask")) try restoredMetadataUmask(ctx);
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "git structural integration: passed\n");
    return 0;
}

fn selected(env: *std.process.Environ.Map, name: []const u8) bool {
    const filter = env.get("PREFABLENS_STRUCTURAL_CASE") orelse return true;
    return std.mem.eql(u8, filter, name);
}

fn runPty(git: merge_git.Git, keys: []const u8) !std.process.RunResult {
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    return pty.runCommandInPty(git.io, git.arena, git.cwd, command, keys, 30);
}

fn expectFile(git: merge_git.Git, path: []const u8, bytes: []const u8) !void {
    try t.expectFile(git.io, git.arena, git.cwd, path, bytes);
}

fn expectAbsent(git: merge_git.Git, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(git.io, try git.path(path), .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ExpectedAbsentFile;
}

fn noTerminal(ctx: Context) !void {
    for ([_]Kind{ .modify_delete, .rename_delete, .rename_rename }) |kind| {
        const git = try ctx.repo(try std.fmt.allocPrint(ctx.git.arena, "no-tty-{s}", .{@tagName(kind)}), kind, false, true, false);
        try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "structural conflict without terminal");
        try t.require((try git.output(&.{ "ls-files", "-u", "-z" })).len > 0, "no-terminal merge lost conflict stages");
        try git.ok(&.{ "merge", "--abort" });
        try expectFile(git, if (kind == .modify_delete) old_path else ours_path, ours);
    }
}

fn deletionChoices(ctx: Context) !void {
    for ([_]Kind{ .modify_delete, .rename_delete }) |kind| {
        for ([_]bool{ false, true }) |current_deleted| {
            for ([_]bool{ false, true }) |keep| {
                const name = try std.fmt.allocPrint(ctx.git.arena, "{s}-{s}-{s}", .{ @tagName(kind), if (current_deleted) "current-deleted" else "incoming-deleted", if (keep) "keep" else "delete" });
                const git = try ctx.repo(name, kind, current_deleted, true, false);
                try t.expectCode(try runPty(git, if (keep) "k\r" else "d\r"), 0, name);
                const path = if (kind == .modify_delete) old_path else if (current_deleted) theirs_path else ours_path;
                const meta_path = try std.fmt.allocPrint(git.arena, "{s}.meta", .{path});
                if (keep) {
                    try expectFile(git, path, if (current_deleted) theirs else ours);
                    try expectFile(git, meta_path, metadata);
                } else {
                    try expectAbsent(git, path);
                    try expectAbsent(git, meta_path);
                }
                if (kind == .rename_delete) {
                    try expectAbsent(git, old_path);
                    try expectAbsent(git, old_path ++ ".meta");
                }
                try t.require((try git.output(&.{ "ls-files", "-u" })).len == 0, "file choice left unmerged paths");
            }
        }
    }
}

fn renameChoices(ctx: Context) !void {
    for ([_]bool{ false, true }) |choose_current| {
        const git = try ctx.repo(if (choose_current) "rename-current" else "rename-incoming", .rename_rename, false, true, false);
        try t.expectCode(try runPty(git, if (choose_current) "a\r" else "b\r"), 0, "rename/rename path and combined content");
        const final_path = if (choose_current) ours_path else theirs_path;
        try expectFile(git, final_path, merged);
        try expectFile(git, try std.fmt.allocPrint(git.arena, "{s}.meta", .{final_path}), metadata);
        try expectAbsent(git, if (choose_current) theirs_path else ours_path);
        try expectAbsent(git, try std.fmt.allocPrint(git.arena, "{s}.meta", .{if (choose_current) theirs_path else ours_path}));
        try expectAbsent(git, old_path);
        try t.require((try git.output(&.{ "ls-files", "-u" })).len == 0, "rename choice left unmerged paths");
    }
}

fn quitAndAbort(ctx: Context) !void {
    const git = try ctx.repo("quit", .rename_rename, false, true, false);
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "prepare native quit reference");
    const native_stages = try git.output(&.{ "ls-files", "-u", "-z" });
    const native_current = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(ours_path), git.arena, .limited(1024 * 1024));
    const native_incoming = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(theirs_path), git.arena, .limited(1024 * 1024));
    try git.ok(&.{ "merge", "--abort" });
    try t.expectCode(try runPty(git, "q"), 1, "quit file choice");
    try t.require(std.mem.eql(u8, native_stages, try git.output(&.{ "ls-files", "-u", "-z" })), "quit changed native conflict stages");
    try expectFile(git, ours_path, native_current);
    try expectFile(git, theirs_path, native_incoming);
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, ours_path, ours);
    try expectFile(git, ours_path ++ ".meta", metadata);
    try expectAbsent(git, theirs_path);
}

fn write(git: merge_git.Git, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(git.io, .{ .sub_path = try git.path(path), .data = bytes });
}

fn guardedPairs(ctx: Context) !void {
    const mismatch = try ctx.repo("guid-mismatch", .modify_delete, false, true, false);
    const different_guid = "fileFormatVersion: 2\nguid: ffffffffffffffffffffffffffffffff\n";
    try write(mismatch, old_path ++ ".meta", different_guid);
    try mismatch.ok(&.{ "add", "--", old_path ++ ".meta" });
    try mismatch.ok(&.{ "commit", "-qm", "Change metadata identity" });
    const mismatch_result = try runPty(mismatch, "d\r");
    try t.expectCode(mismatch_result, 1, "refuse metadata GUID mismatch");
    try t.require(!pty.terminalCaptureContains(mismatch_result.stdout, "Unity asset file conflict"), "GUID mismatch opened a file-choice UI");
    try expectFile(mismatch, old_path, ours);
    try expectFile(mismatch, old_path ++ ".meta", different_guid);
    try t.require((try mismatch.output(&.{ "ls-files", "-u" })).len != 0, "GUID mismatch cleared stages");
    try mismatch.ok(&.{ "merge", "--abort" });

    const ambiguous = try ctx.repo("metadata-content-conflict", .rename_rename, false, true, false);
    for ([_]bool{ false, true }) |current| {
        try ambiguous.ok(&.{ "switch", "-q", if (current) "local" else "remote" });
        const path = if (current) ours_path ++ ".meta" else theirs_path ++ ".meta";
        const changed = try std.mem.replaceOwned(u8, ambiguous.arena, metadata, "userData: ", if (current) "userData: current" else "userData: incoming");
        try write(ambiguous, path, changed);
        try ambiguous.ok(&.{ "add", "--", path });
        try ambiguous.ok(&.{ "commit", "-qm", "Change importer data" });
    }
    const ambiguous_result = try runPty(ambiguous, "a\r");
    try t.expectCode(ambiguous_result, 1, "refuse ambiguous metadata content");
    try t.require(!pty.terminalCaptureContains(ambiguous_result.stdout, "Unity asset file conflict"), "metadata ambiguity opened a file-choice UI");
    const unmerged = try ambiguous.output(&.{ "ls-files", "-u" });
    try t.require(std.mem.indexOf(u8, unmerged, ".prefab\n") != null, "metadata ambiguity resolved the asset independently");
    try ambiguous.ok(&.{ "merge", "--abort" });

    const binary = try ctx.repo("unity-looking-binary", .modify_delete, false, false, false);
    try write(binary, old_path, ours ++ "\x00binary");
    try binary.ok(&.{ "add", "--", old_path });
    try binary.ok(&.{ "commit", "-qm", "Binary input" });
    const binary_result = try runPty(binary, "d\r");
    try t.expectCode(binary_result, 1, "refuse binary structural input");
    try t.require(!pty.terminalCaptureContains(binary_result.stdout, "Unity asset file conflict"), "binary file opened a file-choice UI");
    try expectFile(binary, old_path, ours ++ "\x00binary");
    try binary.ok(&.{ "merge", "--abort" });
}

fn mixedAndNoMetadata(ctx: Context) !void {
    const git = try ctx.repo("mixed-no-meta", .modify_delete, true, false, true);
    try t.expectCode(try runPty(git, "k\r"), 1, "resolve asset while text remains");
    try expectFile(git, old_path, theirs);
    const unmerged = try git.output(&.{ "ls-files", "-u" });
    try t.require(std.mem.indexOf(u8, unmerged, "conflict.txt") != null and std.mem.indexOf(u8, unmerged, ".prefab") == null, "mixed merge did not isolate text conflict");
    _ = try t.expectMarkers(git.io, git.arena, git.cwd, "Notes/conflict.txt");
    try git.ok(&.{ "merge", "--abort" });
    try expectAbsent(git, old_path);
}

fn noCommitAndMode(ctx: Context) !void {
    const git = try ctx.repo("no-commit-executable", .rename_delete, false, true, false);
    try git.ok(&.{ "update-index", "--chmod=+x", "--", ours_path });
    try git.ok(&.{ "commit", "-qm", "Make asset executable" });
    try git.ok(&.{ "checkout-index", "-f", "--", ours_path });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    try t.expectCode(try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "k\r", 30), 0, "structural --no-commit");
    try git.ok(&.{ "rev-parse", "--verify", "MERGE_HEAD" });
    const index = try git.output(&.{ "ls-files", "--stage", "--", ours_path });
    try t.require(std.mem.startsWith(u8, index, "100755 "), "structural keep lost executable index mode");
    if (std.Io.File.Permissions.has_executable_bit) {
        const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path(ours_path), .{});
        try t.require(stat.permissions.toMode() & 0o111 != 0, "structural keep lost executable file mode");
    }
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, ours_path, ours);
    try expectFile(git, ours_path ++ ".meta", metadata);
}

fn renameContent(ctx: Context) !void {
    for ([_]bool{ false, true }) |quit| {
        const git = try ctx.repo(if (quit) "rename-content-quit" else "rename-content-choice", .rename_rename, false, true, false);
        try git.ok(&.{ "switch", "-q", "remote" });
        const conflicting = try std.mem.replaceOwned(u8, git.arena, theirs, "m_Left: 1", "m_Left: 4");
        try write(git, theirs_path, conflicting);
        try git.ok(&.{ "add", "--", theirs_path });
        try git.ok(&.{ "commit", "-qm", "Conflicting rename content" });
        try git.ok(&.{ "switch", "-q", "local" });
        try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "prepare native rename content reference");
        const native_stages = try git.output(&.{ "ls-files", "-u", "-z" });
        const native_current = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(ours_path), git.arena, .limited(1024 * 1024));
        const native_incoming = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(theirs_path), git.arena, .limited(1024 * 1024));
        try git.ok(&.{ "merge", "--abort" });
        const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
        const output = try pty.runCommandInPtyBatches(git.io, git.arena, git.cwd, command, "b\r", if (quit) "\x1b[27uy" else "\x1b[C\r\r", 30);
        try t.expectCode(output, if (quit) 1 else 0, "rename path then content decision");
        try t.require(pty.terminalCaptureContains(output.stdout, "Unity asset file conflict"), "rename content omitted file-choice screen");
        try t.require(pty.terminalCaptureContains(output.stdout, "Result"), "rename content omitted semantic screen");
        if (quit) {
            try expectFile(git, ours_path, native_current);
            try expectFile(git, theirs_path, native_incoming);
            try t.require(std.mem.eql(u8, native_stages, try git.output(&.{ "ls-files", "-u", "-z" })), "content quit changed rename stages");
            try git.ok(&.{ "merge", "--abort" });
        } else {
            try expectFile(git, theirs_path, merged);
            try expectFile(git, theirs_path ++ ".meta", metadata);
            try expectAbsent(git, ours_path);
            try expectAbsent(git, ours_path ++ ".meta");
            try t.require((try git.output(&.{ "ls-files", "-u" })).len == 0, "rename content choice left conflict stages");
        }
    }
}

fn concurrentChanges(ctx: Context) !void {
    for ([_]enum { asset, metadata, index_lock }{ .asset, .metadata, .index_lock }) |kind| {
        const git = try ctx.repo(try std.fmt.allocPrint(ctx.git.arena, "during-ui-{s}", .{@tagName(kind)}), .modify_delete, false, false, false);
        const changed_path = switch (kind) {
            .asset => old_path,
            .metadata => old_path ++ ".meta",
            .index_lock => ".git/index.lock",
        };
        const action = try std.fmt.allocPrint(git.arena, "printf '%s' 'manual edit' > {s}", .{try t.shellQuote(git.arena, changed_path)});
        const output = try runWithUiAction(git, "d\r", "", action);
        try t.expectCode(output, 1, "refuse concurrent file/index change");
        try t.require(pty.terminalCaptureContains(output.stdout, "Unity asset file conflict"), "concurrent-change test missed the UI");
        try expectFile(git, changed_path, "manual edit");
        try t.require((try git.output(&.{ "ls-files", "-u" })).len > 0, "concurrent change cleared conflict stages");
        if (kind != .asset) try expectFile(git, old_path, ours);
        if (kind == .index_lock) {
            try std.Io.Dir.cwd().deleteFile(git.io, try git.path(changed_path));
            try git.ok(&.{ "merge", "--abort" });
        }
    }
}

fn runWithUiAction(git: merge_git.Git, keys: []const u8, second_keys: []const u8, action: []const u8) !std.process.RunResult {
    const command = try std.fmt.allocPrint(
        git.arena,
        "env PATH={s} git merge --no-edit remote",
        .{try t.shellQuote(git.arena, git.env.get("PATH").?)},
    );
    // Wait for the first UI, then finish the mutation before sending input.
    return pty.runCommandInPtyWithUiAction(
        git.io,
        git.arena,
        git.cwd,
        command,
        action,
        keys,
        second_keys,
        30,
    );
}

fn escapedPaths(ctx: Context) !void {
    const git = try ctx.repo("escaped-path", .rename_delete, false, false, false);
    const path = "Assets/Control\x1b[31m.prefab";
    try git.ok(&.{ "mv", "--", ours_path, path });
    try git.ok(&.{ "commit", "-qm", "Rename with terminal control byte" });
    const output = try runPty(git, "k\r");
    try t.expectCode(output, 0, "escaped structural path");
    try t.require(pty.terminalCaptureContains(output.stdout, "Control\\u001b[31m.prefab"), "file-choice label did not escape terminal control");
    try expectFile(git, path, ours);
}

fn crlf(ctx: Context) !void {
    const git = try ctx.repo("crlf-worktree", .rename_rename, false, true, false);
    try git.ok(&.{ "config", "core.autocrlf", "true" });
    try git.ok(&.{ "checkout-index", "-a", "-f" });
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} git merge --no-edit --no-commit remote", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    try t.expectCode(try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "b\r", 30), 0, "structural CRLF worktree");
    try expectFile(git, theirs_path, try std.mem.replaceOwned(u8, git.arena, merged, "\n", "\r\n"));
    try t.require(std.mem.eql(u8, merged, try git.output(&.{ "show", ":Assets/Incoming asset.prefab" })), "CRLF working bytes entered the canonical index blob");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, ours_path, try std.mem.replaceOwned(u8, git.arena, ours, "\n", "\r\n"));
}

fn rollback(ctx: Context) !void {
    const identity = try std.process.run(ctx.git.arena, ctx.git.io, .{ .argv = &.{ "id", "-u" } });
    // POSIX directory permissions do not block root, so this failure cannot be produced there.
    if (std.mem.eql(u8, merge_git.trim(identity.stdout), "0")) return;
    const git = try ctx.repo("rollback-after-file-write", .rename_rename, false, true, false);
    const current = "Assets/Current branch/Asset.prefab";
    const incoming = "Assets/Incoming branch/Asset.prefab";
    for ([_]bool{ false, true }) |is_current| {
        try git.ok(&.{ "switch", "-q", if (is_current) "local" else "remote" });
        const destination = if (is_current) current else incoming;
        const from = if (is_current) ours_path else theirs_path;
        try std.Io.Dir.cwd().createDirPath(git.io, try git.path(std.fs.path.dirname(destination).?));
        try git.ok(&.{ "mv", "--", from, destination });
        try git.ok(&.{ "mv", "--", try std.fmt.allocPrint(git.arena, "{s}.meta", .{from}), try std.fmt.allocPrint(git.arena, "{s}.meta", .{destination}) });
        if (!is_current) {
            try write(git, incoming, try std.mem.replaceOwned(u8, git.arena, theirs, "m_Left: 1", "m_Left: 4"));
            try git.ok(&.{ "add", "--", incoming });
        }
        try git.ok(&.{ "commit", "-qm", "Put renamed files in separate directories" });
    }
    try t.expectCode(try git.run(&.{ "merge", "--no-edit", "remote" }), 1, "prepare rollback reference");
    const stages = try git.output(&.{ "ls-files", "-u", "-z" });
    const native_current = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(current), git.arena, .limited(1024 * 1024));
    const native_incoming = try std.Io.Dir.cwd().readFileAlloc(git.io, try git.path(incoming), git.arena, .limited(1024 * 1024));
    try t.require(std.mem.indexOf(u8, native_current, "<<<<<<<") != null, "rollback fixture lacks meaningful before/after bytes");
    try git.ok(&.{ "merge", "--abort" });
    const output = try runWithUiAction(git, "a\r", "\x1b[C\r\r", "chmod a-w 'Assets/Incoming branch'");
    // Restore the test-owned directory before assertions so cleanup always succeeds.
    try std.Io.Dir.cwd().setFilePermissions(git.io, try git.path("Assets/Incoming branch"), .default_dir, .{ .follow_symlinks = false });
    try t.expectCode(output, 1, "recover from deletion failure after content write");
    try t.require(pty.terminalCaptureContains(output.stdout, "Result"), "rollback test did not complete the content UI");
    try expectFile(git, current, native_current);
    try expectFile(git, incoming, native_incoming);
    try expectFile(git, current ++ ".meta", metadata);
    try expectFile(git, incoming ++ ".meta", metadata);
    try t.require(std.mem.eql(u8, stages, try git.output(&.{ "ls-files", "-u", "-z" })), "rollback changed original conflict stages");
    try git.ok(&.{ "merge", "--abort" });
    try expectFile(git, current, ours);
}

fn metadataAutomatic(ctx: Context) !void {
    const git = try ctx.repo("metadata-clean-merge", .rename_rename, false, true, false);
    // Both metadata revisions keep the GUID and make changes separated by stable lines.
    // Git can combine them without asking for an independent metadata decision.
    try git.ok(&.{ "switch", "-q", "local" });
    const current_meta = "# Current comment\n" ++ metadata;
    try write(git, ours_path ++ ".meta", current_meta);
    try git.ok(&.{ "add", "--", ours_path ++ ".meta" });
    try git.ok(&.{ "commit", "-qm", "Current importer comment" });
    try git.ok(&.{ "switch", "-q", "remote" });
    try write(git, theirs_path ++ ".meta", metadata ++ "# Incoming comment\n");
    try git.ok(&.{ "add", "--", theirs_path ++ ".meta" });
    try git.ok(&.{ "commit", "-qm", "Incoming importer comment" });
    try git.ok(&.{ "switch", "-q", "local" });
    try t.expectCode(try runPty(git, "a\r"), 0, "retain nonconflicting metadata edits");
    try expectFile(git, ours_path, merged);
    try expectFile(git, ours_path ++ ".meta", "# Current comment\n" ++ metadata ++ "# Incoming comment\n");
    try expectAbsent(git, theirs_path ++ ".meta");
}

fn concurrentModes(ctx: Context) !void {
    const cases = [_]struct { name: []const u8, mode: []const u8, file_mode: bool, exit_code: u8, expected_mode: u32 }{
        .{ .name = "later-executable-change", .mode = "755", .file_mode = true, .exit_code = 1, .expected_mode = 0o755 },
        .{ .name = "ignored-executable-change", .mode = "755", .file_mode = false, .exit_code = 0, .expected_mode = 0o755 },
    };
    for (cases) |case| {
        var git = ctx.git;
        git.cwd = try std.fs.path.join(git.arena, &.{ ctx.scratch, case.name });
        const conflicting = try std.mem.replaceOwned(u8, git.arena, ours, "m_Left: 2", "m_Left: 4");
        try t.prepareRepository(git.io, git.arena, git.cwd, ctx.prefablens, .local, &.{
            .{ .path = "Assets/A.prefab", .base = base, .ours = ours, .theirs = conflicting },
            .{ .path = "Assets/Later.prefab", .base = base, .ours = ours, .theirs = conflicting },
        });
        try git.ok(&.{ "config", "pull.twohead", "prefablens" });
        try git.ok(&.{ "config", "core.fileMode", if (case.file_mode) "true" else "false" });
        const action = try std.fmt.allocPrint(git.arena, "chmod {s} 'Assets/Later.prefab'", .{case.mode});
        const output = try runWithUiAction(git, "\x1b[C\r\r", "\x1b[C\r\r", action);
        try t.expectCode(output, case.exit_code, case.name);
        const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path("Assets/Later.prefab"), .{});
        try t.require(stat.permissions.toMode() & 0o777 == case.expected_mode, "resolution changed captured file permissions");
        const stages = try git.output(&.{ "ls-files", "-u" });
        if (case.exit_code == 1) {
            try t.require(std.mem.indexOf(u8, stages, "Later.prefab") != null and std.mem.indexOf(u8, stages, "A.prefab") == null, "later mode change did not remain unresolved");
            _ = try t.expectMarkers(git.io, git.arena, git.cwd, "Assets/Later.prefab");
        } else {
            try expectFile(git, "Assets/Later.prefab", ours);
            try t.require(stages.len == 0, "completed mode-preserving merge left stages");
        }
    }
}

fn restoredMetadataUmask(ctx: Context) !void {
    const git = try ctx.repo("restored-meta-umask", .modify_delete, false, true, false);
    const command = try std.fmt.allocPrint(git.arena, "env PATH={s} sh -c 'umask 077; exec git merge --no-edit remote'", .{try t.shellQuote(git.arena, git.env.get("PATH").?)});
    try t.expectCode(try pty.runCommandInPty(git.io, git.arena, git.cwd, command, "k\r", 30), 0, "restore matching metadata with private umask");
    const stat = try std.Io.Dir.cwd().statFile(git.io, try git.path(old_path ++ ".meta"), .{});
    try t.require(stat.permissions.toMode() & 0o777 == 0o600, "restored sidecar bypassed the process umask");
    try expectFile(git, old_path ++ ".meta", metadata);
}
