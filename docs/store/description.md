# Chrome Web Store listing — PrefabLens

Draft copy for the store listing. The assets in this directory are the
screenshots (1280x800) and the small promo tile (440x280); none of them ship
in the extension zip.

## Short description (132 characters max)

> Semantic diffs for Unity YAML files in GitHub pull requests

(Same as the manifest `description`.)

## Detailed description

PrefabLens turns unreadable Unity YAML diffs into a structured,
Inspector-like view — right inside GitHub pull requests.

Unity serializes prefabs, scenes, and many other assets as YAML. Reviewing
changes to those files on GitHub means scrolling raw text full of fileIDs,
GUIDs, and serialization noise. PrefabLens adds a Semantic toggle to each
Unity YAML file on the Files changed tab that shows what actually changed:
GameObjects, components, and properties, with old and new values side by
side.

Features

- Semantic view for 26 Unity YAML asset types: .prefab, .unity, .asset,
  .mat, .anim, .controller, .terrainlayer, .lighting, and more
- Inspector-style tree — GameObjects, their components, then properties,
  with additions, removals, and value changes highlighted
- MonoBehaviour script names resolved from GUIDs, so script components show
  their actual class name instead of a bare GUID
- Raw / Semantic toggle per file and globally; your choice is remembered
- Sign in with the GitHub device flow straight from the PR page — no
  passwords, no separate server
- Large-file guard: oversized scenes never freeze the tab and render only
  on an explicit click

Privacy

- All diff parsing runs locally in your browser via WebAssembly
- Your GitHub token stays in local extension storage and is sent only to
  github.com and api.github.com
- No analytics, no tracking, no developer-operated server

Privacy policy:
https://github.com/hashiiiii/PrefabLens/blob/main/PRIVACY.md

Open source

PrefabLens is Apache-2.0 licensed. Source, issues, and the CLI companion
live at https://github.com/hashiiiii/PrefabLens

## Listing metadata

- Category: Developer Tools
- Language: English
- Screenshots: `screenshot-1-overview.png` (semantic view with the global
  toggle and file tree), `screenshot-2-scene-prefab.png` (scene and prefab
  diffs with property changes and script-name resolution)
- Small promo tile: `promo-tile-small.png` (source: `promo-tile-small.svg`)
