const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const testing = std.testing;

pub const resolve = @import("resolve.zig");
pub const input = @import("input.zig");
pub const display = @import("display.zig");
pub const render_tree = @import("render_tree.zig");
pub const render_html = @import("render_html.zig");
const unity_path = @import("unity_path.zig");
const builtin_refs = @import("builtin_refs.zig");

test {
    std.testing.refAllDecls(@This());
    _ = resolve;
    _ = input;
    _ = display;
    _ = render_tree;
    _ = render_html;
    _ = unity_path;
    _ = builtin_refs;
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

test "writeReportFile writes the html into the given directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const path = try writeReportFile(testing.io, arena, dir, "Robot", "<!DOCTYPE html>x");
    try testing.expect(std.mem.indexOf(u8, path, "prefablens-Robot-") != null);
    try testing.expect(std.mem.endsWith(u8, path, ".html"));
    const back = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1024));
    try testing.expectEqualStrings("<!DOCTYPE html>x", back);
}

test "run: bulk mode diffs every changed Unity file and skips others" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    // MonoBehaviour with a plain multi-char field, like the other run() fixtures
    // in this file: a bare single-letter field (e.g. "x") is deliberately left
    // lowercase by the nicifier (core/src/inspector.zig mirrors Unity's
    // Inspector, which leaves vector components x/y/z/w alone), so it would not
    // exercise the label capitalization this assertion is meant to check.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  hp: 1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Note.txt", .data = "n1\n" });
    try gitInit(arena, dir); // helper shared with the existing --project git tests
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  hp: 2\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Note.txt", .data = "n2\n" });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    // No operands: HEAD vs worktree over all changed supported files.
    const code = try run(testing.io, arena, &.{ "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    const text = aw.toArrayList().items;
    // The Unity file appears as a header; the text file is filtered out.
    try testing.expect(std.mem.indexOf(u8, text, "Foo.prefab") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Note.txt") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Hp: 1 → 2") != null);
}

test "run: bulk mode with no matching files reports and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Note.txt", .data = "n1\n" });
    try gitInit(arena, dir);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{ "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.toArrayList().items, "no Unity YAML changes") != null);
}

test "run: bulk mode skips files whose content is not UnityYAML" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    // Fake.asset passes the extension gate but is binary on both sides, like a
    // LightingDataAsset: the content sniff must drop it, not render an empty diff.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  hp: 1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v1" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  hp: 2\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v2" });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{ "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "Foo.prefab") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Fake.asset") == null);
}

test "run: bulk mode reports when every candidate fails the content sniff" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v1" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v2" });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{ "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    // Same wording as the "no candidates at all" early exit: to the user both
    // cases mean the same thing.
    try testing.expect(std.mem.indexOf(u8, aw.toArrayList().items, "no Unity YAML changes") != null);
}

test "run: bulk json keeps the array contract when the sniff empties the list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v1" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Fake.asset", .data = "\x00\x01binary-v2" });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    // A json consumer must always get an array on exit 0, never prose.
    const code = try run(testing.io, arena, &.{ "--project", dir, "--json" }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("[]\n", aw.toArrayList().items);
}

test "run: bulk json emits an array of path/diff objects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!4 &4\nTransform:\n  x: 1\n" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.prefab", .data = "--- !u!4 &4\nTransform:\n  x: 2\n" });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{ "--json", "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.startsWith(u8, text, "["));
    try testing.expect(std.mem.indexOf(u8, text, "\"path\":\"Foo.prefab\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"prefablens.diff.v2\"") != null);
}

test "run: --help prints usage on stdout and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{"--help"}, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.toArrayList().items, "usage: prefablens") != null);
    try testing.expectEqual(@as(usize, 0), aw_err.toArrayList().items.len);
}

test "run: no operands in a repo with no commits fails with a git error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    // git init with no commit: HEAD is unborn, so `git diff HEAD` fails --
    // this exercises the same GitDiffFailed path a non-repo would, without
    // depending on the tmp dir falling outside any enclosing git repository
    // (testing.tmpDir lives under this worktree's .zig-cache, which git init
    // shadows with a nested repo).
    const r = try std.process.run(arena, testing.io, .{ .argv = &.{ "git", "init", "-q" }, .cwd = .{ .path = dir } });
    try testing.expect(r.term == .exited and r.term.exited == 0);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var err_out: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &err_out);
    const code = try run(testing.io, arena, &.{ "--project", dir }, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, aw_err.toArrayList().items, "git diff failed") != null);
}

test "run: --json with two real files prints core JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Write fixtures into a temp dir.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"schema\":\"prefablens.diff.v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"0.8\"") != null);
}

test "run: unreadable input file reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "/no/such/file.asset", "/no/such/other.asset" }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read file '/no/such/file.asset'\n", err_output.items);
}

test "run: hostile deeply-nested input reports a clean error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a before file whose value is nested far past any sane bound.
    const depth = 5000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "--- !u!114 &1\nMonoBehaviour:\n  m_Field: ");
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.appendSlice(arena, "{a: ");
    try src.appendSlice(arena, "1");
    i = 0;
    while (i < depth) : (i += 1) try src.append(arena, '}');

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hostile.asset", .data = src.items });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Field: 1
    });
    const hostile_path = try tmp.dir.realPathFileAlloc(testing.io, "hostile.asset", arena);
    const other_path = try tmp.dir.realPathFileAlloc(testing.io, "other.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ hostile_path, other_path }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: input nested too deeply\n", err_output.items);
}

test "run: unreadable --project directory reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
}

test "run: unreadable --project directory reports error and exits 1 in tree mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    // No --json: the default tree format must honor the same error contract.
    const code = try run(testing.io, arena, &.{ "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
}

test "run: unreadable --project directory reports error and exits 1 in html mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real, readable input files so only the project directory is at fault.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--html", "--project", "/no/such/project", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: cannot read project directory '/no/such/project'\n", err_output.items);
}

test "run: bad ref reports error and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Whether the test cwd is a git repo (bad revision) or not (not a repo),
    // git show fails for a bogus ref -- both must surface as a clean error.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "bogus-ref", "HEAD", "Foo.prefab" }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 1), code);
    // Exact match: one clean line, no stack trace or extra noise.
    try testing.expectEqualStrings("error: git show failed for 'bogus-ref:Foo.prefab'\n", err_output.items);
}

test "run: unknown flag prints error and exits 2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--bogus", "a.prefab", "b.prefab" }, &aw.writer, &aw_err.writer, false, null);
    const err_output = aw_err.toArrayList();
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, err_output.items, "unknown flag") != null);
}

test "run: color=true colors tree output, --no-color forces it back off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    // color=true (the TTY-detected default) paints the tree output.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ before_path, after_path }, &aw.writer, &aw_err.writer, true, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);

    // --no-color forces it off even though color=true was passed in.
    var out2: std.ArrayList(u8) = .empty;
    var aw2 = std.Io.Writer.Allocating.fromArrayList(arena, &out2);
    var errbuf2: std.ArrayList(u8) = .empty;
    var aw_err2 = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf2);
    const code2 = try run(testing.io, arena, &.{ "--no-color", before_path, after_path }, &aw2.writer, &aw_err2.writer, true, null);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "\x1b[") == null);
}

test "run: --color forces ANSI output on even when stdout is not a TTY" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.5
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.asset", .data =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  volume: 0.8
    });
    const before_path = try tmp.dir.realPathFileAlloc(testing.io, "before.asset", arena);
    const after_path = try tmp.dir.realPathFileAlloc(testing.io, "after.asset", arena);

    // color=false is the piped-stdout default; --color must paint the output anyway.
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--color", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);

    // --no-color still wins when both flags are given.
    var out2: std.ArrayList(u8) = .empty;
    var aw2 = std.Io.Writer.Allocating.fromArrayList(arena, &out2);
    var errbuf2: std.ArrayList(u8) = .empty;
    var aw_err2 = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf2);
    const code2 = try run(testing.io, arena, &.{ "--color", "--no-color", before_path, after_path }, &aw2.writer, &aw_err2.writer, false, null);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "\x1b[") == null);
}

test "run: --project supplies source prefabs for merged instance diffs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Cylinder.prefab", .data =
        \\--- !u!1 &10
        \\GameObject:
        \\  m_Name: Cyl
        \\  m_Component:
        \\  - component: {fileID: 40}
        \\--- !u!4 &40
        \\Transform:
        \\  m_GameObject: {fileID: 10}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Cylinder.prefab.meta", .data =
        \\fileFormatVersion: 2
        \\guid: 0123456789abcdef0123456789abcdef
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Variant.prefab", .data =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: 0123456789abcdef0123456789abcdef, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: 0123456789abcdef0123456789abcdef, type: 3}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.prefab", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const variant_path = try tmp.dir.realPathFileAlloc(testing.io, "Variant.prefab", arena);
    const empty_path = try tmp.dir.realPathFileAlloc(testing.io, "empty.prefab", arena);

    // With --project: supply the source for a merged display (Scale (1, 2, 1)).
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--no-color", "--project", dir, empty_path, variant_path }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "Scale: (1, 2, 1)") != null);

    // Without --project: stays a degraded display (enumeration of recorded overrides).
    var out2: std.ArrayList(u8) = .empty;
    var aw2 = std.Io.Writer.Allocating.fromArrayList(arena, &out2);
    var errbuf2: std.ArrayList(u8) = .empty;
    var aw_err2 = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf2);
    const code2 = try run(testing.io, arena, &.{ "--no-color", empty_path, variant_path }, &aw2.writer, &aw_err2.writer, false, null);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "Scale.y: 2") != null);
}

/// Lockstep with the release tag v<version>. The single source is build.zig.zon (release.yml bumps it).
pub const version = @import("build_options").version;

// Builds a one-commit repo out of everything currently in `dir`.
fn gitInit(arena: std.mem.Allocator, dir: []const u8) !void {
    const steps = [_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "t@t.t" },
        &.{ "git", "config", "user.name", "t" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-q", "-m", "first" },
    };
    for (steps) |argv| {
        const r = try std.process.run(arena, testing.io, .{ .argv = argv, .cwd = .{ .path = dir } });
        if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
    }
}

test "run: --project points git mode at a repo outside the cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Create a real git repository outside the cwd. If --project points at that repo,
    // git show succeeds (with the cwd fixed at "." it would fail).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--project", dir, "HEAD", "Foo.asset" }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"2\"") != null);
}

pub const Format = enum { tree, json, html };

pub const Target = union(enum) {
    /// Two explicit files, no git involved.
    files: struct { before: []const u8, after: []const u8 },
    /// Empty after_ref = the working tree. Null path = every changed
    /// supported file (bulk mode).
    git: struct { before_ref: []const u8, after_ref: []const u8, path: ?[]const u8 },
};

pub const Options = struct {
    target: Target,
    format: Format = .tree,
    project_root: ?[]const u8 = null, // guid-resolution base and the git repo dir
    no_project: bool = false, // skip the default guid-resolution scan
    no_color: bool = false,
    force_color: bool = false,
    help: bool = false,
    open: bool = false,
};

pub const ArgError = error{ MissingOperands, UnknownFlag, TooManyArguments, ConflictingFlags };

const usage_line = "usage: prefablens [--json|--html] [--open] [--project DIR|--no-project] [--color|--no-color] [<ref>] [<ref>] [<path>] | <before> <after>\n";

const help_text = usage_line ++
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
    \\  --project DIR  Unity project root for guid resolution (and git repo dir);
    \\                 git mode resolves against the repository root by default
    \\  --no-project   skip the default guid-resolution scan
    \\  --color        force ANSI colors on in tree output (useful when piping)
    \\  --no-color     disable ANSI colors in tree output
    \\  -h, --help     show this help
    \\
;

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var format: Format = .tree;
    var project_root: ?[]const u8 = null;
    var no_project = false;
    var no_color = false;
    var force_color = false;
    var open = false;
    var refs: [2][]const u8 = undefined;
    var n_refs: usize = 0;
    var paths: [2][]const u8 = undefined;
    var n_paths: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, a, "--html")) {
            format = .html;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, a, "--color")) {
            force_color = true;
        } else if (std.mem.eql(u8, a, "--open")) {
            open = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .{ .target = .{ .git = .{ .before_ref = "HEAD", .after_ref = "", .path = null } }, .help = true };
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return ArgError.MissingOperands;
            project_root = args[i];
        } else if (std.mem.eql(u8, a, "--no-project")) {
            no_project = true;
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
    if (open) {
        if (format == .json) return ArgError.ConflictingFlags;
        format = .html;
    }
    // Naming a project root while asking to skip resolution is contradictory.
    if (no_project and project_root != null) return ArgError.ConflictingFlags;
    if (n_paths == 2) {
        // Plain two-file compare; mixing it with refs has no meaning.
        if (n_refs != 0) return ArgError.TooManyArguments;
        return .{
            .target = .{ .files = .{ .before = paths[0], .after = paths[1] } },
            .format = format,
            .project_root = project_root,
            .no_project = no_project,
            .no_color = no_color,
            .force_color = force_color,
            .open = open,
        };
    }
    return .{
        .target = .{ .git = .{
            .before_ref = if (n_refs >= 1) refs[0] else "HEAD",
            .after_ref = if (n_refs == 2) refs[1] else "",
            .path = if (n_paths == 1) paths[0] else null,
        } },
        .format = format,
        .project_root = project_root,
        .no_project = no_project,
        .no_color = no_color,
        .force_color = force_color,
        .open = open,
    };
}

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
    repo_dir: []const u8,
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
    const res = diffOne(io, arena, before, after, resolver, assets, repo_dir) catch |err| return .{ .exit = try diffError(stderr, err) };
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
        const res = diffOne(io, arena, before, after, resolver, assets, repo_dir) catch |err| return .{ .exit = try diffError(stderr, err) };
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
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
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
    const opt = parseArgs(args) catch |err| {
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

    // --project doubles as the guid-resolution base and the git repo dir.
    // Without it, git mode anchors at the repository root: git reports changed
    // paths relative to that root, so reading them against a subdirectory cwd
    // would silently misreport every file as deleted. Failure falls back to
    // "." so the not-a-repository error surfaces through git itself below.
    const repo_dir = opt.project_root orelse switch (opt.target) {
        .git => input.repoRoot(io, arena, ".", input.default_git_timeout) catch ".",
        .files => ".",
    };
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
        .files => |f| try collectFileDiffs(io, arena, f, resolver_ptr, &assets, repo_dir, stderr),
        .git => |g| try collectGitDiffs(io, arena, g, opt.format, resolver_ptr, &assets, repo_dir, stdout, stderr),
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

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const user_args = if (args.len > 1) args[1..] else args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const color = std.Io.File.stdout().isTty(init.io) catch false;

    const code = try run(init.io, arena, user_args, stdout, stderr, color, init.environ_map);
    try stdout.flush();
    try stderr.flush();
    return code;
}
