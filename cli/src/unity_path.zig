//! Suffix gate for Unity text-serialized assets (UnityYAML).
//! Mirrors extension/src/domain/unity/fn/is-unity-path.ts UNITY_PATH — keep both lists in sync.
const std = @import("std");
const testing = std.testing;

test "isUnityPath accepts every supported extension, case-insensitively" {
    // One spelling per extension, plus a case-mangled sample: the git side of
    // the CLI must classify operands exactly like the extension classifies
    // PR file paths, or the two products would disagree on what is diffable.
    const yes = [_][]const u8{
        "a.prefab",             "Assets/Scenes/Main.unity", "x.asset",
        "m.mat",                "run.anim",                 "ac.controller",
        "o.overrideController", "p.physicMaterial",         "p2.physicsMaterial2D",
        "t.playable",           "am.mask",                  "b.brush",
        "f.flare",              "fs.fontsettings",          "g.guiskin",
        "gi.giparams",          "rt.renderTexture",         "sa.spriteatlas",
        "sa2.spriteatlasv2",    "tl.terrainlayer",          "mx.mixer",
        "sv.shadervariants",    "pr.preset",                "sg.signal",
        "l.lighting",           "st.scenetemplate",         "UPPER.PREFAB",
        "Mixed.Mat",
    };
    for (yes) |p| try testing.expect(isUnityPath(p));
}

test "isUnityPath rejects git refs, .meta and unknown extensions" {
    const no = [_][]const u8{
        "main",       "HEAD~1",   "feat/mutate-fixtures",
        "v0.4.0",     "Foo.meta", "Foo.prefab.meta",
        "Foo.asmdef", "Foo.txt",  "Foo",
        "prefab", // no dot: a ref named "prefab" must stay a ref
    };
    for (no) |p| try testing.expect(!isUnityPath(p));
}

fn readmeExtensions(readme: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var actual: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, readme, '\n');
    const suffix = " merge=prefablens";
    while (lines.next()) |line| {
        const normalized = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
        if (!std.mem.endsWith(u8, normalized, suffix)) continue;
        try testing.expect(std.mem.startsWith(u8, normalized, "*."));
        try actual.append(allocator, normalized[1 .. normalized.len - suffix.len]);
    }
    return actual;
}

fn expectReadmeExtensions(readme: []const u8) !void {
    var actual = try readmeExtensions(readme, testing.allocator);
    defer actual.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, extensions.len), actual.items.len);
    for (extensions, actual.items) |expected, documented| {
        try testing.expectEqualStrings(expected, documented);
    }
}

fn readmeContents() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        @import("test_options").readme_path,
        testing.allocator,
        .limited(1024 * 1024),
    );
}

fn withCrLf(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var converted: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '\r' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            try converted.appendSlice(allocator, "\r\n");
            index += 2;
        } else if (bytes[index] == '\n') {
            try converted.appendSlice(allocator, "\r\n");
            index += 1;
        } else {
            try converted.append(allocator, bytes[index]);
            index += 1;
        }
    }
    return converted.toOwnedSlice(allocator);
}

test "withCrLf keeps existing CRLF pairs" {
    // This matches a Windows checkout and prevents CRCRLF from a second conversion.
    const converted = try withCrLf("first\r\nsecond\r\n", testing.allocator);
    defer testing.allocator.free(converted);
    try testing.expectEqualStrings("first\r\nsecond\r\n", converted);
}

test "README merge attributes match the Unity extension allowlist" {
    const readme = try readmeContents();
    defer testing.allocator.free(readme);
    try expectReadmeExtensions(readme);
}

test "README merge attributes match the Unity extension allowlist with CRLF" {
    const readme = try readmeContents();
    defer testing.allocator.free(readme);
    // Windows can check out the README with CRLF, so the conversion must not add a second CR.
    const crlf = try withCrLf(readme, testing.allocator);
    defer testing.allocator.free(crlf);
    try expectReadmeExtensions(crlf);
}

// Same set as unityyamlmerge targets, i.e. the community Unity.gitattributes:
// https://github.com/gitattributes/gitattributes/blob/master/Unity.gitattributes
// Excludes .meta (not !u! document format) and JSON like .asmdef. This is a
// prefilter; content is the ground truth (core isUnityYaml).
pub const extensions = [_][]const u8{
    ".prefab",             ".unity",          ".asset",
    ".mat",                ".anim",           ".controller",
    ".overrideController", ".physicMaterial", ".physicsMaterial2D",
    ".playable",           ".mask",           ".brush",
    ".flare",              ".fontsettings",   ".guiskin",
    ".giparams",           ".renderTexture",  ".spriteatlas",
    ".spriteatlasv2",      ".terrainlayer",   ".mixer",
    ".shadervariants",     ".preset",         ".signal",
    ".lighting",           ".scenetemplate",
};

pub fn isUnityPath(path: []const u8) bool {
    for (extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}
