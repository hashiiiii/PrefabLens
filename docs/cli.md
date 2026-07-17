# prefablens CLI reference

`prefablens` renders semantic diffs for text-serialized Unity assets: GameObject /
component / field level changes instead of raw YAML lines. It reads either a git
repository (comparing refs and the working tree) or two files directly.

Quick-start examples live in the [README](../README.md#cli-2); this page is the full
reference.

## Synopsis

```
prefablens [--json|--html] [--open] [--project DIR|--no-project] [--color|--no-color] [<ref>] [<ref>] [<path>]
prefablens [flags] <before> <after>
```

## Operands and argument resolution

An operand ending in a Unity YAML extension (case-insensitive) is a **path**;
anything else is a **git ref**. There are no positional rules beyond that — flags,
refs, and paths may appear in any order.

| Operands | Meaning |
|---|---|
| (none) | HEAD vs working tree, all changed Unity files (bulk mode) |
| `<path>` | HEAD vs working tree, one file |
| `<ref>` | ref vs working tree, all changed Unity files |
| `<ref> <path>` | ref vs working tree, one file |
| `<ref> <ref>` | ref vs ref, all changed Unity files |
| `<ref> <ref> <path>` | ref vs ref, one file |
| `<before> <after>` (two paths) | plain two-file compare, no git involved |

More than two refs, more than two paths, or mixing two paths with a ref is an
error (`too many arguments`, exit 2).

Recognized Unity YAML extensions:
`.prefab` `.unity` `.asset` `.mat` `.anim` `.controller` `.overrideController`
`.physicMaterial` `.physicsMaterial2D` `.playable` `.mask` `.brush` `.flare`
`.fontsettings` `.guiskin` `.giparams` `.renderTexture` `.spriteatlas`
`.spriteatlasv2` `.terrainlayer` `.mixer` `.shadervariants` `.preset` `.signal`
`.lighting` `.scenetemplate`

`.meta`, `.asmdef`, and other non-UnityYAML files are never treated as paths — an
operand like `Foo.meta` is parsed as a git ref and will fail in git, by design.
A binary-serialized asset (no Force Text) passed as an explicit path produces a
silent empty diff, not an error: the parser finds no YAML document headers, which
is indistinguishable from "no changes". Bulk (git) mode content-sniffs candidates
and skips binary files up front; explicit path operands are never second-guessed.
Switch the project to text serialization for meaningful diffs.

## Options

| Flag | Effect |
|---|---|
| `--json` | Emit `prefablens.diff.v2` JSON. In bulk mode the output is a `[{path, diff}]` array; exit 0 always yields valid JSON (an array, possibly empty), never prose. |
| `--html` | Emit a self-contained HTML report on stdout. |
| `--open` | Implies `--html`; writes the report to a temp file, prints its path on stdout, and opens it in a browser. Conflicts with `--json`. |
| `--project DIR` | Unity project root for guid resolution, and the git repo dir. An unreadable DIR is an error (exit 1). |
| `--no-project` | Skip the default guid-resolution scan. Conflicts with `--project`. |
| `--color` | Force ANSI colors in tree output (useful when piping). |
| `--no-color` | Disable ANSI colors; wins over `--color` and TTY detection. |
| `--version` | Print `prefablens X.Y.Z` on stdout and exit 0. Short-circuits everything else. |
| `-h`, `--help` | Print usage on stdout and exit 0. Short-circuits everything else. |

## Output formats

- **tree** (default): human-readable hierarchy on stdout. Colors are on when
  stdout is a TTY, forced by `--color`, and always suppressed by `--no-color`.
- **json** (`--json`): the `prefablens.diff.v2` schema (single-file mode) or a
  `[{path, diff}]` array (bulk mode). Unresolved guid references are listed in
  `unresolvedGuids`; resolved names appear in `resolved` when a project scan ran.
- **html** (`--html` / `--open`): one self-contained page, no external assets.
  With `--open` the report file is named `prefablens-<stem>-<millis>.html` and
  written to the first of `TMPDIR`, `TEMP`, or `/tmp` (checked in that order, on
  every platform).
  Failing to launch a browser prints a warning but still exits 0 — the path was
  already printed. Failing to write the report is an error (exit 1).

## Guid resolution

Unity serializes references as `{fileID, guid, type}`. prefablens resolves guids
to asset paths in three ways:

1. `--project DIR`: scan DIR's `.meta` files up front and resolve against them.
2. Default (git mode, no `--project`, no `--no-project`): resolve lazily against
   the repository root — the scan runs only when the computed diffs actually
   contain unresolved references, so ref-free changes cost nothing. A failed or
   empty scan degrades to unresolved output.
3. Built-in engine references (default materials, meshes, and so on) resolve by
   name with no scan at all.

Unresolved references render as `guid:<hex>` in tree/HTML output and stay listed
in `unresolvedGuids` in JSON.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success — including bulk mode finding nothing to diff (prints `no Unity YAML changes`). |
| 1 | Runtime error: git failed or timed out, a file could not be read, the `--project` directory could not be read, input nested too deeply, or the `--open` report could not be written. One-line `error: …` message on stderr. |
| 2 | Usage error: unknown flag, too many arguments, conflicting flags, or a missing operand after `--project`. Usage/hint on stderr. |

Anything else crashing with a Zig error trace is a prefablens bug, not a user
mistake — the trace is the bug report; please file it.

## Limits and environment

- Input files are capped at 64 MiB each.
- git subprocesses time out after 60 s (surfaced as `error: git timed out …`, exit 1).
- `TMPDIR` / `TEMP` control where `--open` writes its report (fallback `/tmp`).

## Examples

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
