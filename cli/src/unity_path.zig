//! Suffix gate for Unity text-serialized assets (UnityYAML).
//! Mirrors extension/src/unity.ts UNITY_PATH — keep both lists in sync.
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

// Same set as unityyamlmerge targets. Excludes .meta (not !u! document
// format) and JSON like .asmdef.
const extensions = [_][]const u8{
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
