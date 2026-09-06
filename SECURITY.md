# Security Policy

## Supported Versions

PrefabLens is pre-1.0 software.
The maintainer applies security fixes only to the latest released version.
Upgrade to the newest release before you report a vulnerability.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a Vulnerability

Do **not** open a public issue for security vulnerabilities.

Report the vulnerability privately through the GitHub advisory workflow:

1. Open the [Security tab](https://github.com/hashiiiii/PrefabLens/security).
2. Select **Report a vulnerability** to file a private advisory.

The report is sent to the maintainer and remains private.

### What to include

- A description of the vulnerability and its impact.
- Steps to reproduce. Include a minimal UnityYAML asset or command-line example when possible.
- The PrefabLens version and platform (OS/architecture).

### What to expect

- An acknowledgment when possible.
- An assessment and, for valid reports, a fix in a later release.
- Coordinated disclosure after a fix is available.

## Scope

PrefabLens parses untrusted UnityYAML assets.
Parser crashes, out-of-bounds reads, and excessive resource use from crafted input are in scope.
The project tracks vulnerabilities in third-party dependencies through automated dependency updates.
