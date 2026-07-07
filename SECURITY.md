# Security Policy

## Supported Versions

PrefabLens is pre-1.0 software. Security fixes are applied to the latest
released version only. Please upgrade to the newest release before reporting.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older releases | :x:                |

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Report privately through GitHub's built-in advisory workflow:

1. Open the [Security tab](https://github.com/hashiiiii/PrefabLens/security).
2. Click **Report a vulnerability** to file a private advisory.

This routes the report directly to the maintainer without public disclosure.

### What to include

- A description of the vulnerability and its impact.
- Steps to reproduce (a minimal UnityYAML asset or command line is ideal).
- The PrefabLens version and platform (OS / architecture).

### What to expect

- Acknowledgement on a best-effort basis.
- An assessment and, if confirmed, a fix in a subsequent release.
- Coordinated disclosure once a fix is available.

## Scope

PrefabLens parses untrusted UnityYAML assets. Parser crashes, out-of-bounds
reads, and excessive resource use triggered by crafted input are in scope.
Vulnerabilities in third-party dependencies are tracked separately through
automated dependency updates.
