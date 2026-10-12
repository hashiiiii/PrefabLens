# Privacy policy: PrefabLens Chrome extension

Last updated: 2026-07-12

PrefabLens shows semantic diffs for UnityYAML files on GitHub pull request pages.
The extension runs only in your browser.
The extension has no developer-operated server.
It sends data only through requests to GitHub.

## Data the extension handles

- **GitHub OAuth token (authentication information).** GitHub issues this token after you authenticate with GitHub Device Flow. The extension uses it to authenticate requests to the GitHub API.
- **Extension settings.** These include your view preference (semantic or raw) and a GUID index built from each repository's contents. The index makes diff rendering faster.
- **Diff cache.** The extension caches rendered diffs for the pull requests you view. The cache lasts for the browser session.

## How data is collected and used

GitHub issues the token after you complete the GitHub Device Flow authorization.
The extension uses the token only to fetch file contents and pull request metadata from the GitHub API.
These requests supply the data for semantic diffs.
It collects no other data.
It does not collect browsing history.
It does not collect page content from any site other than `https://github.com`.
It does not collect personal information.

## Where data is stored

The extension stores data only on your device:

- The token and settings are stored locally in `chrome.storage.local`.
- The diff cache is stored in `chrome.storage.session`. The browser discards the cache when it closes.

The extension does not sync data to other devices.
It does not upload data anywhere else.

## Who data is shared with

The extension shares data only with GitHub.
The extension sends the token over HTTPS only to `github.com` and `api.github.com`.
These hosts serve GitHub Device Flow, file contents, and pull request metadata.
It uses no service other than GitHub and has no analytics, tracking, or telemetry.

## Data removal

Remove the extension to delete all data it stored on your device.
You can also revoke the token at any time from your GitHub account settings under [Applications](https://github.com/settings/applications).

## Changes to this policy

Changes to this policy appear in this file.
The revision history is in the Git log.

## Contact

Open an issue at <https://github.com/hashiiiii/PrefabLens/issues>.
