# Contributing to PrefabLens

Thanks for your interest in contributing. PrefabLens shows semantic diffs for
UnityYAML assets. This guide covers how to set the project up, the checks your
change must pass, and the conventions we follow.

PrefabLens is pre-1.0, so interfaces and output formats may still change. For
anything beyond a small fix, please open an issue to discuss the approach before
you start — it saves rework on both sides.

## Ways to contribute

- Report a bug or request a feature through GitHub Issues.
- Improve the documentation.
- Open a pull request for a bug fix or feature.
- For security vulnerabilities, do **not** open a public issue — follow
  [SECURITY.md](SECURITY.md) instead.

## Project layout

| Directory | Description |
|---|---|
| `core/` | Diff engine in Zig (shared by the CLI and WASM) |
| `cli/` | `prefablens` command-line tool |
| `extension/` | Chrome extension for semantic diffs on GitHub pull requests |
| `editor/` | Unity Editor package for semantic UnityYAML diffs |

## Development setup

The toolchain is managed with [mise](https://mise.jdx.dev/) — Zig 0.16, Node 24,
and .NET 10.

```bash
mise install
```

## Building and testing

CI runs these same checks on every pull request (see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml)). Run the ones for the
area you touched before opening a PR; your change is expected to pass them.

### Core and CLI (Zig)

```bash
zig build lint          # formatting and static checks
zig build test          # unit tests
zig build perf          # performance budget (enforced on Linux)
zig build run -- before.prefab after.prefab
```

### Chrome extension (TypeScript)

The extension consumes the diff engine compiled to WASM, so build that and run
the golden tests first:

```bash
zig build wasm
node --test core/tests/*.test.mjs

cd extension
npm ci
npm run size
npm run lint
npm run typecheck
npm test
npm run build
npm run e2e        # Playwright; installs Chromium on first run
```

### Unity Editor package (C#)

```bash
cd editor
dotnet tool restore
dotnet csharpier check . --no-msbuild-check
```

## Coding conventions

Before opening a pull request, read
[`docs/coding-conventions.md`](docs/coding-conventions.md). This document is
being drafted; check back as it fills in.

## Commits and branches

Pick one `type` for both the branch name and the commit subject.

- **Branch:** `<type>/<short-english-kebab>` — for example `feat/yaml-parser` or
  `fix/nested-override-diff`.
- **Commit subject:** `<type>: <subject>` — one line, imperative, lowercase
  first word, no trailing period, 50 characters or fewer. For example
  `feat: add YAML parser for .prefab files`.

| type | use when |
|------|----------|
| `feat` | new feature or capability |
| `fix` | bug fix |
| `docs` | documentation only |
| `style` | formatting or whitespace, no behavior change |
| `refactor` | restructuring without behavior change |
| `perf` | performance improvement |
| `test` | adding or fixing tests |
| `build` | build system or dependencies |
| `ci` | CI configuration |
| `chore` | miscellaneous maintenance |
| `revert` | reverting a prior commit |

## Pull requests

- Keep each PR focused on a single change; smaller is easier to review.
- Open it as a **draft** while it is still in progress, and mark it ready once
  CI is green.
- Fill in every section of the PR template — Summary, Motivation, Changes, and
  Testing. Under Testing, show the real commands you ran and their output.
- Link the issue your PR addresses with `Closes #NNN`.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
