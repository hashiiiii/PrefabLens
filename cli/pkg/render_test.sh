#!/usr/bin/env bash
# Tests for render.sh: it renders the Homebrew formula and Scoop manifest
# from the packaging templates, substituting the version and the per-target
# SHA256 hashes of the release zips.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fixture release assets with distinct known content; render.sh only hashes
# the zips, so plain files are enough.
mkdir -p "$tmp/dist"
for target in macos-arm64 macos-x64 linux-x64 windows-x64; do
  printf '%s' "$target" > "$tmp/dist/prefablens-$target.zip"
done

./render.sh 1.2.3 "$tmp/dist" "$tmp/out"

fail() { echo "FAIL: $1"; exit 1; }
sha() { shasum -a 256 "$tmp/dist/prefablens-$1.zip" | cut -d' ' -f1; }

# The version reaches both manifests.
grep -q 'version "1.2.3"' "$tmp/out/prefablens.rb" || fail "formula version"
grep -q '"version": "1.2.3"' "$tmp/out/prefablens.json" || fail "manifest version"

# Each manifest embeds the hash of its own target's asset.
grep -q "$(sha macos-arm64)" "$tmp/out/prefablens.rb" || fail "formula macos-arm64 hash"
grep -q "$(sha macos-x64)" "$tmp/out/prefablens.rb" || fail "formula macos-x64 hash"
grep -q "$(sha linux-x64)" "$tmp/out/prefablens.rb" || fail "formula linux-x64 hash"
grep -q "$(sha windows-x64)" "$tmp/out/prefablens.json" || fail "manifest windows-x64 hash"

# No placeholder survives rendering.
if grep -q '{{' "$tmp/out/prefablens.rb" "$tmp/out/prefablens.json"; then
  fail "unrendered placeholder"
fi

echo "PASS"
