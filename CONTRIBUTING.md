# Contributing to PrefabLens

This document explains how to contribute to PrefabLens.

PrefabLens is pre-1.0 software.
Breaking changes can land without a deprecation cycle.
The project is undergoing large refactors.
A pull request that skips prior discussion may conflict with that work.
Review capacity may be limited.
Contributions use an issue-first flow:

1. **Open an issue.** Describe the bug or the change. Discuss the approach with a maintainer.
2. **Wait for the `approved` label.** A maintainer adds it after approving the approach. You can start once the label is present.
3. **Fork the repository and open a pull request.** Link the approved issue with `Closes #NNN` in the body. Complete every section of the PR template.

If a pull request has no linked `approved` issue, automation posts a comment.
Automation also converts the pull request to draft until the issue-first flow is complete.

For security vulnerabilities, do **not** open a public issue.
Follow [SECURITY.md](SECURITY.md) instead.

## Language

Use English in this repository.

Contributors often read related issues and pull requests to understand the reasons for earlier changes.
Using English makes project history easier to read and lowers the barrier to using and contributing to PrefabLens.

## Releases and changelog

There is no curated `CHANGELOG.md`.
The release history is in [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases).
Release notes come from the squash-merged pull requests since the previous tag.
PR titles use the `type: subject` convention.
The generated notes are grouped by type.
A PR title becomes a release note line without modification.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
