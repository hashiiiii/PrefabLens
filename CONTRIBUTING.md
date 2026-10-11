# Contributing to PrefabLens

PrefabLens is pre-1.0 software.
Breaking changes may ship without a deprecation cycle.
Large refactors are in progress, and review capacity may be limited.
Discuss changes before implementation to avoid conflicts with that work.

1. Open an issue. Describe the bug or proposed change and discuss the approach with a maintainer.
2. Wait for the `approved` label. A maintainer adds it after approving the approach. Start implementation once the label is present.
3. Fork the repository and open a pull request. Link the approved issue with `Closes #NNN` in the body. Complete every section of the PR template.

If a pull request has no linked `approved` issue, automation posts a comment.
Automation also converts the pull request to draft until the issue-first flow is complete.

For security vulnerabilities, do **not** open a public issue.
Follow [SECURITY.md](SECURITY.md) instead.

## Language

Use English in this repository.

Contributors read related issues and pull requests to understand earlier decisions.
English keeps that history accessible to more users and contributors.

## Releases and changelog

The release history is in [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases); there is no curated `CHANGELOG.md`.
Release notes come from the squash-merged pull requests since the previous tag.
PR titles use the `type: subject` convention.
The generated notes are grouped by type.
Each PR title appears unchanged as a release note entry.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
