# PrefabLens

Semantic diff tools for UnityYAML assets. Instead of raw text diffs, PrefabLens shows changes at the GameObject, component, and field level.

## Components

| Directory | Description |
|---|---|
| `core/` | Diff engine in Zig (shared by the CLI and WASM) |
| `cli/` | `prefablens` command-line tool |
| `extension/` | Chrome extension for semantic diffs on GitHub pull requests |
| `editor/` | Unity Editor package for semantic UnityYAML diffs |

## Usage

### CLI

```bash
# Compare two files (tree output)
prefablens before.prefab after.prefab

# JSON / HTML output
prefablens --json before.prefab after.prefab
prefablens --html before.prefab after.prefab

# Compare two git revisions
prefablens --git HEAD~1 HEAD Assets/Foo.prefab

# Compare a revision against the working tree (omit afterRef)
prefablens --git HEAD Assets/Foo.prefab
```

Also runs as an MCP server: `prefablens mcp`.

### Chrome extension

Shows semantic diffs for UnityYAML files on the GitHub pull request Files changed tab. Requires a GitHub Personal Access Token (configure on the extension options page).

### Unity Editor

Open `Window > PrefabLens`, or right-click a supported asset and choose `PrefabLens: Diff vs HEAD`. The CLI binary is downloaded automatically from GitHub Releases.

## Supported files

Text-serialized Unity assets such as `.prefab`, `.unity`, `.asset`, `.mat`, `.anim`, and `.controller`. Excludes `.meta`, `.asmdef`, and other non-UnityYAML formats.

## Development

Toolchain is managed with [mise](https://mise.jdx.dev/) (Zig 0.16, Node 24, .NET 10).

```bash
mise install

# Core / CLI
zig build test
zig build run -- before.prefab after.prefab

# WASM (for the extension)
zig build wasm

# Extension
cd extension && pnpm install && pnpm run build && pnpm test
```

## License

[Apache License 2.0](LICENSE)
