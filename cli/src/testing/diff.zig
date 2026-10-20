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

    const path = try writeReportFile(testing.io, arena, dir, "<!DOCTYPE html>x");
    try testing.expect(std.mem.indexOf(u8, path, "prefablens-") != null);
    try testing.expect(std.mem.indexOf(u8, path, "Robot") == null);
    try testing.expect(std.mem.endsWith(u8, path, ".html"));
    const back = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1024));
    try testing.expectEqualStrings("<!DOCTYPE html>x", back);

    // Same-millisecond invocations must never truncate an earlier report.
    const second_path = try writeReportFile(testing.io, arena, dir, "<!DOCTYPE html>y");
    try testing.expect(!std.mem.eql(u8, path, second_path));
    const first_again = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1024));
    try testing.expectEqualStrings("<!DOCTYPE html>x", first_again);
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

test "run: terminal output escapes controls in Git paths and read errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const unsafe_name = "bad\n\x1b[2J.prefab";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = unsafe_name, .data = "--- !u!4 &4\nTransform:\n  x: 1\n" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = unsafe_name, .data = "--- !u!4 &4\nTransform:\n  x: 2\n" });

    var stdout = std.Io.Writer.Allocating.init(arena);
    var stderr = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--project", dir }, &stdout.writer, &stderr.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    const tree = stdout.toArrayList().items;
    // Git paths may contain terminal controls, so bulk headers must escape before printing them.
    try testing.expect(std.mem.indexOfScalar(u8, tree, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, tree, "bad\\n\\u001b[2J.prefab") != null);

    stdout = std.Io.Writer.Allocating.init(arena);
    stderr = std.Io.Writer.Allocating.init(arena);
    const bad_path = "missing\n\x1b[2J.prefab";
    const error_code = try run(testing.io, arena, &.{ "--no-project", bad_path, "after.prefab" }, &stdout.writer, &stderr.writer, false, null);
    try testing.expectEqual(@as(u8, 1), error_code);
    const error_text = stderr.toArrayList().items;
    try testing.expect(std.mem.indexOfScalar(u8, error_text, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, error_text, "missing\\n\\u001b[2J.prefab") != null);
}

test "run: a changed Git symlink cannot read a prefab outside the repository" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "Repo/Assets");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "private.prefab", .data = "--- !u!1 &1\nGameObject:\n  m_Name: OUTSIDE_SENTINEL\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Repo/Assets/Linked.prefab", .data = "--- !u!1 &1\nGameObject:\n  m_Name: InRepo\n" });
    const repo = try tmp.dir.realPathFileAlloc(testing.io, "Repo", arena);
    try gitInit(arena, repo);
    try tmp.dir.deleteFile(testing.io, "Repo/Assets/Linked.prefab");
    try tmp.dir.symLink(testing.io, "../../private.prefab", "Repo/Assets/Linked.prefab", .{});

    var stdout = std.Io.Writer.Allocating.init(arena);
    var stderr = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--project", repo }, &stdout.writer, &stderr.writer, false, null);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, stdout.toArrayList().items, "OUTSIDE_SENTINEL") == null);
    try testing.expect(std.mem.indexOf(u8, stderr.toArrayList().items, "cannot read file 'Assets/Linked.prefab'") != null);
}

test "run: deeply linked GameObjects fail cleanly before recursive walks overflow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const depth = 12_000;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "before.unity", .data = try hierarchyFixture(arena, depth, false) });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "after.unity", .data = try hierarchyFixture(arena, depth, true) });
    const before = try tmp.dir.realPathFileAlloc(testing.io, "before.unity", arena);
    const after = try tmp.dir.realPathFileAlloc(testing.io, "after.unity", arena);

    var stdout = std.Io.Writer.Allocating.init(arena);
    var stderr = std.Io.Writer.Allocating.init(arena);
    // This shallow YAML graph exceeds the stack limit during tree construction, before prefab expansion can check it.
    const code = try run(testing.io, arena, &.{ "--no-project", before, after }, &stdout.writer, &stderr.writer, false, null);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqualStrings("error: object hierarchy nested too deeply\n", stderr.toArrayList().items);
    try testing.expectEqual(@as(usize, 0), stdout.toArrayList().items.len);
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

    var aw3 = std.Io.Writer.Allocating.init(arena);
    var aw_err3 = std.Io.Writer.Allocating.init(arena);
    const code3 = try run(testing.io, arena, &.{ "--color", before_path, after_path }, &aw3.writer, &aw_err3.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code3);
    try testing.expect(std.mem.indexOf(u8, aw3.toArrayList().items, "\x1b[") != null);
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

fn hierarchyFixture(arena: std.mem.Allocator, depth: usize, change_leaf: bool) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    for (1..depth + 1) |i| {
        const transform = depth + i;
        const parent = if (i == 1) 0 else transform - 1;
        const name = if (change_leaf and i == depth) "Changed" else "Object";
        try source.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "--- !u!1 &{d}\nGameObject:\n  m_Name: {s}{d}\n  m_Component:\n  - component: {{fileID: {d}}}\n",
            .{ i, name, i, transform },
        ));
        try source.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "--- !u!4 &{d}\nTransform:\n  m_GameObject: {{fileID: {d}}}\n  m_Father: {{fileID: {d}}}\n",
            .{ transform, i, parent },
        ));
    }
    return source.toOwnedSlice(arena);
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

test "run: nested --project reads modified and deleted files from the repository root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "Game/Assets");
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const project = try tmp.dir.realPathFileAlloc(testing.io, "Game", arena);

    // Git reports repository-relative paths even when the selected Unity project is nested.
    const before = "--- !u!114 &1\nMonoBehaviour:\n  hp: 1\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Foo.prefab", .data = before });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Gone.prefab", .data = before });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Foo.prefab", .data = "--- !u!114 &1\nMonoBehaviour:\n  hp: 2\n" });
    try tmp.dir.deleteFile(testing.io, "Game/Assets/Gone.prefab");

    const cases = .{
        .{ "Game/Assets/Foo.prefab", "modified", @as(?[]const u8, "2") },
        .{ "Game/Assets/Gone.prefab", "removed", @as(?[]const u8, null) },
    };
    for ([_][]const u8{ dir, project }) |selected| {
        var out = std.Io.Writer.Allocating.init(arena);
        var err = std.Io.Writer.Allocating.init(arena);
        const code = try run(testing.io, arena, &.{ "--json", "--project", selected }, &out.writer, &err.writer, false, null);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err.toArrayList().items);
        const bulk = try std.json.parseFromSlice(std.json.Value, arena, out.toArrayList().items, .{});
        try testing.expectEqual(@as(usize, 2), bulk.value.array.items.len);

        inline for (cases, 0..) |case, i| {
            const entry = bulk.value.array.items[i].object;
            try testing.expectEqualStrings(case[0], entry.get("path").?.string);
            try expectHpDiff(entry.get("diff").?, case[1], case[2]);

            // Explicit paths must share the same root as paths returned by bulk discovery.
            var single = std.Io.Writer.Allocating.init(arena);
            var single_err = std.Io.Writer.Allocating.init(arena);
            const single_code = try run(testing.io, arena, &.{ "--json", "--project", selected, "HEAD", case[0] }, &single.writer, &single_err.writer, false, null);
            try testing.expectEqual(@as(u8, 0), single_code);
            try testing.expectEqualStrings("", single_err.toArrayList().items);
            const parsed = try std.json.parseFromSlice(std.json.Value, arena, single.toArrayList().items, .{});
            try expectHpDiff(parsed.value, case[1], case[2]);
        }
    }
}

fn expectHpDiff(value: std.json.Value, status: []const u8, after: ?[]const u8) !void {
    const components = value.object.get("loose").?.array.items;
    try testing.expectEqual(@as(usize, 1), components.len);
    try testing.expectEqualStrings(status, components[0].object.get("status").?.string);
    const fields = components[0].object.get("fields").?.array.items;
    try testing.expectEqual(@as(usize, 1), fields.len);
    const field = fields[0].object;
    try testing.expectEqualStrings("Hp", field.get("path").?.string);
    try testing.expectEqualStrings(status, field.get("status").?.string);
    try testing.expectEqualStrings("1", field.get("before").?.string);
    if (after) |expected| {
        try testing.expectEqualStrings(expected, field.get("after").?.string);
    } else {
        try testing.expect(field.get("after").? == .null);
    }
}

test "run: nested --project keeps GUID resolution and source loading relative to the project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "Game/Assets");
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const project = try tmp.dir.realPathFileAlloc(testing.io, "Game", arena);

    // Source paths in the GUID index are relative to Game, while Git paths include Game/.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Cylinder.prefab", .data =
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
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Cylinder.prefab.meta", .data = "fileFormatVersion: 2\nguid: 0123456789abcdef0123456789abcdef\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Variant.prefab", .data = "" });
    try gitInit(arena, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game/Assets/Variant.prefab", .data =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 40, guid: 0123456789abcdef0123456789abcdef, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: 0123456789abcdef0123456789abcdef, type: 3}
    });

    var out = std.Io.Writer.Allocating.init(arena);
    var err = std.Io.Writer.Allocating.init(arena);
    const code = try run(testing.io, arena, &.{ "--json", "--project", project, "HEAD", "Game/Assets/Variant.prefab" }, &out.writer, &err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("", err.toArrayList().items);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out.toArrayList().items, .{});
    const resolved = parsed.value.object.get("resolved").?.object;
    try testing.expect(resolved.contains("0123456789abcdef0123456789abcdef"));
    // The resolver preserves the native separators returned by the filesystem walker.
    const expected_source = try std.fs.path.join(arena, &.{ "Assets", "Cylinder.prefab" });
    try testing.expectEqualStrings(expected_source, resolved.get("0123456789abcdef0123456789abcdef").?.string);
    try testing.expect(parsed.value.object.get("neededSources") == null);

    // Combining the recorded y override with source x/z values requires loading the actual source file.
    var tree = std.Io.Writer.Allocating.init(arena);
    var tree_err = std.Io.Writer.Allocating.init(arena);
    const tree_code = try run(testing.io, arena, &.{ "--no-color", "--project", project }, &tree.writer, &tree_err.writer, false, null);
    try testing.expectEqual(@as(u8, 0), tree_code);
    try testing.expectEqualStrings("", tree_err.toArrayList().items);
    try testing.expect(std.mem.indexOf(u8, tree.toArrayList().items, "Scale: (1, 2, 1)") != null);
}
