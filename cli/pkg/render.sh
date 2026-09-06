#!/usr/bin/env bash
# Render the Homebrew formula and Scoop manifest from their templates.
# The script validates every release ZIP before it writes package files.
#
# Usage: render.sh <version> <dist-dir> <out-dir>
#   <dist-dir> holds the release zips (prefablens-<target>.zip).
#   <out-dir> receives prefablens.rb and prefablens.json.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
version=$1 dist=$2 out=$3

targets=(
  macos-arm64
  macos-x64
  linux-x64
  linux-arm64
  windows-x64
  windows-arm64
)

validate_archive() {
  local target=$1
  local archive="$dist/prefablens-$target.zip"
  local primary=prefablens
  local script=git-merge-prefablens
  local actual
  local expected

  if [[ "$target" == windows-* ]]; then
    primary=prefablens.exe
  fi

  if ! actual=$(unzip -Z1 "$archive" 2>/dev/null | LC_ALL=C sort); then
    echo "error: cannot read release archive: $archive" >&2
    return 1
  fi
  expected=$(printf '%s\n' "$script" "$primary" | LC_ALL=C sort)
  if [ "$actual" != "$expected" ]; then
    echo "error: $archive must contain only $primary and $script at the ZIP root" >&2
    return 1
  fi
}

for target in "${targets[@]}"; do
  validate_archive "$target"
done

mkdir -p "$out"

sha() { shasum -a 256 "$dist/prefablens-$1.zip" | cut -d' ' -f1; }

sed -e "s/{{VERSION}}/$version/g" \
    -e "s/{{SHA256_MACOS_ARM64}}/$(sha macos-arm64)/g" \
    -e "s/{{SHA256_MACOS_X64}}/$(sha macos-x64)/g" \
    -e "s/{{SHA256_LINUX_X64}}/$(sha linux-x64)/g" \
    "$script_dir/prefablens.rb" > "$out/prefablens.rb"

sed -e "s/{{VERSION}}/$version/g" \
    -e "s/{{SHA256_WINDOWS_X64}}/$(sha windows-x64)/g" \
    -e "s/{{SHA256_WINDOWS_ARM64}}/$(sha windows-arm64)/g" \
    "$script_dir/prefablens.json" > "$out/prefablens.json"

# A leftover placeholder means that a template and this script differ.
if grep -q '{{' "$out/prefablens.rb" "$out/prefablens.json"; then
  echo "error: unrendered placeholder remains" >&2
  exit 1
fi
