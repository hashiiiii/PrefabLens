# Privacy Policy — PrefabLens Chrome Extension

Last updated: 2026-07-12

PrefabLens shows semantic diffs for Unity YAML files on GitHub pull request pages.
The extension runs only in your browser.
There is no developer-operated server.
Data leaves your browser only in requests to GitHub.

## Data the extension handles

- **GitHub OAuth token (authentication information).** GitHub issues this token when you authenticate with the GitHub device flow. The extension uses the token to authenticate requests to the GitHub API.
- **Extension settings.** Your view-mode preference (semantic or raw) and a per-repository GUID index from repository contents. The index makes diff rendering faster.
- **Diff cache.** Rendered diff data for the pull requests that you view. The cache lasts for the browser session.

## How data is collected and used

GitHub issues the token only after you complete the GitHub device-flow authorization.
The extension uses the token for one purpose only.
It fetches file contents and pull request metadata from the GitHub API so that it can show diffs.
The extension collects no other data.
It does not collect browsing history.
It does not collect page content from sites other than `https://github.com`.
It does not collect personal information.

## Where data is stored

All data stays on your device:

- The token and settings are stored locally in `chrome.storage.local`.
- The diff cache is stored in `chrome.storage.session`. The browser discards the cache when it closes.

The extension does not sync data to other devices.
The extension does not upload data to any other location.

## Who data is shared with

The extension shares data with no one except GitHub.
The token goes only to `github.com` (device-flow endpoints) and `api.github.com` (file contents and pull request metadata) over HTTPS.
There is no developer server.
There is no third-party service.
There is no analytics, tracking, or telemetry.

## Data removal

Remove the extension to delete all data that it stored on your device.
You can also revoke the token at any time from your GitHub account settings under [Applications](https://github.com/settings/applications).

## Changes to this policy

Changes appear in this file in the repository.
The revision history is in the Git log.

## Contact

Open an issue at <https://github.com/hashiiiii/PrefabLens/issues>.
