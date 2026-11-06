#!/usr/bin/env bash
set -euo pipefail

zig_version=$(zig version)
zls_version=$(zls --version)
printf 'Zig: %s\nZLS: %s\n' "$zig_version" "$zls_version"

if [[ ! "$zig_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ ! "$zls_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Expected stable Zig and ZLS releases.' >&2
  exit 1
fi

# Builds never run ZLS, so compilation alone cannot detect an incompatible server.
# ZLS requires the same major/minor release as Zig; patch versions may differ.
# https://zigtools.org/zls/install/#zig-zls-version-compatibility
if [[ "${zig_version%.*}" != "${zls_version%.*}" ]]; then
  echo 'Incompatible Zig and ZLS: major/minor versions must match.' >&2
  exit 1
fi

echo 'Zig and ZLS compatibility OK.'
