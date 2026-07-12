# Demo fixtures

Before/after snapshots of the four files changed in
[unity-yaml-playground#2](https://github.com/hashiiiii/unity-yaml-playground/pull/2)
(base `7682a58`, head `d7cf9b9`), generated in Unity 6000.5.2f1 by that repo's
FixtureGenerator, re-homed under a realistic project layout (`Assets/Prefabs`,
`Assets/Scenes`, `Assets/Settings`). That layout also fixes the demo order —
paths sort as .prefab, .unity, .asset — which `build.mjs` asserts via its
`DEMO_FILES` list, so adding or moving a fixture means updating that list.

The unchanged companions (`.meta`, `.cs`, `.mat`, identical on both sides)
never show up in the diff; they exist so guid references — scripts, materials,
source prefabs — resolve to asset paths, exactly like in a real Unity project.
The CLI resolves them via `--project .`, the extension demo via the
`guids.json` index `build.mjs` derives from the same `.meta` files.

`build.mjs` turns these trees into a throwaway git repository so the demo pages
show real `prefablens` output.
