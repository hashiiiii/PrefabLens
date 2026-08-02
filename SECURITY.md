# Security Policy

## Supported Versions

PrefabLens is pre-1.0 software.
The maintainer applies security fixes to the latest released version only.
Upgrade to the newest release before you report a vulnerability.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older releases | :x:                |

## Reporting a Vulnerability

Do **not** open a public issue for security vulnerabilities.

Report the vulnerability in private through the GitHub advisory workflow:

1. Open the [Security tab](https://github.com/hashiiiii/PrefabLens/security).
2. Select **Report a vulnerability** to file a private advisory.

The report goes to the maintainer.
The report is not public.

### What to include

- A description of the vulnerability and its impact.
- Steps to reproduce. A minimal UnityYAML asset or command line is ideal.
- The PrefabLens version and platform (OS / architecture).

### What to expect

- Acknowledgement when possible.
- An assessment. If the report is valid, a fix in a later release.
- Coordinated disclosure after a fix is available.

## Scope

PrefabLens parses untrusted UnityYAML assets.
Parser crashes, out-of-bounds reads, and excessive resource use from crafted input are in scope.
The project tracks vulnerabilities in third-party dependencies through automated dependency updates.
