# Unity Editor package

This page is for people who change `editor/`.
For install steps and product overview, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Why

The Editor package shows semantic UnityYAML diffs inside Unity.
Authors stay in the Editor.
They do not leave for a separate CLI session for every look at a change.

The package does not reimplement git or the diff engine.
It runs the `prefablens` CLI as a child process and shows `--json` output.
All git logic stays in the CLI.
See [docs/cli.md](cli.md).

The UI resolves guids with the local `AssetDatabase`.
Script and prefab references show as project paths.
The CLI can still run its own `.meta` scan when the working directory is the
project root.

## Tech stack

| Piece | Choice |
|---|---|
| Package id | `com.hashiiiii.prefablens` (`editor/package.json`) |
| Unity minimum | 2022.3 |
| Language | C# (Unity Editor assemblies) |
| Diff engine | External `prefablens` CLI (pinned version in `Editor/Cli.cs`) |
| Headless tests | `DotNetTests~/` via `dotnet test` (Unity stubs, no Editor app) |
| In-Editor tests | `Tests/Editor/` (needs a real Unity Editor) |
| Lint / format | CSharpier (`dotnet csharpier check`) |

## Design

### Layout

| Path | Role |
|---|---|
| `editor/Editor/` | Window, CLI locate/download/run, models, settings |
| `editor/Tests/Editor/` | Unity EditMode tests |
| `editor/DotNetTests~/` | Headless harness. The trailing `~` hides it from Unity import |
| `editor/package.json` | UPM package manifest |

Important types under `Editor/`:

- `PrefabLensWindow.cs` — Window UI and refresh flow
- `Cli.cs`, `Cli.Download.cs`, `Cli.Run.cs` — locate, download, and run the CLI
- `BulkModel.cs`, `DiffModel.cs`, `DiffTree.cs` — JSON models and tree view
- `RefreshGate.cs` — one in-flight CLI run, with a queue for later Base edits
- `PrefabLensSettings.cs` — Preferences UI for the CLI path override
- `BuiltinRefs.cs`, `ValueFormat.cs` — built-in names and field text

### CLI run contract

A refresh runs:

```
prefablens [<base-ref>] --json
```

The working directory is the Unity project root.
An empty Base field means no ref operand (HEAD vs working tree, bulk mode).
The window parses a `[{path, diff}]` array.
Each `diff` uses `prefablens.diff.v2`.

CLI runs time out after 90 s.
If the window closes, the package kills an in-flight run.

### CLI binary locate and download

The pinned CLI version is `Cli.Version` in `Editor/Cli.cs`.
Release automation keeps it in sync with `editor/package.json` and
`build.zig.zon`.

Download target (relative to the project root):

`Library/PrefabLens/<version>/prefablens` (`.exe` on Windows)

`Library/` is not for version control.
The binary must not enter the repository.

On first need, the package downloads the pinned zip from GitHub Releases.
It fetches `SHA256SUMS` first and compares the zip digest before extract.
A mismatch aborts the install.
On macOS/Linux it marks the binary executable.
A failed `chmod` fails the download.
After a successful install, it deletes older cached versions under
`Library/PrefabLens/`.
The download has a 120 s cap.
The window can cancel it.

### `PrefabLens.CliPath` resolution

Preferences store an optional absolute path in EditorPrefs key
`PrefabLens.CliPath` (per machine, not per project).

Resolution order:

1. If the override is set and the file exists, the package uses the override.
2. If the override is set and the file is missing, the package uses the
   downloaded binary when that file exists. Otherwise the CLI is missing, and
   the package reports the broken override.
3. If no override is set, the package uses the downloaded binary when that file
   exists. Otherwise the CLI is missing, and the window can start a download.

The package reports a missing override in the console (once per distinct missing
path), on the missing-CLI screen, and on the Preferences page.

### Guid resolution in the UI

After JSON parse, the window resolves remaining guids with
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
cd editor
dotnet tool restore
dotnet csharpier check . --no-msbuild-check
dotnet test DotNetTests~/Tests
```

These commands do not need the Unity Editor app.

For `Tests/Editor/` EditMode tests:

1. Open the package in Unity 2022.3 or newer.
2. Run the EditMode test runner there.

For a local CLI build from the Editor:

1. Build the CLI with `zig build` at the repository root.
2. Set `PrefabLens.CliPath` to the absolute path of `zig-out/bin/prefablens`
   (add `.exe` on Windows).
3. Open **Window > PrefabLens**.
4. Refresh the window.

CI runs csharpier and `DotNetTests~/` in the `editor` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
CI does not run the in-Editor EditMode suite.

## Deploy

The Editor package ships as UPM content under `editor/` in this repository.

1. Run [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   with `workflow_dispatch` and a version `X.Y.Z` (no `v` prefix).
2. Make sure that `Cli.Version` stays aligned with the release tag (`v$VERSION`).
   The bump step updates the synced version files.

After you start the workflow, it bumps `editor/package.json` and related
version files.
It tags `v$VERSION` and publishes GitHub Release assets that the package
downloads at runtime.

OpenUPM serves `com.hashiiiii.prefablens` from this repository path `editor`.
This repository has no OpenUPM publish job.
OpenUPM tracks the package outside this workflow.

After a tag lands on `main`:

1. Make sure that the OpenUPM package page shows the new version.
2. If the page is stale, update the OpenUPM registration.
3. If you cannot update it, ask a maintainer who owns that listing.

Users can also install from the git URL with `?path=editor` (see the README).
