# Contributing to PrefabLens

## Contribution flow

1. Open or find an issue that describes the bug or proposed change, then discuss the approach with a maintainer.
2. Wait for the issue's `approved` label before starting implementation.
3. Open a pull request from your fork.  
   Link the approved issue in this repository with `Closes #NNN` and complete every section of the pull request template.

The PR gate also accepts an `approved` label applied to the pull request by a maintainer.  
If neither the linked PrefabLens issue nor the pull request has that label, the gate comments and converts the pull request to draft.

Use English for issues, pull requests, and documentation so contributors can follow earlier decisions.  
Use `type: subject` for pull request titles.

Do not report security vulnerabilities in a public issue.  
Follow the [security policy](SECURITY.md).

## Local development

Install [mise](https://mise.jdx.dev/), then install the tool versions pinned in `mise.toml` from the repository root:

```sh
mise install
```

### Project structure

| Directory | Purpose |
| --- | --- |
| `core/` | Zig semantic diff engine used by the CLI and WebAssembly builds |
| `cli/` | Native `prefablens` command-line tool and Git merge strategy |
| `extension/` | Chrome extension for semantic diffs on GitHub pull request pages |
| `editor/` | Unity Editor package |
| `site/` | Cloudflare Workers demo built from CLI and extension artifacts |

### Build and test

Run these commands from the repository root.

Build the CLI and merge strategy, build the WebAssembly module, and run Zig formatting and native tests:

```sh
zig build
zig build wasm
zig build lint
zig build test
zig build perf
```

`zig build` installs the CLI and Git strategy script in `zig-out/bin/`.  
`zig build test` runs core, CLI, and integration tests.
`zig build perf` measures a 50,000-object diff and a 50,000-file GUID scan against performance budgets.

Build and test the extension:

```sh
(cd extension && pnpm install --frozen-lockfile && pnpm run build && pnpm test)
```

Build the Editor package tests against the real CLI binaries:

```sh
zig build test-installation-binaries -Doptimize=ReleaseSafe
PREFABLENS_TEST_BIN_DIR="$PWD/zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/zig-out/test-alternate-bin" \
  dotnet test editor/DotNetTests~/Tests
```

For the test setup and Unity Editor checks, see the [Editor test guide](editor/DotNetTests~/README.md).

Build the site and run its checks.  
The site uses the CLI, WebAssembly module, and extension demo bundle:

```sh
zig build
zig build wasm
(cd extension && pnpm install --frozen-lockfile && pnpm run demo)
(cd site && pnpm install --frozen-lockfile && pnpm test && pnpm run build)
```

For product workflows, see the [CLI guide](docs/cli.md), [extension guide](docs/extension.md), and [Unity Editor guide](docs/editor.md).

## Maintainer releases

Before the release, confirm the GitHub App has `Contents: Read and write` permission and access to the PrefabLens, `homebrew-tap`, and `scoop-bucket` repositories.  
Run the [Release workflow](.github/workflows/release.yml) from `main` and enter a version as `X.Y.Z`, without a `v` prefix.

The workflow updates the version fields for the CLI, extension, and Editor package automatically.  
After the builds succeed, it commits the version bump, creates the `vX.Y.Z` tag, and publishes a GitHub Release.  
It also updates the Homebrew and Scoop packages.  
Generated release notes use squash-merged pull request titles unchanged; the project does not maintain a curated changelog.

The `skip_chrome_extension` input skips only the Chrome Web Store upload and review submission; the GitHub Release still includes the extension ZIP.  
The store publishes it after review approval.  
After the workflow completes, check the GitHub Release assets and the Homebrew and Scoop packages.  
Then check that the Editor package version is current on OpenUPM; the Release workflow does not publish to OpenUPM.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
