---
name: cut-release
description: Use when cutting a new PrefabLens release, publishing a version, or pushing a vX.Y.Z tag. Bumps the five version sources in lockstep, tags main to trigger the release workflow, and verifies the GitHub Release with its four CLI zips. PrefabLens repo only. Explicit invocation only — pushes tags and publishes a public release.
disable-model-invocation: true
license: Proprietary
metadata:
  project: PrefabLens
---

# Cut a PrefabLens release

## Overview

PrefabLens ships four components on one version line: the Zig CLI, the Chrome extension, the Unity Editor package, and the MCP server (npm). A release is triggered by **pushing a `vX.Y.Z` git tag** — `.github/workflows/release.yml` then cross-compiles the CLI for four targets, zips them, and runs `gh release create` automatically. The release workflow then publishes `@hashiiiii/prefablens-mcp` to npm after the zip assets go live (Trusted Publishing — the npmjs.com side needs to be configured before the first publish).

**Core principle: the human pushes exactly one thing — the tag. Everything downstream is automated. Never create the release by hand.**

The Editor package downloads the CLI from `releases/download/v<Cli.Version>/prefablens-<target>.zip`, so the tag, `Cli.Version`, and the package versions must be the *same* string, and the tag must point at a commit that already carries that version.

## When to use

- Publishing a new version (feature/bugfix already merged to `main`)
- Re-cutting after a failed release workflow

Do **not** use to: re-point an existing tag, or hotfix a shipped binary in place (bump a new patch instead).

## Steps

Run from a clean `main` that is up to date (`git switch main && git pull`).

1. **Pick the version** `X.Y.Z` (semver; bump patch for fixes, minor for features).

2. **Bump all four sources to `X.Y.Z`** on a branch:
   - `editor/Editor/Cli.cs` → `public const string Version = "X.Y.Z";`
   - `editor/package.json` → `"version": "X.Y.Z"`
   - `extension/package.json` → `"version": "X.Y.Z"`
   - `extension/manifest.json` → `"version": "X.Y.Z"`
   - `mcp/package.json` → `"version": "X.Y.Z"`

3. **Verify they agree** (this is the #1 failure mode):

   ```
   .claude/skills/cut-release/scripts/check-versions.sh X.Y.Z
   ```

   Fix any `DIFF` line before continuing.

4. **Land the bump on main first.** Branch `chore/release-vX.Y.Z`, commit `chore: bump version to X.Y.Z`, open a PR, wait for CI green, squash-merge. Then `git switch main && git pull`.

5. **Tag the merged commit and push** (the push is the trigger):

   ```
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

6. **Verify the release** — the workflow takes a few minutes:

   ```
   gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')
   gh release view vX.Y.Z --json tagName,assets -q '.tagName + ": " + ([.assets[].name] | join(", "))'
   ```

   Expect four assets: `prefablens-{macos-arm64,macos-x64,linux-x64,windows-x64}.zip`.

   Also verify `npm view @hashiiiii/prefablens-mcp version` matches the tag.

## Red flags — stop and reconsider

| Situation | Why it breaks | Do instead |
|---|---|---|
| Running `gh release create` yourself | The workflow's own `gh release create` then fails with "already exists" | Only push the tag; let the workflow publish |
| Tagging before the version bump is on `main` | The released binary and package versions disagree; Editor downloads a version with no matching package | Merge the bump to `main`, then tag that commit |
| `Cli.Version` ≠ the tag version | Editor requests `releases/download/v<Cli.Version>/…` → 404 | Keep all four sources and the tag identical (step 3 enforces this) |
| Re-pushing / moving an existing tag to "redo" a release | Consumers cache the old asset; history becomes ambiguous | Delete the release **and** tag, or bump to the next patch and tag that |

## Verify the outcome, not the intent

A release is done only when `gh release view vX.Y.Z` lists all four zips. If the workflow failed, read `gh run view --log-failed`, fix on `main`, delete the partial tag/release, and re-tag — do not assume a pushed tag means a published release.
