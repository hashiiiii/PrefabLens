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

## Unity Editor

<p align="center">
  <img width="924" src="docs/images/editor.png" alt="Semantic diff in the Unity Editor" />
</p>

> [!IMPORTANT]
> The package requires Unity **2022.3 or later**.

### Installation

#### OpenUPM

```bash
openupm add com.hashiiiii.prefablens
```

If you do not use [openupm-cli](https://github.com/openupm/openupm-cli), follow the scoped registry instructions on the [package page](https://openupm.com/packages/com.hashiiiii.prefablens/).

#### UPM

1. Open Unity and select `Window > Package Manager`.
2. Click the + button in the top left corner and choose `Add package from git URL....`
3. Enter the following URL: `https://github.com/hashiiiii/PrefabLens.git?path=editor`
4. Click Add to install the package.

For more details, see the [Unity manual](https://docs.unity3d.com/6000.6/Documentation/Manual/upm-ui-giturl.html).

### Usage

Open `Window > PrefabLens`.

The left pane lists every UnityYAML asset that differs from the Git reference in **Base**.
If **Base** is empty, the window uses **HEAD**.

The right pane shows the semantic diff for the selected asset.

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

### Usage

#### Diff

```bash
prefablens                              # HEAD vs working tree, all changed UnityYAML files
prefablens Assets/Foo.prefab            # HEAD vs working tree, one file
prefablens main                         # ref vs working tree, all changed UnityYAML files
prefablens HEAD~1 HEAD Assets/Foo.prefab  # ref vs ref, one file
prefablens before.prefab after.prefab   # plain comparison of two files

prefablens --json before.prefab after.prefab
prefablens --open main                  # write the report to a temp file and open it
```

#### Merge

> [!IMPORTANT]
> PrefabLens uses Git **2.39 or later** to resolve UnityYAML conflicts during `git merge`.

Choose a setup scope:

| Command                            | Attributes             | Git configuration |
| ---------------------------------- | ---------------------- | ----------------- |
| `prefablens setup-merge --project` | `.gitattributes`       | Current clone     |
| `prefablens setup-merge --local`   | `.git/info/attributes` | Current clone     |
| `prefablens setup-merge --user`    | User attributes file   | Global            |

> [!NOTE]
> Without a flag, `prefablens setup-merge` uses `--local`.

Use the normal merge command:

```bash
git merge origin/main
```

https://github.com/user-attachments/assets/5a89e4d8-2d0b-493c-adc6-062154a36417

## Development

Install [mise](https://mise.jdx.dev/).
Install the toolchain from the repository root:

```bash
mise install
```

### Folder structure

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
zig build
zig build wasm
zig build test
```

`zig build` installs the CLI and the Git strategy script to `zig-out/bin/`.
`zig build wasm` compiles `core/` to WASM for the extension and the site.
`zig build test` runs native tests for both.

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

The site build needs the CLI, the WASM module, and the extension demo bundle.

```bash
zig build
zig build wasm
(cd extension && pnpm install && pnpm run demo)
(cd site && pnpm install && pnpm test && pnpm run build)
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
