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
| `cli/pkg/` | Scripts that write the Homebrew formula for release |

Dependencies point from `cli/` into `core/`.
`core/` does not import `cli/`.

### Constraints

- All git work uses subprocesses in `cli/src/input.zig`.
- Each input file has a size cap of 64 MiB.
- Git subprocesses time out after 60 s.
- Binary-serialized assets produce an empty diff for an explicit path.
  Bulk git mode skips binary candidates after a content sniff.
- `.meta`, `.asmdef`, and other non-UnityYAML names are never path operands.
  The CLI treats them as git refs on purpose.

### Semantic merge adapters

The CLI provides two Git merge adapters. Both adapters use the semantic merge engine for Unity YAML files.

#### `merge-driver`

```text
prefablens merge-driver <base> <ours-and-output> <theirs> <path>
```

Git maps the placeholders to these arguments:

| Argument | Git placeholder | Meaning |
|---|---|---|
| `<base>` | `%O` | Common ancestor |
| `<ours-and-output>` | `%A` | Ours input and result output |
| `<theirs>` | `%B` | Theirs input |
| `<path>` | `%P` | Repository-relative path |

#### `mergetool`

```text
prefablens mergetool <base> <local> <remote> <merged>
```

Git provides these values through environment variables:

| Argument | Git variable | Meaning |
|---|---|---|
| `<base>` | `$BASE` | Common ancestor |
| `<local>` | `$LOCAL` | Ours input |
| `<remote>` | `$REMOTE` | Theirs input |
| `<merged>` | `$MERGED` | Partial result and final output |

The adapters return these results:

| Command | Arguments | Exit 0 | Exit 1 | Exit 2 |
| --- | --- | --- | --- | --- |
| `merge-driver` | `<base> <ours-and-output> <theirs> <path>` | Complete result | Safe partial result | No write |
| `mergetool` | `<base> <local> <remote> <merged>` | Validated result | User abort, no write | Validation failure, no write |

At startup, `mergetool` recomputes the deterministic partial result. It compares that result with the bytes in `$MERGED`.
If the bytes differ, it returns exit 2 and keeps `$MERGED` unchanged.

After the last conflict is resolved, `mergetool` checks these eight conditions:

1. Every atomic operation has a result.
2. Every `fileID` is unique.
3. Every Component document has a matching `m_Component` reference.
4. Every Transform `m_Father` matches the parent `m_Children` reference.
5. The hierarchy has no cycle.
6. Every internal reference points to an existing document.
7. The complete output parses as Unity YAML.
8. `$MERGED` has not changed since startup.

Each input file has a 64 MiB limit. `mergetool` opens its TUI only when standard input and standard output are TTYs.
Without both TTYs, it returns exit 2 and does not write `$MERGED`.

The adapters write a temporary file in the same directory as the output. They flush and close the file before atomic replace.
Malformed input, unsupported input, an abort, or a validation error leaves the output unchanged.

`diff-driver` and `difftool` are reserved names for Issue #227. This task does not implement those adapters.

libvaxis is a dependency of the CLI TUI only. The core and WASM targets do not import libvaxis.

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

`cli/pkg/render_test.sh` covers the Homebrew formula scripts.
CI also runs `.github/scripts/check-version-sync.sh` on Ubuntu.

CI runs these checks in the `core` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Deploy

Maintainers publish CLI binaries through the Release workflow on `main`.

1. Run [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   with `workflow_dispatch` and a version `X.Y.Z` (no `v` prefix).
2. Make sure that you run the workflow from `main`.

After you start the workflow, it bumps versions (including `build.zig.zon`).
It builds platform zips under `dist/`:

- `prefablens-macos-arm64.zip`
- `prefablens-macos-x64.zip`
- `prefablens-linux-x64.zip`
- `prefablens-linux-arm64.zip`
- `prefablens-windows-x64.zip`
- `prefablens-windows-arm64.zip`

It commits, tags `v$VERSION`, and creates the GitHub Release with `SHA256SUMS`.
Then the `publish-formula` job writes the Homebrew formula with
`cli/pkg/render.sh` and pushes it to `hashiiiii/homebrew-tap`.

The Scoop bucket is not pushed from this repository.
It updates itself from the release and `SHA256SUMS`.
