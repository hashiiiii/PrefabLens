#!/bin/sh
# Guard that the release version stays in sync across the five version-pinned
# files fanned out by .bumpversion.toml. Each extraction below mirrors that
# file's search pattern in .bumpversion.toml, so this guard and the release
# tooling agree on what "the version" is.
set -eu

cd "$(dirname "$0")/../.."

status=0
reference=""

# $1: file path, $2: extracted version (empty when the marker is missing)
check() {
  file=$1
  version=$2
  if [ -z "$version" ]; then
    version="(version marker not found)"
    status=1
  fi
  printf '%s: %s\n' "$file" "$version"
  if [ -z "$reference" ]; then
    reference=$version
  elif [ "$version" != "$reference" ]; then
    status=1
  fi
}

check build.zig.zon \
  "$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)"
check extension/manifest.json \
  "$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' extension/manifest.json | head -n 1)"
check editor/package.json \
  "$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' editor/package.json | head -n 1)"
check editor/Editor/Cli.cs \
  "$(sed -n 's/.*public const string Version = "\([^"]*\)".*/\1/p' editor/Editor/Cli.cs | head -n 1)"
check extension/package.json \
  "$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' extension/package.json | head -n 1)"

if [ "$status" -ne 0 ]; then
  echo "Version mismatch: the files above must all carry the same version." >&2
  exit 1
fi
echo "Version sync OK: $reference"
