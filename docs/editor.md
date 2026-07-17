# PrefabLens for the Unity Editor

The editor package shows semantic diffs of your working tree inside Unity:
which UnityYAML assets changed against a chosen git ref, and what changed inside
each one at the GameObject / component / field level.

## Requirements

- Unity 2022.3 or newer.
- The project is inside a git repository (the CLI shells out to git).
- Text asset serialization (Edit > Project Settings > Editor > Asset
  Serialization > Force Text) — binary-serialized assets cannot be diffed.

## Installation

Via [OpenUPM](https://openupm.com/packages/com.hashiiiii.prefablens/):

```bash
openupm add com.hashiiiii.prefablens
```

Or without the openupm CLI: add the scoped registry as described on the package
page, or install straight from git via Package Manager > Add package from git
URL:

```
https://github.com/hashiiiii/PrefabLens.git?path=editor
```

## The PrefabLens window

Open **Window > PrefabLens**.

- The left pane lists every changed UnityYAML asset compared to the **Base**
  ref; the right pane shows the selected asset's semantic diff.
- **Base** accepts a branch, tag, or commit; empty means HEAD. The field commits
  on Enter or focus loss, and each committed edit triggers exactly one CLI run —
  edits made while a run is in flight are queued and re-run automatically once
  the in-flight run returns.
- The status line always names the ref the displayed data was produced from
  (for example `3 changed vs HEAD`).
- The window refreshes when it gains focus and via the **Refresh** button.
- Reference fields resolve guids through the local `AssetDatabase`, so script
  and prefab references display as project paths.

## The CLI binary

The window runs the `prefablens` CLI as a child process. On first use it
downloads the pinned version automatically from GitHub Releases:

- Download target: `Library/PrefabLens/<version>/prefablens` (`.exe` on
  Windows), relative to the project root. `Library/` is not version-controlled,
  so the binary never enters your repository.
- Integrity: the release's `SHA256SUMS` is fetched first and the zip is verified
  against it before extraction. A mismatch aborts the install.
- On macOS/Linux the binary is marked executable; a failed `chmod` fails the
  download with the binary path in the message.
- Older cached versions under `Library/PrefabLens/` are deleted after a
  successful install.
- The whole download is capped at 120 s and can be canceled from the window.
- CLI runs are capped at 90 s; closing the window kills an in-flight run.

When neither the override nor a downloaded binary is available, the window
shows a `prefablens CLI not found (v<version>).` screen instead of the diff
panes, with a **Download from GitHub Releases** button and a reminder that a
manual path can be set via the `PrefabLens.CliPath` EditorPrefs key. If the
previous auto-download attempt failed, its error appears above that message;
if a broken CLI path override caused the screen, that is called out above it
too (see [Using your own CLI binary](#using-your-own-cli-binary)).

## Using your own CLI binary

Preferences > **PrefabLens** (Edit > Preferences on Windows/Linux, Unity >
Settings on macOS) exposes the override:

- **CLI path override** — an absolute path to a `prefablens` binary. Empty means
  "auto-download the pinned version". The page also offers Browse….
- **Resolved CLI (override|downloaded): …** — the binary the window would run
  right now, tagged with where it came from, for diagnostics. When neither the
  override nor a downloaded binary exists it instead reads `Resolved CLI: not
  found — the PrefabLens window downloads v<version> on its next refresh`. A
  broken override additionally shows `Override points at a missing file: …`
  underneath.
- The setting is stored in the `PrefabLens.CliPath` EditorPrefs key (per-machine,
  not per-project), so it can also be set from scripts:

```csharp
UnityEditor.EditorPrefs.SetString("PrefabLens.CliPath", "/usr/local/bin/prefablens");
```

Resolution order: the override wins when its file exists; otherwise the
downloaded binary under `Library/` is used if present. An override pointing at
a missing file falls back to that downloaded binary if it exists, or otherwise
to an automatic download attempt (the missing-CLI screen instead, if a
previous attempt in this session already failed). The broken override itself
is reported in three places: a console warning
(`PrefabLens: EditorPrefs 'PrefabLens.CliPath' points at a missing file: <path>.
Falling back to the default location.`), a note on the missing-CLI screen
(`Override 'PrefabLens.CliPath' points at a missing file: <path>`), and the
Preferences page (`Override points at a missing file: <path>`). Fix or clear
the override to silence all three. The console warning specifically is logged
once per distinct missing path, not on every refresh; clearing or fixing the
override re-arms it, so a later broken path is reported too.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Download failed: …` in the window | Network/proxy blocked GitHub Releases, or the SHA-256 check failed. Retry, or download the zip manually from Releases and point the CLI path override at the extracted binary. |
| A one-line error from the CLI, or `prefablens exited with N` when the CLI printed nothing | The CLI's own error (stderr) — most commonly the project is not inside a git repository, or git timed out. See [docs/cli.md](cli.md) for the CLI's error contract. |
| `Could not parse CLI output (CLI version mismatch?)` | The binary at the override path is too old/new for this package. The Unity console carries the exact parse exception. Clear the override or update the binary. |
| `prefablens timed out after 90s and was killed` | A hung git or an enormous working tree. Check `git status` performance in that repository. |
| Everything shows as changed / nothing parses | The project is serializing assets as binary. Switch to Force Text. |

## How the window invokes the CLI

For the curious (and for debugging): a refresh runs

```
prefablens [<base-ref>] --json
```

with the project root as the working directory, and renders the resulting
`[{path, diff}]` array. Everything documented in [docs/cli.md](cli.md) about
bulk mode and guid resolution applies as-is.
