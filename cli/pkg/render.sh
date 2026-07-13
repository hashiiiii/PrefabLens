#!/usr/bin/env bash
# Render the Homebrew formula from prefablens.rb, stamping the version and
# the per-target SHA256 hashes. The release workflow and the initial
# bootstrap both call this. The Scoop manifest is not rendered here: the
# scoop-bucket repo updates itself via checkver/autoupdate.
#
# Usage: render.sh <version> <dist-dir> <out-dir>
#   <dist-dir> holds the release zips (prefablens-<target>.zip).
#   <out-dir> receives the rendered prefablens.rb.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
version=$1 dist=$2 out=$3
mkdir -p "$out"

sha() { shasum -a 256 "$dist/prefablens-$1.zip" | cut -d' ' -f1; }

sed -e "s/{{VERSION}}/$version/g" \
    -e "s/{{SHA256_MACOS_ARM64}}/$(sha macos-arm64)/g" \
    -e "s/{{SHA256_MACOS_X64}}/$(sha macos-x64)/g" \
    -e "s/{{SHA256_LINUX_X64}}/$(sha linux-x64)/g" \
    "$script_dir/prefablens.rb" > "$out/prefablens.rb"

# A leftover placeholder means the template and this script drifted apart.
if grep -q '{{' "$out/prefablens.rb"; then
  echo "error: unrendered placeholder remains" >&2
  exit 1
fi
