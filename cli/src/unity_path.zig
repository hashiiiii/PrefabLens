//! Suffix gate for Unity text-serialized assets (UnityYAML).
//! Keep this list aligned with UNITY_PATH in extension/src/domain/unity/fn/is-unity-path.ts so both classify the same assets.
const std = @import("std");
const testing = std.testing;

test "isUnityPath accepts every supported extension, case-insensitively" {
    // Git operands and PR file paths must use the same extension rules, including case-insensitive matching.
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
