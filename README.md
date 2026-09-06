# PrefabLens

[![License](https://img.shields.io/github/license/hashiiiii/PrefabLens)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/PrefabLens)](https://github.com/hashiiiii/PrefabLens/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/PrefabLens/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/PrefabLens/actions/workflows/ci.yml)

PrefabLens shows semantic diffs of UnityYAML assets.
It shows changes to GameObjects, components, and fields.

Use the [Chrome extension](#chrome-extension), [Unity Editor package](#unity-editor), or [CLI](#cli).
Try the [live demo](https://prefablens.hashiiiii.workers.dev/).

## Supported files

PrefabLens supports text-serialized Unity assets.
Supported extensions include `.prefab`, `.unity`, `.asset`, `.mat`, `.anim`, and `.controller`.
See the [CLI reference](docs/cli.md#operands-and-argument-resolution) for the full list.
PrefabLens does not support `.meta`, `.asmdef`, or other formats that are not UnityYAML.

The project must use text asset serialization.
Select `Edit > Project Settings > Editor > Asset Serialization > Force Text`.
Binary-serialized assets do not produce useful diffs.

## Chrome extension

The extension shows semantic diffs on GitHub pull requests.
It works on github.com only.

<p align="center">
  <img width="924" src="docs/images/extension.png" alt="Semantic diff in a GitHub pull request" />
</p>

Install the extension from the [Chrome Web Store](https://chromewebstore.google.com/detail/dlhnalbfkikchkfedfneiimadommcnip).

You can sign in from the diff panel with GitHub Device Flow.
You do not need to set a token.

## Unity Editor

<p align="center">
  <img width="924" src="docs/images/editor.png" alt="Semantic diff in the Unity Editor" />
</p>

The package requires Unity 2022.3 or newer.
The project must be inside a git repository.

### Installation

Install from OpenUPM:

```bash
openupm add com.hashiiiii.prefablens
```

If you do not use [openupm-cli](https://github.com/openupm/openupm-cli), follow the scoped registry instructions on the [package page](https://openupm.com/packages/com.hashiiiii.prefablens/).
Alternatively, install from this git URL in the Package Manager:

`https://github.com/hashiiiii/PrefabLens.git?path=editor`

### Usage

Open `Window > PrefabLens`.

The left pane lists every changed UnityYAML asset against the **Base** ref.
An empty **Base** ref means HEAD.
The right pane shows the semantic diff for the selected asset.

The window refreshes when it gains focus.
Click **Refresh** to refresh it manually.

On first use, the package downloads a pinned CLI archive from GitHub Releases.
The package extracts only `prefablens` into `Library/PrefabLens/`.
On Windows, the file name is `prefablens.exe`.
Git does not track this directory.

To use a local CLI:

1. Open Preferences > PrefabLens.
2. Set **CLI path override** to the absolute path of `prefablens`.

Alternatively, set the `PrefabLens.CliPath` EditorPrefs key to an absolute path.

The CLI must run and report its version.
A manual CLI can use a version other than the pinned version.
If the override is invalid, PrefabLens uses a valid downloaded CLI or offers a download.

### Troubleshooting

| Symptom                                               | What to do                                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `Download failed: …`                                  | Retry. If the retry fails, download the release zip. Then set the CLI path override.       |
| `CLI path override … is invalid. …`                   | Select a working `prefablens` executable. Or clear the CLI path override.                  |
| `prefablens exited with N` / one-line CLI error       | Check that the project is in a git repository. Check that git finishes within the timeout. |
| `Could not parse CLI output (CLI version mismatch?):` | Clear the CLI path override or update the CLI.                                             |
| `prefablens timed out after 90s and was killed`       | Check that `git status` is fast in the repository.                                         |
| Changed assets never appear                           | Switch Asset Serialization to Force Text.                                                  |

## CLI

<p align="center">
  <img width="924" src="docs/images/cli.png" alt="Semantic diff in the CLI" />
</p>

### Installation

#### Homebrew (macOS / Linux)

```bash
brew install hashiiiii/tap/prefablens
```

#### Scoop (Windows)

```bash
scoop bucket add hashiiiii https://github.com/hashiiiii/scoop-bucket
scoop install prefablens
```

#### mise

```bash
mise use -g github:hashiiiii/PrefabLens
```

#### Manual

Download the zip for your platform from [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases).
Each zip contains one native `prefablens` executable and the `git-merge-prefablens` script.

Git needs the script name to select the PrefabLens merge strategy.
Git for Windows reads the script shebang and runs the script with `sh`.

If you replace an older manual installation on Windows, remove `git-merge-prefablens.exe`.
The old executable can hide the new script.
Scoop removes its old `git-merge-prefablens` shim during `scoop update prefablens`.

### Usage

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

Operands with a UnityYAML extension (`.prefab`, `.unity`, `.asset`, and more) are paths.
All other operands are git refs.

### Git merge

PrefabLens uses Git 2.39 or later to resolve UnityYAML conflicts during `git merge`.

Install `prefablens` and the packaged `git-merge-prefablens` script on `PATH`.
The script runs `prefablens merge-strategy`.

For one clone, run:

```bash
prefablens setup-merge
```

This command adds repository-local Git configuration and UnityYAML attributes in `.git/info/attributes`.

For a team, use shared attributes instead:

```bash
prefablens setup-merge --team
```

Commit the generated `.gitattributes`.

Each clone requires this setup command once.
Setup keeps existing attributes and unrelated Git configuration.

Use the normal merge command:

```bash
git merge main
```

PrefabLens merges independent UnityYAML changes automatically.
If a UnityYAML conflict remains and a terminal is available, the merge UI opens.

Resolve the values. Then select **Complete**.

File deletion and rename conflicts offer a file choice before content resolution.
PrefabLens applies the asset choice to matching `.meta` files.
Ambiguous metadata conflicts stay unresolved.

Other file formats use normal Git merge behavior.
If other formats also conflict, those conflicts remain unresolved after PrefabLens resolves the UnityYAML conflicts.
Before Git can complete the merge, every conflict must have a resolution.
`--no-commit`, `--squash`, and `git merge --abort` remain available.
Strategy options (`-X`) require Git 2.43 or later.

If you quit or no terminal is available, unresolved text keeps Git conflict markers.
The `merge.conflictStyle` configuration and `conflict-marker-size` attribute control the markers.
Even when a line-based merge is clean, a semantic conflict can require markers.
Binary and file deletion or rename conflicts keep the normal Git file representation.

To complete the merge with another editor:

1. Resolve the conflicts with your editor.
2. Stage the resolved files with `git add`.
3. Run `git merge --continue`.

To reopen the UnityYAML content UI for one unresolved path:

```bash
git mergetool --tool=prefablens -- Assets/Prefabs/Robot.prefab
```

## Development

Install [mise](https://mise.jdx.dev/).
The toolchain is Zig 0.16, Node 24, pnpm 12, and .NET 10.

Install the toolchain from the repository root:

```bash
mise install
```

### Repository layout

| Directory    | Description                                                        |
| ------------ | ------------------------------------------------------------------ |
| `core/`      | Zig diff engine for the CLI and WASM                               |
| `cli/`       | `prefablens` CLI tool                                              |
| `extension/` | Chrome extension for semantic diffs on GitHub pull requests        |
| `editor/`    | Unity Editor package for semantic diffs                            |
| `site/`      | Live demo on Cloudflare Workers, using CLI and extension artifacts |

### Build and test

Run each code block from the repository root.

#### Core and CLI

```bash
zig build test
zig build run -- before.prefab after.prefab
```

#### WASM

Build the WASM module for the extension:

```bash
zig build wasm
```

#### Chrome extension

The build and test commands run `zig build wasm` when needed.

```bash
(cd extension && pnpm install && pnpm run build && pnpm test)
```

#### Unity Editor

These tests run on .NET with real native CLI commands and do not require Unity.

```bash
zig build test-installation-binaries -Doptimize=ReleaseSafe
PREFABLENS_TEST_BIN_DIR="$PWD/zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/zig-out/test-alternate-bin" \
  dotnet test editor/DotNetTests~/Tests
```

#### Site

First, build the CLI, WASM module, and extension demo bundle.
Run `pnpm run demo` in `extension/` to build the demo bundle.

```bash
(cd site && node build.mjs)
```

### Further reading

- [CLI](docs/cli.md)
- [Chrome extension](docs/extension.md)
- [Unity Editor package](docs/editor.md)

## Contributing

Open an issue first.
If the issue does not have the `approved` label, do not open a pull request.
Read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE)
