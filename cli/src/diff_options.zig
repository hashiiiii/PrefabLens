const std = @import("std");
const testing = std.testing;
const unity_path = @import("unity_path.zig");

pub const Format = enum { tree, json, html };

pub const Target = union(enum) {
    /// Two explicit files, no git involved.
    files: struct { before: []const u8, after: []const u8 },
    /// Empty after_ref = the working tree. Null path = every changed
    /// supported file (bulk mode).
    git: struct { before_ref: []const u8, after_ref: []const u8, path: ?[]const u8 },
};

pub const Options = struct {
    target: Target = .{ .git = .{ .before_ref = "HEAD", .after_ref = "", .path = null } },
    format: Format = .tree,
    project_root: ?[]const u8 = null, // guid-resolution base and the git repo dir
    no_project: bool = false, // skip the default guid-resolution scan
    no_color: bool = false,
    force_color: bool = false,
    help: bool = false,
    version: bool = false,
    open: bool = false,
};

pub const ArgError = error{ MissingOperands, UnknownFlag, TooManyArguments, ConflictingFlags };

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var opt: Options = .{};
    var refs: [2][]const u8 = undefined;
    var n_refs: usize = 0;
    var paths: [2][]const u8 = undefined;
    var n_paths: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            opt.format = .json;
        } else if (std.mem.eql(u8, a, "--html")) {
            opt.format = .html;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opt.no_color = true;
        } else if (std.mem.eql(u8, a, "--color")) {
            opt.force_color = true;
        } else if (std.mem.eql(u8, a, "--open")) {
            opt.open = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .{ .help = true };
        } else if (std.mem.eql(u8, a, "--version")) {
            return .{ .version = true };
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return ArgError.MissingOperands;
            opt.project_root = args[i];
        } else if (std.mem.eql(u8, a, "--no-project")) {
            opt.no_project = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return ArgError.UnknownFlag;
        } else if (unity_path.isUnityPath(a)) {
            if (n_paths >= 2) return ArgError.TooManyArguments;
            paths[n_paths] = a;
            n_paths += 1;
        } else {
            if (n_refs >= 2) return ArgError.TooManyArguments;
            refs[n_refs] = a;
            n_refs += 1;
        }
    }
    if (opt.open) {
        if (opt.format == .json) return ArgError.ConflictingFlags;
        opt.format = .html;
    }
    // Naming a project root while asking to skip resolution is contradictory.
    if (opt.no_project and opt.project_root != null) return ArgError.ConflictingFlags;
    if (n_paths == 2) {
        // Plain two-file compare; mixing it with refs has no meaning.
        if (n_refs != 0) return ArgError.TooManyArguments;
        opt.target = .{ .files = .{ .before = paths[0], .after = paths[1] } };
    } else {
        opt.target = .{ .git = .{
            .before_ref = if (n_refs >= 1) refs[0] else "HEAD",
            .after_ref = if (n_refs == 2) refs[1] else "",
            .path = if (n_paths == 1) paths[0] else null,
        } };
    }
    return opt;
}

test "parseArgs: no operands = HEAD vs worktree, bulk" {
    const opt = try parseArgs(&.{});
    try testing.expectEqualStrings("HEAD", opt.target.git.before_ref);
    try testing.expectEqualStrings("", opt.target.git.after_ref);
    try testing.expectEqual(@as(?[]const u8, null), opt.target.git.path);
}

test "parseArgs: one path = HEAD vs worktree, single file" {
    const opt = try parseArgs(&.{"Assets/Foo.prefab"});
    try testing.expectEqualStrings("HEAD", opt.target.git.before_ref);
    try testing.expectEqualStrings("Assets/Foo.prefab", opt.target.git.path.?);
}

test "parseArgs: one ref = ref vs worktree, bulk" {
    const opt = try parseArgs(&.{"main"});
    try testing.expectEqualStrings("main", opt.target.git.before_ref);
    try testing.expectEqualStrings("", opt.target.git.after_ref);
    try testing.expectEqual(@as(?[]const u8, null), opt.target.git.path);
}

test "parseArgs: ref and path, order independent of flags" {
    const opt = try parseArgs(&.{ "main", "Assets/Foo.prefab", "--json" });
    try testing.expectEqualStrings("main", opt.target.git.before_ref);
    try testing.expectEqualStrings("Assets/Foo.prefab", opt.target.git.path.?);
    try testing.expectEqual(Format.json, opt.format);
}

test "parseArgs: two refs = ref vs ref, bulk" {
    const opt = try parseArgs(&.{ "main", "feat/x" });
    try testing.expectEqualStrings("main", opt.target.git.before_ref);
    try testing.expectEqualStrings("feat/x", opt.target.git.after_ref);
    try testing.expectEqual(@as(?[]const u8, null), opt.target.git.path);
}

test "parseArgs: two refs and a path" {
    const opt = try parseArgs(&.{ "HEAD~1", "HEAD", "Assets/Foo.unity" });
    try testing.expectEqualStrings("HEAD~1", opt.target.git.before_ref);
    try testing.expectEqualStrings("HEAD", opt.target.git.after_ref);
    try testing.expectEqualStrings("Assets/Foo.unity", opt.target.git.path.?);
}

test "parseArgs: two paths = plain compare, no git" {
    const opt = try parseArgs(&.{ "old.prefab", "new.prefab" });
    try testing.expectEqualStrings("old.prefab", opt.target.files.before);
    try testing.expectEqualStrings("new.prefab", opt.target.files.after);
}

test "parseArgs: excess operands are rejected" {
    // Three refs; two paths and a ref; three paths — all over the limit.
    try testing.expectError(ArgError.TooManyArguments, parseArgs(&.{ "a", "b", "c" }));
    try testing.expectError(ArgError.TooManyArguments, parseArgs(&.{ "main", "a.prefab", "b.prefab" }));
    try testing.expectError(ArgError.TooManyArguments, parseArgs(&.{ "a.prefab", "b.prefab", "c.prefab" }));
}

test "parseArgs: --help short-circuits" {
    const opt = try parseArgs(&.{ "--help", "whatever" });
    try testing.expect(opt.help);
    const short = try parseArgs(&.{"-h"});
    try testing.expect(short.help);
}

test "parseArgs: --version short-circuits" {
    // Same convention as --help: the first informational flag wins and
    // everything after it (even nonsense operands) is ignored.
    const opt = try parseArgs(&.{ "--version", "whatever" });
    try testing.expect(opt.version);
}

test "parseArgs: --no-project parses and conflicts with --project" {
    const opt = try parseArgs(&.{ "--no-project", "main" });
    try testing.expect(opt.no_project);
    try testing.expectError(ArgError.ConflictingFlags, parseArgs(&.{ "--no-project", "--project", ".", "main" }));
    try testing.expectError(ArgError.ConflictingFlags, parseArgs(&.{ "--project", ".", "--no-project", "main" }));
}

test "parseArgs: --open implies html and rejects --json" {
    const opt = try parseArgs(&.{ "--open", "main" });
    try testing.expect(opt.open);
    try testing.expectEqual(Format.html, opt.format);
    try testing.expectError(ArgError.ConflictingFlags, parseArgs(&.{ "--open", "--json", "main" }));
    try testing.expectError(ArgError.ConflictingFlags, parseArgs(&.{ "--json", "--open", "main" }));
}
