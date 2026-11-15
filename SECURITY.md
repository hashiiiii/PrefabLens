# Security policy

## Supported versions

The maintainer applies security fixes only to the latest release.  
Upgrade to the latest release before reporting a vulnerability.

## Reporting a vulnerability

Do not report security vulnerabilities in a public issue.  
Use GitHub's private advisory workflow:

1. Open the [Security tab](https://github.com/hashiiiii/PrefabLens/security).
2. Select **Report a vulnerability**.

The report goes to the maintainer and remains private.

Include:

- A description of the vulnerability and its impact.
- Reproduction steps, with a minimal UnityYAML asset or command-line example when possible.
- The PrefabLens version and platform (OS and architecture).

The maintainer will acknowledge reports when possible, assess each report, and fix valid vulnerabilities in a later release.  
Coordinated disclosure follows when a fix is available.

## Scope

PrefabLens parses untrusted UnityYAML assets.  
Parser crashes, out-of-bounds reads, and excessive resource use caused by crafted input are in scope.  
The project tracks third-party dependency vulnerabilities through automated dependency updates.
