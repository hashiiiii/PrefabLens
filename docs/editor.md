# Unity Editor Package

PrefabLens adds a window for reviewing semantic diffs of changed UnityYAML assets.  
The package uses the PrefabLens CLI for Git operations and diff generation, then resolves GUID references to asset paths in Unity.

For the main product overview and other tools, see the [README](../README.md).  
For contributor workflow, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Install and Use

The package requires Unity 2022.3 or later.  
Install it through [OpenUPM](https://openupm.com/packages/com.hashiiiii.prefablens/) or add the Git URL `https://github.com/hashiiiii/PrefabLens.git?path=editor#v0.13.0` in Unity Package Manager.  
The Release workflow updates this URL to the latest release.  
Use the current URL when upgrading a Git installation.  
The [README](../README.md#unity-editor) has step-by-step installation instructions.

After installation:

1. Open **Window > PrefabLens**.
2. On first use, the package automatically downloads its pinned CLI from GitHub Releases.  
   The download needs network access and can be canceled from the window.
3. Leave **Base** empty to compare the working tree with `HEAD`, or enter a branch, tag, or commit to use as the base.
4. Select an asset in the left pane to view its semantic diff.  
   Change **Base** and press Enter, move focus out of the field, or click **Refresh** to run the comparison again.

The window refreshes when it opens or regains focus.  
It lists changed UnityYAML assets; the right pane shows the selected asset's GameObjects, components, and fields.

## Troubleshooting

### CLI Download Fails

The window shows the download error and offers a retry.  
Check network access to GitHub Releases, then click **Download from GitHub Releases**.  
To use a local executable, open **Preferences > PrefabLens** and choose the `prefablens` file (or `prefablens.exe` on Windows).  
Clear **CLI path override** to return to the package-managed CLI.

The package stores its downloaded CLI under `Library/PrefabLens/`.  
Unity does not track `Library/` in Git.  
The override is stored in Unity's `EditorPrefs`, so it applies to the Editor on this machine rather than to the project.  
Lookup order is a valid override, the pinned CLI in `Library/PrefabLens/`, then a download.  
An override is accepted if it runs and reports a version; it does not have to match the package's pinned version.  
If an override is invalid, the package reports the reason and continues to the pinned CLI or download.  
The automatic download checks the archive against the release's `SHA256SUMS` and verifies the pinned CLI version before installing it.

### Refresh Reports an Error

The window displays the CLI's error text.  
Confirm that the Unity project is in a Git working tree and that the selected Base ref exists.  
To inspect the same comparison outside Unity, run `prefablens --json` for `HEAD` or `prefablens <base-ref> --json` from the project root.  
See the [CLI guide](cli.md) for command details.

### An Asset Does Not Appear

The window lists changed UnityYAML assets.  
Check that the asset is in the Git comparison and uses Unity's text-based YAML serialization.  
If the list is empty, the status line reports that there are no changes against the selected Base (or `HEAD` when Base is empty).

## How the Package Works

The Editor window passes `--json` to the CLI from the Unity project root.  
When Base is set, it passes the ref before `--json`.  
The CLI owns Git and diff behavior; the C# package displays its JSON result and uses Unity's `AssetDatabase` to resolve each GUID to an asset path.  
Keep new Git or semantic-diff behavior in the CLI rather than duplicating it in the Editor package.

The package code lives in `editor/Editor/`.  
`PrefabLensWindow.cs` owns the window and refresh flow, `Cli.cs` and its partial files locate, download, and run the CLI, and the model and tree-view files parse and display CLI output.  
The `DotNetTests~/` folder is hidden from Unity's asset importer and runs the Editor tests without a Unity installation.

## Contributor Checks

Install the repository toolchain from the root, then build the real native CLI binaries used by the C# checks:

```sh
mise install
mise exec -- zig build test-installation-binaries -Doptimize=ReleaseSafe
cd editor
dotnet tool restore
dotnet csharpier check . --no-msbuild-check
PREFABLENS_TEST_BIN_DIR="$PWD/../zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/../zig-out/test-alternate-bin" \
  dotnet test DotNetTests~/Tests
```

The headless test project compiles the package against small Unity API stubs and runs the C# tests with real native CLI binaries.  
It does not cover Unity's actual Editor runtime.  
For that, open the package in Unity 2022.3 or later, set `PREFABLENS_TEST_BIN_DIR` and `PREFABLENS_TEST_ALT_BIN_DIR` in the Unity process environment, then run the EditMode tests in `editor/Tests/Editor/`.

CI runs CSharpier and the headless .NET tests on Windows, macOS, and Linux.  
It does not run the EditMode tests inside Unity; see the `editor_native` and `editor` jobs in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
