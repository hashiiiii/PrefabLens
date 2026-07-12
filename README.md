# PrefabLens

Semantic diff tools for UnityYAML assets. Instead of raw text diffs, PrefabLens shows changes at the GameObject, component, and field level.

Try the [live demo](https://hashiiiii.github.io/PrefabLens/) — the extension's GitHub view and the CLI's local output, running in your browser.

## Components

| Directory | Description |
|---|---|
| `core/` | Diff engine in Zig (shared by the CLI and WASM) |
| `cli/` | `prefablens` command-line tool |
| `extension/` | Chrome extension for semantic diffs on GitHub pull requests |
| `editor/` | Unity Editor package for semantic UnityYAML diffs |

## Installation

### Homebrew (macOS / Linux)

```bash
brew install hashiiiii/tap/prefablens
```

### Scoop (Windows)

```bash
scoop bucket add hashiiiii https://github.com/hashiiiii/scoop-bucket
scoop install prefablens
```

### mise

```bash
mise use -g github:hashiiiii/PrefabLens
```

### Manual

Download the zip for your platform from [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases).

## Usage

### CLI

```bash
prefablens                              # HEAD vs working tree, all changed Unity files
prefablens Assets/Foo.prefab            # HEAD vs working tree, one file
prefablens main                         # ref vs working tree, all changed Unity files
prefablens HEAD~1 HEAD Assets/Foo.prefab  # ref vs ref, one file
prefablens before.prefab after.prefab   # plain two-file compare (no git)

prefablens --json before.prefab after.prefab
prefablens --html main                  # self-contained HTML report on stdout
prefablens --open main                  # write the report to a temp file and open it
```

Operands ending in a Unity YAML extension (`.prefab`, `.unity`, `.asset`, ...) are
treated as paths; everything else is a git ref.

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
