const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const testing = std.testing;
const options = @import("diff_options.zig");
const resolve = @import("resolve.zig");
const input = @import("input.zig");
const render_tree = @import("render_tree.zig");
const render_html = @import("render_html.zig");
const unity_path = @import("unity_path.zig");
const builtin_refs = @import("builtin_refs.zig");
const merge_setup = @import("merge_setup.zig");
const version = @import("build_options").version;
const Format = options.Format;
const Target = options.Target;
const Options = options.Options;
const ArgError = options.ArgError;

test {
    _ = options;
    _ = @import("testing/diff.zig");
}

const usage_line = "usage: prefablens [--json|--html] [--open] [--project DIR|--no-project] [--color|--no-color] [<ref>] [<ref>] [<path>] | <before> <after>\n";

const help_text = usage_line ++ "\nGit merge setup: " ++ merge_setup.usage ++ "\n" ++
    \\  --project              Share .gitattributes; configure the current clone
    \\  --local                Configure the current clone (default)
    \\  --user                 Configure all your repositories with global settings
    \\
    \\Operands ending in a Unity YAML extension (.prefab, .unity, .asset, ...)
    \\are paths; anything else is a git ref.
    \\
    \\  (no operands)          HEAD vs working tree, all changed Unity files
    \\  <path>                 HEAD vs working tree, one file
    \\  <ref> [<path>]         ref vs working tree
    \\  <ref> <ref> [<path>]   ref vs ref
    \\  <before> <after>       compare two files directly (no git)
    \\
    \\options:
    \\  --json         prefablens.diff.v2 JSON ({path, diff} array in bulk mode)
    \\  --html         self-contained HTML report on stdout
    \\  --open         write the HTML report to a temp file and open it in a browser
    \\  --project DIR  Unity project root; git uses its containing repository;
    \\                 git mode resolves against the repository root by default
    \\  --no-project   skip the default guid-resolution scan
    \\  --color        force ANSI colors when stdout is not a TTY (e.g. piping)
    \\  --no-color     disable ANSI colors (overrides TTY detection and --color)
    \\  --version      print the version and exit
    \\  -h, --help     show this help
    \\
;

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(input.max_input_bytes));
}

/// Writes the report under `dir` with a collision-resistant name and
/// returns the full path.
pub fn writeReportFile(io: std.Io, arena: std.mem.Allocator, dir: []const u8, name_stem: []const u8, html: []const u8) ![]const u8 {
    // Zig 0.16 clocks go through Io: no std.time.milliTimestamp anymore.
    const millis: u64 = @intCast(std.Io.Clock.now(.real, io).toMilliseconds());
    const path = try std.fmt.allocPrint(arena, "{s}/prefablens-{s}-{d}.html", .{ dir, name_stem, millis });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = html });
    return path;
}

fn openInBrowser(io: std.Io, arena: std.mem.Allocator, path: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", path },
        .windows => &.{ "cmd", "/c", "start", "", path },
        else => &.{ "xdg-open", path },
    };
    const res = try std.process.run(arena, io, .{ .argv = argv });
    if (res.term != .exited or res.term.exited != 0) return error.OpenFailed;
}

const model = core.model;

/// Bytes ride along so the lazy default resolution can re-diff files whose
/// source prefabs only become loadable once the index exists.
const NamedDiff = struct { path: ?[]const u8, before: []const u8, after: []const u8, res: model.DiffResult };

/// Diff one before/after pair, satisfying needed_sources from the project
/// index when available (nested sources raise new requests, so up to 3
/// rounds; stop if there's no progress). Index paths are project-relative,
/// so source reads join them with `project_root`.
fn diffOne(
    io: std.Io,
    arena: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    idx: ?*core.json.Resolver,
    assets: *core.Assets,
    project_root: []const u8,
) !model.DiffResult {
    var res = try core.diffBytesWithAssets(arena, before, after, assets);
    if (idx) |index| {
        var rounds: usize = 0;
        while (res.needed_sources.len != 0 and rounds < 3) : (rounds += 1) {
            var progressed = false;
            for (res.needed_sources) |ns| {
                if (assets.contains(ns.guid)) continue;
                const path = index.get(ns.guid) orelse continue;
                const full = try std.fs.path.join(arena, &.{ project_root, path });
                const bytes = readFile(io, arena, full) catch continue;
                try assets.put(arena, ns.guid, bytes);
                progressed = true;
            }
            if (!progressed) break;
            res = try core.diffBytesWithAssets(arena, before, after, assets);
        }
    }
    return res;
}

/// Looks up an environment variable, treating a set-but-empty value the same as unset.
/// Some shells/CI configs export TMPDIR="" rather than leaving it undefined, and an empty
/// directory string would otherwise win the `orelse` fallback chain below with a bogus path.
fn envDir(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

test "envDir treats a set-but-empty variable as unset and falls through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(arena);
    try env.put("TMPDIR", "");
    try env.put("TEMP", "/tmp/real");

    try testing.expectEqual(@as(?[]const u8, null), envDir(&env, "TMPDIR"));
    try testing.expectEqualStrings("/tmp/real", envDir(&env, "TEMP").?);
    // The same fallback chain run() uses: empty TMPDIR must not win over TEMP.
    try testing.expectEqualStrings("/tmp/real", envDir(&env, "TMPDIR") orelse envDir(&env, "TEMP") orelse "/tmp");
    // A key missing from the map entirely also falls through to "/tmp".
    try testing.expectEqualStrings("/tmp", envDir(&env, "NOPE") orelse "/tmp");
}

/// Runs `git show <ref>:<path>`, printing the one-line error and returning
/// null when it fails (the caller exits 1).
fn gitShowOrReport(io: std.Io, arena: std.mem.Allocator, repo_dir: []const u8, ref: []const u8, path: []const u8, stderr: *std.Io.Writer) !?[]u8 {
    return input.showAtRef(io, arena, repo_dir, ref, path, input.default_git_timeout) catch |err| {
        if (err == error.GitTimeout)
            try stderr.print("error: git timed out for '{s}:{s}'\n", .{ ref, path })
        else
            try stderr.print("error: git show failed for '{s}:{s}'\n", .{ ref, path });
        return null;
    };
}

/// What target collection hands back to run(): the diffs to render, or the
/// exit code to return right away (the message is already written).
const Collected = union(enum) { diffs: []NamedDiff, exit: u8 };

/// Collects the single diff for an explicit two-file compare.
fn collectFileDiffs(
    io: std.Io,
    arena: std.mem.Allocator,
    f: @FieldType(Target, "files"),
    resolver: ?*core.json.Resolver,
    assets: *core.Assets,
    project_root: []const u8,
    stderr: *std.Io.Writer,
) !Collected {
    const before = readFile(io, arena, f.before) catch {
        try stderr.print("error: cannot read file '{s}'\n", .{f.before});
        return .{ .exit = 1 };
    };
    const after = readFile(io, arena, f.after) catch {
        try stderr.print("error: cannot read file '{s}'\n", .{f.after});
        return .{ .exit = 1 };
    };
    const res = diffOne(io, arena, before, after, resolver, assets, project_root) catch |err| return .{ .exit = try diffError(stderr, err) };
    var diffs: std.ArrayList(NamedDiff) = .empty;
    try diffs.append(arena, .{ .path = null, .before = before, .after = after, .res = res });
    return .{ .diffs = diffs.items };
}

/// Collects one diff per changed path between two git refs (or a ref and the
/// working tree). Explicit paths yield exactly one; bulk mode sniffs away
/// binary files and may exit early with no diffs at all.
fn collectGitDiffs(
    io: std.Io,
    arena: std.mem.Allocator,
    g: @FieldType(Target, "git"),
    format: Format,
    resolver: ?*core.json.Resolver,
    assets: *core.Assets,
    repo_dir: []const u8,
    project_root: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Collected {
    // Built as a list (not `&.{p}`) so the single-path case doesn't
    // take the address of a temporary array literal.
    var path_list: std.ArrayList([]const u8) = .empty;
    if (g.path) |p| {
        try path_list.append(arena, p);
    } else {
        const all = input.changedPaths(io, arena, repo_dir, g.before_ref, g.after_ref, input.default_git_timeout) catch |err| {
            if (err == error.GitTimeout)
                try stderr.writeAll("error: git timed out listing changed files\n")
            else
                try stderr.print("error: git diff failed for '{s}'\n", .{g.before_ref});
            return .{ .exit = 1 };
        };
        for (all) |p| if (unity_path.isUnityPath(p)) try path_list.append(arena, p);
    }
    var diffs: std.ArrayList(NamedDiff) = .empty;
    for (path_list.items) |p| {
        const before = try gitShowOrReport(io, arena, repo_dir, g.before_ref, p, stderr) orelse return .{ .exit = 1 };
        const after = if (g.after_ref.len == 0)
            // One ref = comparison against the working tree (a
            // missing file is deletion = empty side).
            input.readWorktree(io, arena, repo_dir, p) catch {
                try stderr.print("error: cannot read file '{s}'\n", .{p});
                return .{ .exit = 1 };
            }
        else
            try gitShowOrReport(io, arena, repo_dir, g.after_ref, p, stderr) orelse return .{ .exit = 1 };
        // Bulk mode trusts content over extension: some .asset files
        // are binary regardless of Force Text and would render as an
        // empty diff. An explicit path operand is never second-guessed.
        if (g.path == null and !core.isUnityYaml(before) and !core.isUnityYaml(after)) continue;
        const res = diffOne(io, arena, before, after, resolver, assets, project_root) catch |err| return .{ .exit = try diffError(stderr, err) };
        // Single explicit path keeps the headerless single-file output.
        try diffs.append(arena, .{ .path = if (g.path != null) null else p, .before = before, .after = after, .res = res });
    }
    // No candidates listed, or every one sniffed away (binary .asset):
    // one exit for both, honoring --json's array contract. Explicit
    // paths and .files always append, so only bulk mode gets here.
    if (diffs.items.len == 0) {
        if (format == .json) try stdout.writeAll("[]\n") else try stdout.writeAll("no Unity YAML changes\n");
        return .{ .exit = 0 };
    }
    return .{ .diffs = diffs.items };
}

/// Prints diff.v2 JSON: a bare object for the single headerless diff, a
/// {path, diff} array otherwise.
fn emitJson(arena: std.mem.Allocator, stdout: *std.Io.Writer, diffs: []const NamedDiff, resolver: ?*core.json.Resolver) !void {
    if (diffs.len == 1 and diffs[0].path == null) {
        const out = try core.json.serialize(arena, diffs[0].res, resolver);
        try stdout.writeAll(out);
        try stdout.writeByte('\n');
    } else {
        try stdout.writeByte('[');
        for (diffs, 0..) |d, i| {
            if (i != 0) try stdout.writeByte(',');
            try stdout.writeAll("{\"path\":");
            try core.json.writeJsonString(stdout, d.path.?);
            try stdout.writeAll(",\"diff\":");
            try stdout.writeAll(try core.json.serialize(arena, d.res, resolver));
            try stdout.writeByte('}');
        }
        try stdout.writeAll("]\n");
    }
}

/// Renders every diff as a tree; bulk mode prefixes each with its path
/// (bold when colored).
fn emitTree(arena: std.mem.Allocator, stdout: *std.Io.Writer, diffs: []const NamedDiff, resolver: ?*core.json.Resolver, use_color: bool) !void {
    for (diffs, 0..) |d, i| {
        if (d.path) |p| {
            if (i != 0) try stdout.writeByte('\n');
            if (use_color) try stdout.writeAll(render_tree.Color.bold);
            try stdout.print("{s}\n", .{p});
            if (use_color) try stdout.writeAll(render_tree.Color.reset);
        }
        try render_tree.render(arena, stdout, d.res, resolver, use_color);
    }
}

/// Writes the HTML report to stdout, or with --open to a temp file that is
/// then launched in a browser. Returns the exit code.
fn emitHtml(
    io: std.Io,
    arena: std.mem.Allocator,
    opt: Options,
    diffs: []const NamedDiff,
    resolver: ?*core.json.Resolver,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ: ?*const std.process.Environ.Map,
) !u8 {
    var files: std.ArrayList(render_html.FileDiff) = .empty;
    for (diffs) |d| try files.append(arena, .{ .path = d.path, .res = d.res });
    if (!opt.open) {
        try render_html.render(stdout, files.items, resolver);
        return 0;
    }
    var aw = std.Io.Writer.Allocating.init(arena);
    try render_html.render(&aw.writer, files.items, resolver);
    const tmp_dir = if (environ) |env|
        envDir(env, "TMPDIR") orelse envDir(env, "TEMP") orelse "/tmp"
    else
        "/tmp";
    // Single-file reports carry the file stem; bulk mode is just "report".
    const stem = switch (opt.target) {
        .files => |f| std.fs.path.stem(f.after),
        .git => |g| if (g.path) |p| std.fs.path.stem(p) else "report",
    };
    const report = writeReportFile(io, arena, tmp_dir, stem, aw.toArrayList().items) catch {
        try stderr.print("error: cannot write report to '{s}'\n", .{tmp_dir});
        return 1;
    };
    try stdout.print("{s}\n", .{report});
    openInBrowser(io, arena, report) catch {
        // The path is already printed; failing to launch a
        // browser must not fail the diff.
        try stderr.print("warning: could not open a browser for '{s}'\n", .{report});
    };
    return 0;
}

pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, color: bool, environ: ?*const std.process.Environ.Map) !u8 {
    const opt = options.parseArgs(args) catch |err| {
        switch (err) {
            ArgError.MissingOperands => try stderr.writeAll(usage_line),
            ArgError.UnknownFlag => try stderr.writeAll("error: unknown flag (see --help)\n"),
            ArgError.TooManyArguments => try stderr.writeAll("error: too many arguments (see --help)\n"),
            ArgError.ConflictingFlags => try stderr.writeAll("error: conflicting flags (see --help)\n"),
        }
        return 2;
    };
    if (opt.help) {
        try stdout.writeAll(help_text);
        return 0;
    }
    if (opt.version) {
        try stdout.print("prefablens {s}\n", .{version});
        return 0;
    }

    // Git paths are repository-relative even when --project selects a nested Unity project.
    // Keep source loading relative to that project and preserve Git's errors if discovery fails.
    const start_dir = opt.project_root orelse ".";
    const repo_dir = switch (opt.target) {
        .git => input.repoRoot(io, arena, start_dir, input.default_git_timeout) catch start_dir,
        .files => start_dir,
    };
    const project_root = opt.project_root orelse repo_dir;
    var resolver_ptr: ?*core.json.Resolver = null;
    var idx: core.json.Resolver = undefined;
    if (opt.project_root) |proj| {
        idx = resolve.buildIndex(io, arena, proj) catch {
            try stderr.print("error: cannot read project directory '{s}'\n", .{proj});
            return 1;
        };
        resolver_ptr = &idx;
    }
    var assets: core.Assets = .empty;

    // Collect (path, before, after) triples for every diff target.
    const collected = switch (opt.target) {
        .files => |f| try collectFileDiffs(io, arena, f, resolver_ptr, &assets, project_root, stderr),
        .git => |g| try collectGitDiffs(io, arena, g, opt.format, resolver_ptr, &assets, repo_dir, project_root, stdout, stderr),
    };
    const diffs = switch (collected) {
        .diffs => |d| d,
        .exit => |code| return code,
    };

    // Default guid resolution: with no --project and no --no-project, git mode
    // resolves against the repository root — but only after the diffs prove
    // there is something to resolve, so ref-free changes cost nothing. Built-in
    // refs display by name without any .meta, so they neither trigger a scan
    // nor keep its early exit waiting. A failed or empty scan degrades to the
    // unresolved output, "--project" hint included.
    if (resolver_ptr == null and !opt.no_project and opt.target == .git) {
        const wanted = try wantedGuids(arena, diffs);
        if (wanted.len != 0) scan: {
            const built = resolve.buildIndexFor(io, arena, repo_dir, wanted) catch break :scan;
            if (built.count() == 0) break :scan;
            idx = built;
            resolver_ptr = &idx;
            // Source prefabs only became loadable with the index in hand:
            // re-diff just the files still asking for them.
            for (diffs) |*d| {
                if (d.res.needed_sources.len == 0) continue;
                d.res = diffOne(io, arena, d.before, d.after, resolver_ptr, &assets, repo_dir) catch d.res;
            }
        }
    }

    switch (opt.format) {
        .json => try emitJson(arena, stdout, diffs, resolver_ptr),
        // Color when stdout is a TTY is decided in main(); --color forces it on
        // for pipes, and --no-color wins over both.
        .tree => try emitTree(arena, stdout, diffs, resolver_ptr, (color or opt.force_color) and !opt.no_color),
        .html => return emitHtml(io, arena, opt, diffs, resolver_ptr, stdout, stderr, environ),
    }
    return 0;
}

/// guids the default scan should look for: every unresolved reference and
/// needed source across `diffs`, deduplicated, minus built-ins (those resolve
/// by name and never correspond to a .meta, so waiting on them would defeat
/// the scan's early exit).
fn wantedGuids(arena: std.mem.Allocator, diffs: []const NamedDiff) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var wanted: std.ArrayList([]const u8) = .empty;
    for (diffs) |d| {
        for (d.res.unresolved_guids) |g| {
            if (builtin_refs.isBuiltinGuid(g)) continue;
            const gop = try seen.getOrPut(arena, g);
            if (!gop.found_existing) try wanted.append(arena, g);
        }
        for (d.res.needed_sources) |ns| {
            if (builtin_refs.isBuiltinGuid(ns.guid)) continue;
            const gop = try seen.getOrPut(arena, ns.guid);
            if (!gop.found_existing) try wanted.append(arena, ns.guid);
        }
    }
    return wanted.items;
}

test "wantedGuids dedups across files and excludes built-ins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two files referencing the same script, one also holding a built-in ref:
    // the scan target must be exactly one guid.
    const yaml_a =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  m_Mesh: {fileID: 10202, guid: 0000000000000000e000000000000000, type: 0}
        \\  hp: 1
    ;
    const yaml_b =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  hp: 2
    ;
    const res_a = try core.diffBytes(arena, "", yaml_a);
    const res_b = try core.diffBytes(arena, yaml_b, yaml_a);
    const wanted = try wantedGuids(arena, &.{
        .{ .path = "a", .before = "", .after = yaml_a, .res = res_a },
        .{ .path = "b", .before = yaml_b, .after = yaml_a, .res = res_b },
    });
    try testing.expectEqual(@as(usize, 1), wanted.len);
    try testing.expectEqualStrings("abc123", wanted[0]);
}

/// Maps anticipated diff failures to the one-line stderr contract and exit
/// code 1. Anything else is a prefablens bug, not a user mistake, so it
/// deliberately propagates and crashes with an error trace: the trace is the
/// bug report, and a polite message would only hide it. The `try
/// stderr.print` paths follow the same rule for write failures.
fn diffError(stderr: *std.Io.Writer, err: anyerror) !u8 {
    if (err == error.NestingTooDeep) {
        try stderr.writeAll("error: input nested too deeply\n");
        return 1;
    }
    return err;
}
