# Demo fixtures

Before/after snapshots of four files changed in
[unity-yaml-playground#2](https://github.com/hashiiiii/unity-yaml-playground/pull/2)
(base `7682a58`, head `d7cf9b9`), generated in Unity 6000.5.2f1 by that repo's
FixtureGenerator. `before/` is the base state, `after/` the head state.

The demo deliberately shows one file per headline type — `.asset`, `.unity`,
`.prefab` — plus a prefab variant for the override view; that focus is asserted
by `build.mjs`, so adding a fixture means updating its expected file list.
`.meta` files are excluded on purpose: PrefabLens never touches them (they are
importer settings, not UnityYAML documents), so they would only show GitHub's
plain diff.

`build.mjs` turns these trees into a throwaway git repository so the demo pages
show real `prefablens` output.
