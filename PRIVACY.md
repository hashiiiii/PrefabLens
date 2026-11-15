# Privacy policy: PrefabLens Chrome extension

Last updated: 2026-11-15

PrefabLens displays semantic diffs for UnityYAML files on GitHub pull request pages.  
It runs in your browser, has no developer-operated server, and makes network requests only to GitHub.

## Data the extension handles

- **GitHub access token.** GitHub issues the token through Device Flow with the `repo` scope.  
  The extension uses it to read pull request metadata and repository contents through the GitHub API.
- **Pending sign-in state.** While sign-in is in progress, the extension stores the temporary GitHub user code and its expiry time.
- **Settings and repository index.** The extension stores your view preference and GUID-to-path mappings built from repository contents.
- **Rendered diff cache.** The extension caches rendered diffs for pull requests you view.  
  Chrome clears this cache when the browser closes.

## Collection and use

The extension reads GitHub pull request pages to find UnityYAML files, then fetches the data needed to render their diffs from GitHub.  
It does not collect browsing history or page content from other websites.  
It has no analytics, tracking, or telemetry.

## Storage

The extension stores the token, pending sign-in state, settings, and repository index in `chrome.storage.local` on your device.  
It stores the diff cache in `chrome.storage.session`, which Chrome clears when the browser closes.  
The extension does not sync this data to other devices.

## Sharing

The extension sends the access token over HTTPS to `api.github.com` for authenticated API requests.  
Device Flow requests go to `github.com`; they do not include the access token.  
The extension uses no external service other than GitHub.

## Data removal

Remove the extension to delete its locally stored data.  
You can also revoke its token in your GitHub account settings under [Applications](https://github.com/settings/applications).

## Changes to this policy

Changes appear in this file; the revision history is in the Git log.

## Contact

Open an issue at <https://github.com/hashiiiii/PrefabLens/issues>.
