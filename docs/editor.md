# Unity Editor package

This page describes the `editor/` package for contributors.
For install steps and product overview, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Purpose

The Editor package shows semantic diffs for UnityYAML assets inside Unity.
Authors can review changes in the Editor without opening a separate CLI session for each asset.

The package does not reimplement Git or the diff engine.
It runs the `prefablens` CLI as a child process and displays its `--json` output.
The CLI owns all Git logic.
See [docs/cli.md](cli.md).

The UI resolves GUIDs with the local `AssetDatabase`.
It displays script and prefab references as project paths.
The CLI can also run its own `.meta` scan when the working directory is the
project root.

## Tech stack

| Piece | Choice |
|---|---|
| Package ID | `com.hashiiiii.prefablens` (`editor/package.json`) |
| Unity minimum | 2022.3 |
| Language | C# (Unity Editor assemblies) |
| Diff engine | External `prefablens` CLI (pinned version in `Editor/Cli.cs`) |
| Headless tests | `DotNetTests~/` via `dotnet test` (Unity stubs, no Editor app) |
| Editor tests | `Tests/Editor/` (needs a real Unity Editor) |
| Lint / format | CSharpier (`dotnet csharpier check`) |

## Design

### Layout

| Path | Role |
|---|---|
| `editor/Editor/` | Window, CLI locate/download/run, models, settings |
| `editor/Tests/Editor/` | Unity EditMode tests |
| `editor/DotNetTests~/` | Headless harness. The trailing `~` hides it from the Unity asset importer |
| `editor/package.json` | UPM package manifest |

Important types under `Editor/`:

- `PrefabLensWindow.cs`: window layout and refresh flow
- `Cli.cs`, `Cli.Download.cs`, `Cli.Run.cs`: locate, download, and run the CLI
- `BulkModel.cs`, `DiffModel.cs`, `DiffTree.cs`: JSON models and display row tree
- `DiffTreeView.cs`: UI Toolkit rows, status badges, and TreeView wiring
- `RefreshGate.cs`: one in-flight CLI run, with a queue for later Base edits
- `PrefabLensSettings.cs`: Preferences UI for the CLI path override
- `BuiltinRefs.cs`, `ValueFormat.cs`: built-in names and field text

### CLI run contract

The refresh command is:

```
prefablens [<base-ref>] --json
```

The working directory is the Unity project root.
An empty Base field omits the ref operand (HEAD vs working tree, bulk mode).
The window parses a `[{path, diff}]` array.
Each `diff` uses `prefablens.diff.v2`.

CLI runs time out after 90 s.
If the window closes, the package kills an in-flight run.

### CLI binary locate and download

The pinned CLI version is `Cli.Version` in `Editor/Cli.cs`.
Release automation keeps it in sync with `editor/package.json` and
`build.zig.zon`.

The package installs one native CLI at `Library/PrefabLens/<version>/prefablens`.
On Windows, the filename has an `.exe` suffix.

Git does not track `Library/`.
The CLI must stay outside the repository.

On first use, the package downloads the pinned ZIP from GitHub Releases.
It compares the ZIP digest with `SHA256SUMS` before extraction.
The archive must contain the exact native CLI name at its root.

The package extracts the archive into a staging directory.
It extracts only the native CLI.
On macOS and Linux, it marks the CLI as executable.
It runs `--version` from the staging directory.
The CLI must report `Cli.Version`.

After these checks pass, the package replaces the version directory.
A failed check leaves an existing cache unchanged.
After a successful install, it deletes older cached versions under
`Library/PrefabLens/`.

The download has a 120 s cap.
The window can cancel it.

### `PrefabLens.CliPath` resolution

The Preferences UI stores an optional absolute path in the EditorPrefs key
`PrefabLens.CliPath` (per machine, not per project).
This path selects the `prefablens` executable.

Resolution order:

1. If the override runs and reports a version, the package uses it.
   A manual CLI can use a version other than `Cli.Version`.
2. If the override is invalid, the package reports the cause.
   If a valid downloaded CLI exists, the package uses that CLI.
   Otherwise, the window offers the pinned download.
3. If the override is empty, the package uses a downloaded CLI that matches `Cli.Version`.
   If the CLI fails the version check, the window offers the pinned download.

During a window refresh or a Preferences update, the package checks the CLI version.
It does not run version commands during a UI repaint.

The package reports an invalid override in the console once per distinct error.
It also reports the error on the missing-CLI screen and the Preferences page.

### GUID resolution in the UI

After parsing the JSON, the window resolves remaining GUIDs with
`AssetDatabase.GUIDToAssetPath`.
Built-in engine references use `BuiltinRefs.cs`
(aligned with `cli/src/builtin_refs.zig`).

## Verification

Install the toolchain from the repository root:

```bash
mise install
```

Then run the headless Editor checks:

```bash
mise exec -- zig build test-installation-binaries -Doptimize=ReleaseSafe
cd editor
dotnet tool restore
dotnet csharpier check . --no-msbuild-check
PREFABLENS_TEST_BIN_DIR="$PWD/../zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/../zig-out/test-alternate-bin" \
  dotnet test DotNetTests~/Tests
```

The installation tests run real native commands from both directories.
The headless C# harness does not require the Unity Editor application.

To run the EditMode tests in `Tests/Editor/`:

1. Build the two native test CLIs with the build command in this section.
2. Set `PREFABLENS_TEST_BIN_DIR` and `PREFABLENS_TEST_ALT_BIN_DIR` for the Unity process.
3. Open the package in Unity 2022.3 or newer.
4. Run the EditMode test runner there.

For a local CLI build from the Editor:

Windows executable names have an `.exe` suffix.

1. Build the CLI with `zig build` at the repository root.
2. Set `PrefabLens.CliPath` to the absolute path of `zig-out/bin/prefablens`.
3. Open **Window > PrefabLens**.
4. Refresh the window.

CI runs CSharpier and `DotNetTests~/` on Windows, macOS, and Linux in the
`editor_native` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
The `editor` job reports the combined result for branch protection.
CI does not run the EditMode suite inside the Unity Editor.

## Deploy

The Editor package ships as UPM content under `editor/` in this repository.

1. Run [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   with `workflow_dispatch` and a version `X.Y.Z` (no `v` prefix).
2. Verify that `Cli.Version` stays aligned with the release tag (`v$VERSION`).
   The bump step updates the version files that must stay in sync.

The workflow updates `editor/package.json` and related version files.
It tags `v$VERSION` and publishes GitHub Release assets that the package
downloads at runtime.

OpenUPM serves `com.hashiiiii.prefablens` from the `editor` path in this repository.
This repository has no OpenUPM publish job.
OpenUPM tracks the package outside this workflow.

After a tag reaches `main`:

1. Verify that the OpenUPM package page shows the new version.
2. If the page is stale, update the OpenUPM registration.
3. If you cannot update the registration, ask the maintainer responsible for the listing.

Users can also install from the Git URL with `?path=editor` (see the README).
