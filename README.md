# PrefabLens

[![License](https://img.shields.io/github/license/hashiiiii/PrefabLens)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/PrefabLens)](https://github.com/hashiiiii/PrefabLens/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/PrefabLens/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/PrefabLens/actions/workflows/ci.yml)

PrefabLens shows semantic diffs for UnityYAML assets.
It shows changes to GameObjects, components, and fields.

Use the [Chrome extension](#chrome-extension), [Unity Editor package](#unity-editor), or [CLI](#cli).
Try the [live demo](https://prefablens.hashiiiii.workers.dev/).

## Chrome extension

The extension shows semantic diffs on GitHub pull requests.
It works only on `github.com`.

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

The package requires Unity 2022.3 or later.

### Installation

Install from OpenUPM:

```bash
openupm add com.hashiiiii.prefablens
```

If you do not use [openupm-cli](https://github.com/openupm/openupm-cli), follow the scoped registry instructions on the [package page](https://openupm.com/packages/com.hashiiiii.prefablens/).
Alternatively, install the package from this Git URL in the Package Manager:

`https://github.com/hashiiiii/PrefabLens.git?path=editor`

### Usage

Open `Window > PrefabLens`.

The left pane lists every UnityYAML asset that differs from the Git reference in **Base**.
If **Base** is empty, the window uses HEAD.
The right pane shows the semantic diff for the selected asset.

The window refreshes when it gains focus.
Click **Refresh** to refresh it.

On first use, the package downloads a pinned CLI archive from GitHub Releases.
The package extracts only `prefablens` into `Library/PrefabLens/<version>/`.
On Windows, the filename is `prefablens.exe`.
Git does not track `Library/PrefabLens/`.

To use a local CLI:

1. Open Preferences > PrefabLens.
2. Set **CLI path override** to the absolute path of `prefablens`.

Alternatively, set the `PrefabLens.CliPath` EditorPrefs key to an absolute path.

The CLI must run and report its version.
A local CLI can use a version other than the pinned version.
If the override is invalid, PrefabLens uses a valid downloaded CLI or offers a download.

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

Download the ZIP archive for your platform from [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases).
Each archive contains one native `prefablens` executable and the `git-merge-prefablens` script.

Git needs the script name to select the PrefabLens merge strategy.
Git for Windows reads the script's first line (the shebang) and runs the script with `sh`.

If you replace an older manual installation on Windows, remove `git-merge-prefablens.exe`.
Git can run the old executable instead of the new script.
Scoop removes its old `git-merge-prefablens` shim during `scoop update prefablens`.

### Usage

```bash
prefablens                              # HEAD vs working tree, all changed UnityYAML files
prefablens Assets/Foo.prefab            # HEAD vs working tree, one file
prefablens main                         # ref vs working tree, all changed UnityYAML files
prefablens HEAD~1 HEAD Assets/Foo.prefab  # ref vs ref, one file
prefablens before.prefab after.prefab   # plain comparison of two files

prefablens --json before.prefab after.prefab
prefablens --html main                  # self-contained HTML report on stdout
prefablens --open main                  # write the report to a temp file and open it
```

Operands with a UnityYAML extension (`.prefab`, `.unity`, `.asset`, and more) are paths.
All other operands are Git references (refs).

### Git diff

PrefabLens can provide semantic views inside the [PrefabLens diffnav fork](https://github.com/hashiiiii/diffnav).
Git, `diffnav`, `delta`, and `prefablens` must be on `PATH` when the difftool runs.
Build the fork from its checkout before setup:

```bash
go build -o ./diffnav .
```

Place the resulting `diffnav` executable on `PATH`.
The required direct comparison and external renderer options are specific to this fork.

Register the integration for the current repository:

```bash
prefablens setup-diff
```

Use `prefablens setup-diff --user` to register it in your global Git configuration.
Setup only registers the Git configuration. It does not install or verify the required executables.

Open all changed files in one directory comparison:

```bash
git difftool --dir-diff --no-symlinks
git difftool --dir-diff --no-symlinks --cached
git difftool --dir-diff --no-symlinks HEAD~1 HEAD
```

Directory mode asks Git to prepare temporary before and after directories.
`--no-symlinks` asks Git to copy working tree files into them.
See the [Git difftool documentation](https://git-scm.com/docs/git-difftool) for its revision and directory options.

Open one session for a specific file:

```bash
git difftool --no-prompt --tool=prefablens -- Assets/Player.prefab
```

Press **v** in `diffnav` to switch between semantic and raw views.
Unsupported files and renderer errors stay available as raw diffs.
For malformed UnityYAML, the raw view also shows the renderer diagnostic.

### Git merge

PrefabLens uses Git **2.39** or later to resolve UnityYAML conflicts during `git merge`.

Install `prefablens` and the packaged `git-merge-prefablens` script on `PATH`.
The script runs `prefablens merge-strategy`.

Choose a setup scope:

| Command | Attributes | Git configuration |
| --- | --- | --- |
| `prefablens setup-merge --project` | Shared `.gitattributes` | Current clone |
| `prefablens setup-merge --local` | `.git/info/attributes` | Current clone |
| `prefablens setup-merge --user` | User attributes file | Global |

Without a flag, `prefablens setup-merge` uses `--local`.
Run local and project setup inside a Git working tree.
Outside a working tree, the command explains this requirement and suggests `--user`.

With `--project`, commit the generated `.gitattributes` to share the rules.
Each clone needs setup unless the user has already configured merge integration with `--user`.
Git does not share merge driver configuration through `.gitattributes`.

User setup works outside repositories.
It uses the global `core.attributesFile` setting or Git's default user attributes file, usually `~/.config/git/attributes`.
It selects PrefabLens as the default merge strategy in all your repositories, including repositories without Unity files.
Existing repository settings can override these user defaults.
See [setup scopes](docs/cli.md#setup-scopes) for attribute paths and precedence.

This setup keeps existing attributes and unrelated Git configuration.

Use the normal merge command:

```bash
git merge origin/main
```

PrefabLens merges independent UnityYAML changes automatically.
If a UnityYAML conflict remains, the merge UI opens when a terminal is available.

Resolve the remaining conflicts, then select **Complete**.

For array insertion conflicts, focus **Ours** or **Theirs**.
Press **Shift + T** to switch between **One side** and **Both sides**.
Use the arrow keys to choose **Ours + Theirs** or **Theirs + Ours**, then press **Enter** to apply that order.
See [collection merges](docs/collection-merge.md) for supported array behavior and unsupported collection shapes.

## Development

Install [mise](https://mise.jdx.dev/).
The toolchain uses Zig 0.16, Node 24, pnpm 12, and .NET 10.

Install the toolchain from the repository root:

```bash
mise install
```

### Repository layout

| Directory    | Description                                                        |
| ------------ | ------------------------------------------------------------------ |
| `core/`      | Zig semantic diff engine for the CLI and WASM                      |
| `cli/`       | `prefablens` CLI tool                                              |
| `extension/` | Chrome extension for semantic diffs on GitHub pull requests        |
| `editor/`    | Unity Editor package for semantic diffs                            |
| `site/`      | Live demo on Cloudflare Workers, using CLI and extension artifacts |

### Build and test

Run the commands in each code block from the repository root.

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

The extension build and test commands run `zig build wasm` when needed.

```bash
(cd extension && pnpm install && pnpm run build && pnpm test)
```

#### Unity Editor

These tests run on .NET and call the native CLI.
They do not require Unity.

```bash
zig build test-installation-binaries -Doptimize=ReleaseSafe
PREFABLENS_TEST_BIN_DIR="$PWD/zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/zig-out/test-alternate-bin" \
  dotnet test editor/DotNetTests~/Tests
```

#### Site

Before you build the site, build the CLI, WASM module, and extension demo bundle:

```bash
zig build
zig build wasm
(cd extension && pnpm run demo)
(cd site && pnpm run build)
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
