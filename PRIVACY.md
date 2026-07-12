# Privacy Policy — PrefabLens Chrome Extension

Last updated: 2026-07-12

PrefabLens renders semantic diffs for Unity YAML files on GitHub pull request
pages. It runs entirely inside your browser. There is no developer-operated
server: no data ever leaves your browser except in requests to GitHub itself.

## Data the extension handles

- **GitHub OAuth token (authentication information).** Obtained when you sign
  in via the GitHub device flow. Used to authenticate requests to the GitHub
  API.
- **Extension settings.** Your view-mode preference (semantic or raw) and a
  per-repository GUID index derived from repository contents, kept to speed up
  diff rendering.
- **Diff cache.** Rendered diff data for the pull requests you view, cached
  for the duration of the browser session.

## How data is collected and used

The token is issued by GitHub only after you complete GitHub's own device-flow
authorization. The extension uses it for exactly one purpose: fetching file
contents and pull request metadata from the GitHub API so it can render
diffs. The extension collects nothing else —
no browsing history, no page content from sites other than
`https://github.com`, and no personal information.

## Where data is stored

All data stays on your device:

- The token and settings are stored locally via `chrome.storage.local`.
- The diff cache is stored via `chrome.storage.session` and is discarded when
  the browser closes.

Nothing is synced to other devices or uploaded anywhere.

## Who data is shared with

No one. The token is sent only to `github.com` (device-flow endpoints) and
`api.github.com` (file contents and pull request metadata) over HTTPS. There
is no developer server, no third-party service, and no analytics, tracking, or
telemetry of any kind.

## Data removal

Remove the extension to delete everything it stored on your device. You can
also revoke the token itself at any time from your GitHub account settings
under [Applications](https://github.com/settings/applications).

## Changes to this policy

Changes are published to this file in the repository; the revision history is
visible in the Git log.

## Contact

Open an issue at <https://github.com/hashiiiii/PrefabLens/issues>.
