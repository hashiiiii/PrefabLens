const std = @import("std");
const builtin = @import("builtin");

pub const AttributeMode = enum { local, tracked };
const RevisionSide = enum { base, ours, theirs };

pub const FileSides = struct {
    path: []const u8,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
};

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
    try configureHermeticRepository(io, arena, repo);
    try gitOk(io, arena, repo, &.{ "config", "user.email", "prefablens-tests@example.invalid" });
    try gitOk(io, arena, repo, &.{ "config", "user.name", "PrefabLens tests" });
    try gitOk(io, arena, repo, &.{ "config", "merge.prefablens.name", "PrefabLens semantic merge" });
    const driver = try std.fmt.allocPrint(
        arena,
        "{s} merge-driver %O %A %B %P %L",
        .{try shellQuote(arena, try normalizeExecutablePathForGitShell(arena, prefablens, builtin.os.tag == .windows))},
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

pub fn configureHermeticRepository(io: std.Io, arena: std.mem.Allocator, repo: []const u8) !void {
    const empty_attributes = try std.fs.path.join(arena, &.{ repo, ".git/prefablens-global-attributes" });
    const empty_excludes = try std.fs.path.join(arena, &.{ repo, ".git/prefablens-global-excludes" });
    const disabled_hooks = try std.fs.path.join(arena, &.{ repo, ".git/prefablens-disabled-hooks" });
    try writeFile(io, arena, repo, ".git/prefablens-global-attributes", "");
    try writeFile(io, arena, repo, ".git/prefablens-global-excludes", "");

    // Exact-byte assertions require Git to ignore user line-ending and attribute settings.
    try gitOk(io, arena, repo, &.{ "config", "core.autocrlf", "false" });
    try gitOk(io, arena, repo, &.{ "config", "core.eol", "lf" });
    try gitOk(io, arena, repo, &.{ "config", "core.attributesFile", empty_attributes });
    try gitOk(io, arena, repo, &.{ "config", "core.excludesFile", empty_excludes });
    try gitOk(io, arena, repo, &.{ "config", "core.hooksPath", disabled_hooks });
    try gitOk(io, arena, repo, &.{ "config", "commit.gpgSign", "false" });
    try gitOk(io, arena, repo, &.{ "config", "merge.default", "text" });
    try gitOk(io, arena, repo, &.{ "config", "merge.conflictStyle", "merge" });
    try gitOk(io, arena, repo, &.{ "config", "rerere.enabled", "false" });
    try gitOk(io, arena, repo, &.{ "config", "rerere.autoupdate", "false" });
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

pub fn checkAttributes(io: std.Io, arena: std.mem.Allocator, repo: []const u8) !void {
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

pub fn normalizeExecutablePathForGitShell(
    arena: std.mem.Allocator,
    executable_path: []const u8,
    is_windows: bool,
) ![]const u8 {
    if (!is_windows) return executable_path;
    const normalized = try arena.alloc(u8, executable_path.len);
    for (executable_path, 0..) |byte, index| {
        normalized[index] = if (byte == '\\') '/' else byte;
    }
    return normalized;
}

pub fn writeFile(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: []const u8,
    relative: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ repo, relative });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn readFile(
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

pub fn expectMarkers(io: std.Io, arena: std.mem.Allocator, repo: []const u8, relative: []const u8) ![]const u8 {
    const bytes = try readFile(io, arena, repo, relative);
    try require(std.mem.indexOf(u8, bytes, "<<<<<<<") != null, "missing opening conflict marker");
    try require(std.mem.indexOf(u8, bytes, "=======") != null, "missing conflict separator");
    try require(std.mem.indexOf(u8, bytes, ">>>>>>>") != null, "missing closing conflict marker");
    return bytes;
}

pub fn expectStage(io: std.Io, arena: std.mem.Allocator, repo: []const u8, path: []const u8, stage: u8, expected: []const u8) !void {
    const spec = try std.fmt.allocPrint(arena, ":{d}:{s}", .{ stage, path });
    const result = try gitRun(io, arena, repo, &.{ "show", spec });
    try expectCode(result, 0, "read original index stage");
    try require(std.mem.eql(u8, result.stdout, expected), "index stage lost original source bytes");
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
