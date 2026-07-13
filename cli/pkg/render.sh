#!/usr/bin/env bash
# Render the Homebrew formula and Scoop manifest from the packaging
# templates. The release workflow and the initial bootstrap both call this.
#
# Usage: render.sh <version> <dist-dir> <out-dir>
#   <dist-dir> holds the release zips (prefablens-<target>.zip).
#   <out-dir> receives prefablens.rb and prefablens.json.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
version=$1 dist=$2 out=$3
mkdir -p "$out"

sha() { shasum -a 256 "$dist/prefablens-$1.zip" | cut -d' ' -f1; }

render() {
  sed -e "s/{{VERSION}}/$version/g" \
      -e "s/{{SHA256_MACOS_ARM64}}/$(sha macos-arm64)/g" \
      -e "s/{{SHA256_MACOS_X64}}/$(sha macos-x64)/g" \
      -e "s/{{SHA256_LINUX_X64}}/$(sha linux-x64)/g" \
      -e "s/{{SHA256_WINDOWS_X64}}/$(sha windows-x64)/g" \
      "$script_dir/$1"
}

render prefablens.rb.tmpl > "$out/prefablens.rb"
render prefablens.json.tmpl > "$out/prefablens.json"

# A leftover placeholder means a template and this script drifted apart.
if grep -q '{{' "$out/prefablens.rb" "$out/prefablens.json"; then
  echo "error: unrendered placeholder remains" >&2
  exit 1
fi
