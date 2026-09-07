const std = @import("std");
const core = @import("core");
const testing = std.testing;
const diff = @import("../diff.zig");
const run = diff.run;
const writeReportFile = diff.writeReportFile;
const version = @import("build_options").version;

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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{"--help"}, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.toArrayList().items, "usage: prefablens") != null);
    try testing.expectEqual(@as(usize, 0), aw_err.toArrayList().items.len);
}

test "run: --version prints the version on stdout and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{"--version"}, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    // Exact match against the compiled-in constant: one line, nothing else,
    // so the output stays scriptable (`prefablens --version | cut -d' ' -f2`).
    const expected = try std.fmt.allocPrint(arena, "prefablens {s}\n", .{version});
    try testing.expectEqualStrings(expected, aw.toArrayList().items);
    try testing.expectEqual(@as(usize, 0), aw_err.toArrayList().items.len);
}

test "run: --help documents --version" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{"--help"}, &aw.writer, &aw_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, aw.toArrayList().items, "--version") != null);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ before_path, after_path }, &aw.writer, &aw_err.writer, true, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);

    // --no-color forces it off even though color=true was passed in.
    var aw2 = std.Io.Writer.Allocating.init(arena);
    var aw_err2 = std.Io.Writer.Allocating.init(arena);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--color", before_path, after_path }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);

    // --no-color still wins when both flags are given.
    var aw2 = std.Io.Writer.Allocating.init(arena);
    var aw_err2 = std.Io.Writer.Allocating.init(arena);
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
    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--no-color", "--project", dir, empty_path, variant_path }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "Scale: (1, 2, 1)") != null);

    // Without --project: stays a degraded display (enumeration of recorded overrides).
    var aw2 = std.Io.Writer.Allocating.init(arena);
    var aw_err2 = std.Io.Writer.Allocating.init(arena);
    const code2 = try run(testing.io, arena, &.{ "--no-color", empty_path, variant_path }, &aw2.writer, &aw_err2.writer, false, null);
    const output2 = aw2.toArrayList();
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expect(std.mem.indexOf(u8, output2.items, "Scale.y: 2") != null);
}

/// Lockstep with the release tag v<version>. The single source is build.zig.zon (release.yml bumps it).
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

    var aw = std.Io.Writer.Allocating.init(arena);
    var aw_err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--json", "--project", dir, "HEAD", "Foo.asset" }, &aw.writer, &aw_err.writer, false, null);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"2\"") != null);
}
