# CLI

This page describes the `cli/` and shared `core/` code for contributors.
For install steps and quick-start examples, see the [README](../README.md).
For the contribution process, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Purpose

`prefablens` shows semantic diffs for text-serialized Unity assets.
It shows GameObject, component, and field changes.
It does not show raw YAML line-by-line diffs.

The CLI owns Git and filesystem I/O.
The shared engine in `core/` parses input, computes diffs, builds trees, and produces JSON.
The Editor package and other tools call this CLI.
They must not reimplement Git logic.

The JSON contract is `prefablens.diff.v2`.
The schema remains stable unless a release documents a breaking change.

## Tech stack

| Piece | Choice |
|---|---|
| Language | Zig 0.16 (see root `mise.toml` and `build.zig.zon`) |
| Diff engine | `core/` (also built to WASM for the extension) |
| CLI entry | `cli/src/main.zig` → binary `prefablens` |
| Version source | `build.zig.zon` (injected via `build_options`) |
| Build | `zig build` installs to `zig-out/bin/` |
| Native tests | `zig build test` (core and CLI unit tests, Git integration, and supported terminal tests) |
| Lint | `zig build lint` |
| Performance checks | `zig build perf` (includes the GUID scan budget) |

## Design

### Layout

| Path | Role |
|---|---|
| `core/src/` | Parse, diff, tree, JSON (`prefablens.diff.v2`), WASM export |
| `cli/src/main.zig`, `command.zig` | Process setup and command dispatch |
| `cli/src/diff.zig` | Diff input collection, GUID resolution, and output selection |
| `cli/src/diff_options.zig` | Diff options and operand parsing |
| `cli/src/input.zig` | Git subprocess I/O and file reads |
| `cli/src/resolve.zig` | `.meta` GUID index scan |
| `cli/src/unity_path.zig` | UnityYAML extension detection |
| `cli/src/builtin_refs.zig` | Built-in Unity resource names |
| `cli/src/render_tree.zig`, `render_html.zig`, `display.zig` | Tree, HTML, and ANSI output |
| `cli/src/merge_tui.zig`, `merge_ui_state.zig` | Merge interaction, rendering, and resolution state |
| `cli/src/testing/` | Diff integration tests and shared Git and terminal test helpers |
| `cli/bin/git-merge-prefablens` | Script that runs `prefablens merge-strategy` for Git |
| `cli/pkg/` | Templates and scripts for Homebrew and Scoop |

Dependencies point from `cli/` to `core/`.
`core/` does not import `cli/`.
Test executables share helpers from `testing/` without importing one another.

### Constraints

- Git diff operations use subprocesses in `cli/src/input.zig`.
- Each input file has a size cap of 64 MiB.
- Git diff subprocesses time out after 60 s.
- Binary-serialized assets produce an empty diff when an explicit path names one.
  Bulk Git mode skips binary candidates after a content sniff.
- `.meta`, `.asmdef`, and other non-UnityYAML names are never path operands.
  The CLI treats them as Git refs intentionally.

### Git merge integration

One native executable and the packaged `git-merge-prefablens` script must be on `PATH`.
The script contains only this command:

```sh
#!/bin/sh
exec prefablens merge-strategy "$@"
```

Git needs the script name to select the merge strategy.
Git for Windows recognizes its shebang and starts `sh` for the script.

Before setup writes attributes or Git configuration, it verifies the strategy and driver through Git.
Each route must reach the installed `prefablens` version.

The `git --exec-path` command prints the directory that Git searches before the other `PATH` directories.
The script must be a custom Git command on `PATH`, outside this directory.

The setup keeps existing attribute lines and unrelated configuration.
The configuration uses command names without absolute paths.
You do not need to run setup again after a complete upgrade.

#### Setup scopes

```text
prefablens setup-merge [--project|--local|--user]
```

| Scope | Attributes | Git configuration |
| --- | --- | --- |
| `--project` | `.gitattributes` at the repository root | Local |
| `--local` or no flag | Git's `info/attributes` file, usually `.git/info/attributes` | Local |
| `--user` | User attributes file | Global |

Choose at most one scope.
The former `--team` flag has been replaced by `--project` and is no longer accepted.
Existing merge configuration remains valid.

Local and project setup require a Git working tree and also work from its subdirectories.
Local setup resolves the attributes path through Git, including in linked worktrees.
Outside a working tree, these scopes exit with status 2 and explain where to run setup.
The message also suggests `prefablens setup-merge --user` for user configuration.
This failure does not write setup files.

With `--project`, commit `.gitattributes` to share the attribute rules.
The merge driver, mergetool, and strategy settings remain local to the clone.
Each clone needs setup unless those settings are already available from user configuration.

User setup also works outside repositories and writes merge settings with `git config --global`.
It uses the global `core.attributesFile` value, including values from included configuration files.
Git expands `~` in that path.
An empty or relative value is rejected because it cannot identify one shared attributes file across repositories.
Set an absolute path or a path starting with `~/` before running user setup.

When `core.attributesFile` is unset, user setup uses `$XDG_CONFIG_HOME/git/attributes`.
If `XDG_CONFIG_HOME` is unset or empty, it uses `~/.config/git/attributes`.
Setup registers this default path in global configuration so that a system `core.attributesFile` setting cannot redirect Git to another file.
Existing attribute lines are preserved, and repeated setup does not duplicate the rules.
If the user attributes file is a symlink, setup updates its target and preserves the link.

User setup sets `pull.twohead=prefablens` globally, selecting PrefabLens for ordinary merges across all repositories, including repositories without Unity files.
Repository configuration takes precedence over global configuration.
For attributes, Git gives `info/attributes` precedence over `.gitattributes`, which takes precedence over user attributes.
See [Git attributes](https://git-scm.com/docs/gitattributes) for the full precedence rules.

#### Merge behavior

Before the strategy writes merge objects, the index, or working files, it checks the installed CLI version.

If any command is missing or reports a different version, reinstall the release archive.

The `pull.twohead=prefablens` configuration entry selects the strategy for ordinary two-head `git merge` commands.
The strategy uses `git merge-tree --write-tree -z --messages` and requires Git 2.39 or later.
It uses the output tree, index stages, and structured conflict types from the Git ort engine.
It also tracks conflicts that have no unmerged index entries.
Strategy options (`-X`) require Git 2.43 or later.
On older Git versions, the strategy refuses these options before it writes working files.

The strategy prepares the index, then uses the Git two-tree checkout to protect local edits and untracked paths.
It writes the conflict index before any UI starts.
Only conflicts in UnityYAML files open a UI. Other formats keep their normal Git conflict state.

The UI supports choices for file deletions, renames, and matching GUID metadata.
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
`$MERGED` contains the current working file and receives a resolution only after completion.

| Command | Exit 0 | Exit 1 | Exit 2 |
| --- | --- | --- | --- |
| `merge-driver` | Complete result | Unresolved result with text markers or native binary representation | I/O failure, no write |
| `mergetool` | Result that passes all checks | User quit, no write | Startup error or failed check, no write |

The driver uses the original three inputs for Git text fallback.
The `merge.conflictStyle` configuration and `conflict-marker-size` attribute control the markers.
If the text merge is clean but semantic resolution is incomplete, the driver emits a whole-file conflict block.
Files other than UnityYAML use Git's text or binary fallback.

The semantic plan and valid partial result remain in memory.
At startup, the mergetool reads the three original inputs and records a snapshot of `$MERGED`.
It does not parse the markers.
If the user quits, startup fails, or the UI is interrupted, the working conflict representation stays in place.
The user can edit it with another tool and complete the normal Git workflow.

#### Edit Result

Click **Ours** or **Theirs** to preview a value.
Click **Result**, or focus it and press **Enter**, to edit the existing value.
**Ctrl+E** opens the Result editor directly from the selected conflict; **F2** also works.
Before editing, **Backspace** or **Delete** clears the focused Result and reopens the conflict without starting the editor.
While editing, typing and pasting insert at the cursor; **Backspace** and **Delete** remove a character or the selected range.

Arrow keys move the cursor within the value.
Click inside the editor to place the cursor, or drag to select text across lines.
Selected text is highlighted; typing or pasting replaces it.
**Home** / **Ctrl+A** and **End** / **Ctrl+E** move to the start and end of the current line.
**Shift+Enter** inserts a newline with the current indentation.
If your terminal sends the same key code for Enter and Shift+Enter, use **Ctrl+J** or configure Shift+Enter to send a newline (`\n`).
**Enter** applies the value; **Escape** cancels editing and returns to the hierarchy.
Clearing the value and leaving **Result** reopens the conflict.
Applying an empty value still requires confirmation.

Paste the YAML value from a diff, without diff markers, headers, or the enclosing property name.
Bracketed paste keeps indentation and line breaks and waits for **Enter** before applying the value.
Collection values accept block YAML and flow YAML split across lines.
Keep each scalar token on one line; folded scalar input remains unsupported.
PrefabLens keeps the existing collection shape checks and output formatting rules.
For a component delete/edit conflict, Result contains the whole component document.
You can edit its properties while keeping its document header, type, and `m_GameObject` reference unchanged.

#### Completion checks

Before PrefabLens writes a completed semantic resolution, it verifies these conditions:

1. Every atomic operation has a result.
2. Every `fileID` is unique.
3. Every Component document has a matching `m_Component` reference.
4. Every Transform `m_Father` matches the parent `m_Children` reference.
5. The hierarchy has no cycle.
6. Every internal reference points to an existing document.
7. The complete output parses as UnityYAML.
8. The current output file matches its snapshot from UI startup.

Original input files have a 64 MiB limit. Working conflict output has a separate 256 MiB limit.
The mergetool requires both standard input and standard output to be TTYs.
Without them, it returns 2 and keeps `$MERGED` unchanged. The automatic strategy instead leaves the merge unresolved.
PrefabLens writes completed output with atomic file replacement and retains existing permissions.

`diff-driver` and `difftool` remain reserved for Issue #227.
libvaxis is a CLI dependency. The core and WASM targets do not import it.

### CLI contract

Users, the Editor package, and scripts rely on this interface.
A change to this interface requires a clear release note.

#### Synopsis

```
prefablens [--json|--html] [--open] [--project DIR|--no-project] [--color|--no-color] [<ref>] [<ref>] [<path>]
prefablens [flags] <before> <after>
```

#### Operands and argument resolution

An operand that ends in a UnityYAML extension (case-insensitive) is a **path**.
Any other operand is a **Git ref**.
Flags can appear anywhere among the operands.
Among operands of the same kind, order matters.
The first ref (or path) is the before side.
The second is the after side.

| Operands | Meaning |
|---|---|
| (none) | HEAD vs working tree, all changed UnityYAML files (bulk mode) |
| `<path>` | HEAD vs working tree, one file |
| `<ref>` | ref vs working tree, all changed UnityYAML files |
| `<ref> <path>` | ref vs working tree, one file |
| `<ref> <ref>` | first ref (before) vs second ref (after), all changed UnityYAML files |
| `<ref> <ref> <path>` | first ref (before) vs second ref (after), one file |
| `<before> <after>` (two paths) | plain comparison of two files, no Git involved |

More than two refs, more than two paths, or a mix of two paths with a ref is an
error (`too many arguments`, exit 2).

Recognized UnityYAML extensions:

`.prefab` `.unity` `.asset` `.mat` `.anim` `.controller` `.overrideController`
`.physicMaterial` `.physicsMaterial2D` `.playable` `.mask` `.brush` `.flare`
`.fontsettings` `.guiskin` `.giparams` `.renderTexture` `.spriteatlas`
`.spriteatlasv2` `.terrainlayer` `.mixer` `.shadervariants` `.preset` `.signal`
`.lighting` `.scenetemplate`

#### Options

| Flag | Effect |
|---|---|
| `--json` | Emit `prefablens.diff.v2` JSON. Bulk mode emits a `[{path, diff}]` array. On exit 0, it always emits valid JSON and never prose. |
| `--html` | Emit a self-contained HTML report on stdout. |
| `--open` | Implies `--html`. Writes a temp report, prints its path, and opens a browser. Conflicts with `--json`. |
| `--project DIR` | Unity project root for GUID resolution and source prefabs. Git uses the repository containing DIR. An unreadable DIR is an error (exit 1). |
| `--no-project` | Skip the default GUID resolution scan. Conflicts with `--project`. |
| `--color` | Force ANSI colors when stdout is not a TTY (for example a pipe). |
| `--no-color` | Disable ANSI colors. Overrides TTY detection and `--color`. |
| `--version` | Print `prefablens X.Y.Z` on stdout and exit 0. Ignores other work. |
| `-h`, `--help` | Print usage on stdout and exit 0. Ignores other work. |

In Git mode, paths are relative to the repository root, including when `--project` selects a nested Unity project.
For example, use `prefablens --project Game Game/Assets/Foo.prefab` from the repository root.

#### Output formats

- **tree** (default): prints the hierarchy to stdout.
  Colors are enabled for TTY output and with `--color`. They are disabled with `--no-color`.
- **json** (`--json`): the `prefablens.diff.v2` schema (single-file mode) or a
  `[{path, diff}]` array (bulk mode). Unresolved GUID references are listed in
  `unresolvedGuids`. Resolved names appear in `resolved` after a project scan.
- **html** (`--html` / `--open`): one self-contained page, no external assets.
  With `--open` the report file is named `prefablens-<stem>-<millis>.html`.
  The write path is the first of `TMPDIR`, `TEMP`, or `/tmp`
  (in that order, on every platform).
  If the CLI fails to open a browser, it prints a warning and still exits 0.
  The CLI prints the path before attempting to open the browser.
  If the report write fails, the CLI exits 1.

#### GUID resolution

Unity serializes references as `{fileID, guid, type}`.
The CLI resolves GUIDs to asset paths in three ways:

1. `--project DIR`: scan the `.meta` files in DIR up front and resolve references against them.
2. Default (Git mode, no `--project`, no `--no-project`): resolve references lazily
   against the repository root. The scan runs only when the diffs contain
   unresolved references. If the scan fails or finds no entries, the references remain unresolved.
3. Built-in engine references resolve by name with no scan.

Unresolved references show as `guid:<hex>` in tree and HTML output.
They stay listed in `unresolvedGuids` in JSON.

#### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. This includes bulk mode with nothing to diff (`no UnityYAML changes`, or `[]` with `--json`). |
| 1 | Runtime error. See the list below. One-line `error: …` message on stderr. |
| 2 | Usage error. Unknown flag, too many arguments, flag conflict, or a missing operand after `--project`. Usage/hint on stderr. |

Exit code 1 covers these failures:

- Git failed or timed out
- a file read failed
- the `--project` directory was not readable
- input nested too deeply
- the `--open` report write failed

If Zig emits a trace for a failure outside this list, it indicates a prefablens bug.
Report the trace as a bug.

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
prefablens before.prefab after.prefab       # no Git: compare two files
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

The performance gate builds both benchmarks before running them sequentially.
The diff benchmark warms up once, then reports five samples and checks their median against the 600 ms ceiling.
Each sample diffs 50,000 objects with a fresh arena to keep memory usage bounded.
The GUID scan retains its 50,000-file workload and 1,200 ms ceiling.

Build the native CLI and Git strategy script before running the package test:

```bash
zig build -Doptimize=ReleaseSafe
cli/pkg/render_test.sh zig-out/bin
```

The package test creates a ZIP file for each of the six release targets.
It checks the ZIP roots and the generated package files.
It also runs the extracted script through Git with the host CLI.
CI also runs `.github/scripts/check-version-sync.sh` on Ubuntu.

CI runs these checks in the `core` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Deploy

Maintainers publish CLI binaries through the Release workflow on `main`.

Before a release:

1. Verify that the GitHub App has `Contents: Read and write` permission.
2. Verify that its installation has access to `PrefabLens`, `homebrew-tap`, and `scoop-bucket`.
3. Select `main` for [`.github/workflows/release.yml`](../.github/workflows/release.yml).
4. Run `workflow_dispatch` with a version `X.Y.Z` (no `v` prefix).

Verify these permissions manually before the release.

The workflow updates versions, including `build.zig.zon`.
It builds platform ZIP files under `dist/`:

- `prefablens-macos-arm64.zip`
- `prefablens-macos-x64.zip`
- `prefablens-linux-x64.zip`
- `prefablens-linux-arm64.zip`
- `prefablens-windows-x64.zip`
- `prefablens-windows-arm64.zip`

Each CLI ZIP contains one native executable and `git-merge-prefablens` at its root.
The native CLI name is `prefablens.exe` in the Windows ZIP files.
The script has no filename extension on any platform.

The workflow commits, tags `v$VERSION`, and creates the GitHub Release with `SHA256SUMS`.
After the release is created, `publish-packages` downloads all six CLI ZIP files.
It checks that each ZIP file contains the native CLI and the script.
It generates the Homebrew formula and Scoop manifest with `cli/pkg/render.sh`.
It then pushes each file to its package repository.

The Homebrew formula installs the native CLI and the script.
Its test runs the version commands for the CLI and the strategy.
The Scoop manifest creates a shim for `prefablens.exe`.
It also adds the release directory to `PATH`, so Git can find the script.
Scoop removes the old `git-merge-prefablens` shim when it updates from the two-executable manifest.

For an older manual Windows installation, remove `git-merge-prefablens.exe` before you add the new release directory to `PATH`.
The old executable can hide the new script.

The Release workflow updates both package repositories.
The Scoop bucket has no separate update workflow or `checkver` / `autoupdate` configuration.
Users install new versions with `scoop update prefablens` after the Release workflow updates the bucket.
