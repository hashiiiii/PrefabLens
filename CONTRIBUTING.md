# Contributing to PrefabLens

Thanks for your interest in contributing.

PrefabLens is pre-1.0: breaking changes land without deprecation cycles and
large refactors are in flight. A pull request that arrives without prior
discussion is likely to conflict with that work — and review bandwidth for
it may simply not exist. So contributions follow an issue-first flow:

1. **Open an issue** describing the bug or the change you have in mind, and
   discuss the approach with a maintainer.
2. **Wait for the `approved` label.** When we agree the change should be
   implemented, a maintainer puts the `approved` label on the issue. That
   label is the green light to start.
3. **Fork the repository and open a pull request.** Link the approved issue
   with `Closes #NNN` in the body and fill in every section of the PR
   template.

A pull request without a linked `approved` issue receives an automated
comment and is converted to draft until the issue-first flow catches up.

For security vulnerabilities, do **not** open a public issue — follow
[SECURITY.md](SECURITY.md) instead.

## Releases and changelog

There is no curated `CHANGELOG.md`, by decision. The release history lives in
[GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases): notes are
generated from the squash-merged pull requests since the previous tag, and PR
titles follow the `type: subject` convention, so the generated notes are already
grouped and readable. When writing a PR title, remember it becomes a release
note line verbatim.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
