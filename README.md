# PrefabLens

[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/PrefabLens/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/PrefabLens/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/hashiiiii/PrefabLens)](https://github.com/hashiiiii/PrefabLens/releases)
[![License](https://img.shields.io/github/license/hashiiiii/PrefabLens)](LICENSE)

[![Homebrew](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Fhashiiiii%2Fhomebrew-tap%2Fmain%2FFormula%2Fprefablens.rb&search=version%20%22(%5B%5Cd.%5D%2B)%22&replace=%241&label=homebrew)](https://github.com/hashiiiii/homebrew-tap/blob/main/Formula/prefablens.rb)
[![Scoop](https://img.shields.io/scoop/v/prefablens?bucket=https%3A%2F%2Fgithub.com%2Fhashiiiii%2Fscoop-bucket&label=scoop)](https://github.com/hashiiiii/scoop-bucket/blob/main/bucket/prefablens.json)
[![OpenUPM](https://img.shields.io/npm/v/com.hashiiiii.prefablens?registry_uri=https%3A%2F%2Fpackage.openupm.com&label=openupm)](https://openupm.com/packages/com.hashiiiii.prefablens/)
[![Chrome Web Store](https://img.shields.io/chrome-web-store/v/dlhnalbfkikchkfedfneiimadommcnip?label=chrome%20web%20store)](https://chromewebstore.google.com/detail/dlhnalbfkikchkfedfneiimadommcnip)

Semantic diff tools for UnityYAML assets. Instead of raw text diffs, PrefabLens shows changes at the GameObject, component, and field level.

Try the [live demo](https://hashiiiii.github.io/PrefabLens/) — the extension's GitHub view and the CLI's local output, running in your browser.

<p align="center">
  <img src="docs/images/top.png" alt="PrefabLens: semantic Unity prefab diffs vs raw git diff" />
</p>

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

### Chrome extension (Chrome Web Store)

Install from the [Chrome Web Store](https://chromewebstore.google.com/detail/dlhnalbfkikchkfedfneiimadommcnip).

### Unity Editor package (OpenUPM)

```bash
openupm add com.hashiiiii.prefablens
```

Without the [openupm-cli](https://github.com/openupm/openupm-cli), add the scoped registry as described on the [package page](https://openupm.com/packages/com.hashiiiii.prefablens/), or install via the Package Manager git URL: `https://github.com/hashiiiii/PrefabLens.git?path=editor`.

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

Shows semantic diffs for UnityYAML files on the GitHub pull request Files changed tab. Sign in with GitHub from the first diff panel (or the extension options page); authorization uses the GitHub device flow, so no token setup is needed.

> [!NOTE]
> The extension is currently available on github.com only.

### Unity Editor

Open `Window > PrefabLens`. The window lists every changed UnityYAML asset vs HEAD and shows the selected asset's semantic diff. The CLI binary is downloaded automatically from GitHub Releases.

## Supported files

Text-serialized Unity assets such as `.prefab`, `.unity`, `.asset`, `.mat`, `.anim`, and `.controller`. Excludes `.meta`, `.asmdef`, and other non-UnityYAML formats.

## Development

Toolchain is managed with [mise](https://mise.jdx.dev/) (Zig 0.16, Node 24, pnpm 11, .NET 10).

```bash
mise install

# Core / CLI
zig build test
zig build run -- before.prefab after.prefab

# WASM (for the extension)
zig build wasm

# Extension
cd extension && pnpm install && pnpm run build && pnpm test

# Editor (EditMode tests run on .NET, no Unity required)
cd editor && dotnet test DotNetTests~/Tests
```

## License

[Apache License 2.0](LICENSE)
