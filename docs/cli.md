# CLI

This page is for people who change `cli/` or the shared engine in `core/`.
For install steps and quick-start examples, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Why

`prefablens` shows semantic diffs for text-serialized Unity assets.
It shows GameObject, component, and field changes.
It does not show raw YAML line diffs.

The CLI owns git and filesystem I/O.
The shared engine in `core/` owns parse, diff, tree build, and JSON output.
The Editor package and other tools call this CLI.
They must not reimplement git logic.

The JSON contract is `prefablens.diff.v2`.
The schema stays stable unless a release notes a break on purpose.

## Tech stack

| Piece | Choice |
|---|---|
| Language | Zig 0.16 (see root `mise.toml` and `build.zig.zon`) |
| Diff engine | `core/` (also built to WASM for the extension) |
| CLI entry | `cli/src/main.zig` → binary `prefablens` |
| Version source | `build.zig.zon` (injected via `build_options`) |
| Build | `zig build` installs to `zig-out/bin/` |
| Unit tests | `zig build test` (core + CLI) |
| Lint | `zig build lint` |
| Perf gates | `zig build perf` (includes the guid-scan budget) |

## Design

### Layout

| Path | Role |
|---|---|
| `core/src/` | Parse, diff, tree, JSON (`prefablens.diff.v2`), WASM export |
| `cli/src/main.zig` | Argument parse and orchestration |
| `cli/src/input.zig` | Git subprocess I/O and file reads |
| `cli/src/resolve.zig` | `.meta` guid index scan |
| `cli/src/unity_path.zig` | Unity YAML extension detection |
| `cli/src/builtin_refs.zig` | Built-in Unity resource names |
| `cli/src/render_tree.zig`, `render_html.zig`, `display.zig` | Tree, HTML, and ANSI output |
| `cli/bin/git-merge-prefablens` | Script that runs `prefablens merge-strategy` for Git |
| `cli/pkg/` | Templates and scripts for Homebrew and Scoop |

Dependencies point from `cli/` into `core/`.
`core/` does not import `cli/`.

### Constraints

- Diff Git work uses subprocesses in `cli/src/input.zig`.
- Each input file has a size cap of 64 MiB.
- Diff Git subprocesses time out after 60 s.
- Binary-serialized assets produce an empty diff for an explicit path.
  Bulk git mode skips binary candidates after a content sniff.
- `.meta`, `.asmdef`, and other non-UnityYAML names are never path operands.
  The CLI treats them as git refs on purpose.

### Git merge integration

`prefablens setup-merge` configures one clone.
With `--team`, this command writes shared `.gitattributes` instead of `.git/info/attributes`.
One native executable and the packaged `git-merge-prefablens` script must be on `PATH`.
The script contains only this command:

```sh
#!/bin/sh
exec prefablens merge-strategy "$@"
```

Git needs the script name to select the merge strategy.
Git for Windows recognizes its shebang and starts `sh` for the script.

Before setup writes attributes or Git configuration, it checks the strategy and driver routes through Git.
Each route must reach the installed `prefablens` version.

The `git --exec-path` command prints the directory that Git searches before the other `PATH` directories.
The script must be a custom Git command on `PATH`, outside this directory.

Setup keeps existing attribute lines and unrelated configuration.
The configuration uses command names without absolute paths.
A complete upgrade does not require another setup.

Before the strategy writes merge objects, the index, or working files, it checks the installed CLI version.

If a command is missing or has a different version, reinstall the release archive.

The `pull.twohead=prefablens` configuration entry selects the strategy for ordinary two-head `git merge` commands.
The strategy uses `git merge-tree --write-tree -z --messages` and requires Git 2.39 or later.
It uses the output tree, index stages, and structured conflict types from the Git ort engine.
It also tracks conflicts that have no unmerged index entries.
Strategy options (`-X`) require Git 2.43 or later.
On older Git versions, the strategy refuses these options before it writes working files.

The strategy prepares the index.
Then it uses the Git two-tree checkout to protect local edits and untracked paths.
It writes the conflict index before any UI starts.
Only Unity YAML conflicts open a UI. Other formats keep their normal Git conflict state.

The UI includes file deletion, rename, and matching GUID metadata choices.
PrefabLens writes a file resolution only after you complete these choices.
Ambiguous paths, GUIDs, or metadata content remain unresolved.

The outer Git command owns merge commits, `MERGE_HEAD`, `--no-commit`, `--squash`, and abort.
Before the strategy can return 0, every conflict must have a resolution.
If a conflict remains after the strategy installs the merge state, it returns 1.
A failure before installation returns 2.

#### Content adapters

```text
prefablens merge-driver <base> <ours-and-output> <theirs> <path> [<marker-size>]
prefablens mergetool <base> <local> <remote> <merged>
```

| Driver argument | Git placeholder | Meaning |
| --- | --- | --- |
| `<base>` | `%O` | Common ancestor |
| `<ours-and-output>` | `%A` | Ours input and result output |
| `<theirs>` | `%B` | Theirs input |
| `<path>` | `%P` | Repository-relative path |
| `<marker-size>` | `%L` | Conflict marker width, default 7 |

The mergetool arguments map to `$BASE`, `$LOCAL`, `$REMOTE`, and `$MERGED`.
`$MERGED` contains the current working file and receives only a completed resolution.

| Command | Exit 0 | Exit 1 | Exit 2 |
| --- | --- | --- | --- |
| `merge-driver` | Complete result | Unresolved result with text markers or native binary representation | I/O failure, no write |
| `mergetool` | Result that passes all checks | User quit, no write | Startup error or failed check, no write |

The driver uses the original three inputs for Git text fallback.
The `merge.conflictStyle` configuration and `conflict-marker-size` attribute control the markers.
If the text merge is clean but semantic resolution is incomplete, the driver emits a whole-file conflict block.
Non-Unity content uses Git text or binary fallback.

The semantic plan and valid partial result stay in memory.
At startup, the mergetool reads the three original inputs.
It records a snapshot of `$MERGED`.
It does not parse the markers.
Quit, startup failure, and an interrupted UI leave the working conflict representation in place.
The user can edit it with another tool and complete the normal Git workflow.

Before PrefabLens writes a completed semantic resolution, it makes sure that these conditions are true:

1. Every atomic operation has a result.
2. Every `fileID` is unique.
3. Every Component document has a matching `m_Component` reference.
4. Every Transform `m_Father` matches the parent `m_Children` reference.
5. The hierarchy has no cycle.
6. Every internal reference points to an existing document.
7. The complete output parses as Unity YAML.
8. The current output file matches its snapshot from UI startup.

Original input files have a 64 MiB limit. Working conflict output has a separate 256 MiB limit.
The mergetool requires both standard input and standard output to be TTYs.
Without them, it returns 2 and keeps `$MERGED` unchanged. The automatic strategy instead leaves the merge unresolved.
PrefabLens writes completed output with atomic file replacement and retains existing permissions.

`diff-driver` and `difftool` remain reserved for Issue #227.
libvaxis is a CLI dependency. The core and WASM targets do not import it.

### CLI contract

Consumers (humans, the Editor package, scripts) rely on this surface.
A change to this surface needs a clear release note.

#### Synopsis

```
prefablens [--json|--html] [--open] [--project DIR|--no-project] [--color|--no-color] [<ref>] [<ref>] [<path>]
prefablens [flags] <before> <after>
```

#### Operands and argument resolution

An operand that ends in a Unity YAML extension (case-insensitive) is a **path**.
Any other operand is a **git ref**.
Flags can appear anywhere among the operands.
Among operands of the same kind, order matters.
The first ref (or path) is the before side.
The second is the after side.

| Operands | Meaning |
|---|---|
| (none) | HEAD vs working tree, all changed Unity files (bulk mode) |
| `<path>` | HEAD vs working tree, one file |
| `<ref>` | ref vs working tree, all changed Unity files |
| `<ref> <path>` | ref vs working tree, one file |
| `<ref> <ref>` | first ref (before) vs second ref (after), all changed Unity files |
| `<ref> <ref> <path>` | first ref (before) vs second ref (after), one file |
| `<before> <after>` (two paths) | plain two-file compare, no git involved |

More than two refs, more than two paths, or a mix of two paths with a ref is an
error (`too many arguments`, exit 2).

Recognized Unity YAML extensions:

`.prefab` `.unity` `.asset` `.mat` `.anim` `.controller` `.overrideController`
`.physicMaterial` `.physicsMaterial2D` `.playable` `.mask` `.brush` `.flare`
`.fontsettings` `.guiskin` `.giparams` `.renderTexture` `.spriteatlas`
`.spriteatlasv2` `.terrainlayer` `.mixer` `.shadervariants` `.preset` `.signal`
`.lighting` `.scenetemplate`

#### Options

| Flag | Effect |
|---|---|
| `--json` | Emit `prefablens.diff.v2` JSON. Bulk mode emits a `[{path, diff}]` array. Exit 0 always emits valid JSON, never prose. |
| `--html` | Emit a self-contained HTML report on stdout. |
| `--open` | Implies `--html`. Writes a temp report, prints its path, and opens a browser. Conflicts with `--json`. |
| `--project DIR` | Unity project root for guid resolution and the git repo dir. An unreadable DIR is an error (exit 1). |
| `--no-project` | Skip the default guid-resolution scan. Conflicts with `--project`. |
| `--color` | Force ANSI colors when stdout is not a TTY (for example a pipe). |
| `--no-color` | Disable ANSI colors. Overrides TTY detection and `--color`. |
| `--version` | Print `prefablens X.Y.Z` on stdout and exit 0. Ignores other work. |
| `-h`, `--help` | Print usage on stdout and exit 0. Ignores other work. |

#### Output formats

- **tree** (default): human-readable hierarchy on stdout.
  Colors are on for a TTY, on with `--color`, and off with `--no-color`.
- **json** (`--json`): the `prefablens.diff.v2` schema (single-file mode) or a
  `[{path, diff}]` array (bulk mode). Unresolved guid references are listed in
  `unresolvedGuids`. Resolved names appear in `resolved` after a project scan.
- **html** (`--html` / `--open`): one self-contained page, no external assets.
  With `--open` the report file is named `prefablens-<stem>-<millis>.html`.
  The write path is the first of `TMPDIR`, `TEMP`, or `/tmp`
  (in that order, on every platform).
  If the CLI fails to open a browser, it prints a warning and still exits 0.
  The path was already printed.
  If the report write fails, the CLI exits 1.

#### Guid resolution

Unity serializes references as `{fileID, guid, type}`.
prefablens resolves guids to asset paths in three ways:

1. `--project DIR`: scan the `.meta` files in DIR up front and resolve against them.
2. Default (git mode, no `--project`, no `--no-project`): resolve in a lazy way
   against the repository root. The scan runs only when the diffs contain
   unresolved references. A failed or empty scan degrades to unresolved output.
3. Built-in engine references resolve by name with no scan.

Unresolved references show as `guid:<hex>` in tree/HTML output.
They stay listed in `unresolvedGuids` in JSON.

#### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. This includes bulk mode with nothing to diff (`no Unity YAML changes`, or `[]` with `--json`). |
| 1 | Runtime error. See the list below. One-line `error: …` message on stderr. |
| 2 | Usage error. Unknown flag, too many arguments, flag conflict, or a missing operand after `--project`. Usage/hint on stderr. |

Exit 1 covers these failures:

- git failed or timed out
- a file read failed
- the `--project` directory was not readable
- input nested too deeply
- the `--open` report write failed

A Zig error trace that is not one of these exits is a prefablens bug.
Report that trace as a bug.

#### Limits and environment

- Input files are capped at 64 MiB each.
- Git subprocesses time out after 60 s (`error: git timed out …`, exit 1).
- `TMPDIR` / `TEMP` control where `--open` writes its report (fallback `/tmp`).

#### Contract examples

```bash
prefablens                                  # HEAD vs working tree, everything, as a tree
prefablens Assets/Player.prefab             # one file vs HEAD
prefablens main                             # main vs working tree
prefablens v0.6.0 v0.7.0                    # tag vs tag
prefablens HEAD~1 HEAD Assets/Boss.unity    # one file between two refs
prefablens before.prefab after.prefab       # no git: compare two files
prefablens --json main | jq '.[].path'      # bulk JSON, changed paths only
prefablens --open main                      # HTML report in the browser
prefablens --project . --no-color HEAD~3    # explicit project scan, plain text
```

## Verification

Install the toolchain from the repository root:

```bash
mise install
```

Then run the core and CLI checks:

```bash
zig build lint
zig build test
zig build perf
zig build run -- before.prefab after.prefab
```

Build the native CLI and Git strategy script before you run the package test:

```bash
zig build -Doptimize=ReleaseSafe
cli/pkg/render_test.sh zig-out/bin
```

The package test creates real ZIP files for all six release target names.
It checks the ZIP roots and the generated package files.
It also runs the extracted script through Git with the real host CLI.
CI also runs `.github/scripts/check-version-sync.sh` on Ubuntu.

CI runs these checks in the `core` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Deploy

Maintainers publish CLI binaries through the Release workflow on `main`.

Before a release:

1. Make sure that the GitHub App has `Contents: Read and write` permission.
2. Make sure that its installation has access to `PrefabLens`, `homebrew-tap`, and `scoop-bucket`.
3. Select `main` for [`.github/workflows/release.yml`](../.github/workflows/release.yml).
4. Run `workflow_dispatch` with a version `X.Y.Z` (no `v` prefix).

These permissions require a manual check before the release.

After you start the workflow, it updates versions (including `build.zig.zon`).
It builds platform ZIP files under `dist/`:

- `prefablens-macos-arm64.zip`
- `prefablens-macos-x64.zip`
- `prefablens-linux-x64.zip`
- `prefablens-linux-arm64.zip`
- `prefablens-windows-x64.zip`
- `prefablens-windows-arm64.zip`

Each CLI ZIP contains one native CLI and `git-merge-prefablens` at its root.
The native CLI name is `prefablens.exe` in the Windows ZIP files.
The script has no file-name extension on all platforms.

The workflow commits, tags `v$VERSION`, and creates the GitHub Release with `SHA256SUMS`.
After the release exists, `publish-packages` downloads all six CLI ZIP files.
It checks that each ZIP file contains the native CLI and the script.
It generates the Homebrew formula and Scoop manifest with `cli/pkg/render.sh`.
Then it pushes each file to its package repository.

The Homebrew formula installs the native CLI and the script.
Its test runs the version commands for the CLI and the strategy.
The Scoop manifest creates a shim for `prefablens.exe`.
It also adds the release directory to `PATH`, so Git can find the script.
Scoop removes the old `git-merge-prefablens` shim when it updates from the two-executable manifest.

For an older manual Windows installation, remove `git-merge-prefablens.exe` before you add the new release directory to `PATH`.
The old executable can hide the new script.

The Release workflow owns package updates in both repositories.
The Scoop bucket has no separate update workflow or `checkver` / `autoupdate` configuration.
Users install new versions with `scoop update prefablens` after the Release workflow updates the bucket.
