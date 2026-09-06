#!/usr/bin/env bash
# Verify the package renderer with ZIP files that contain native PrefabLens executables.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
native_bin_dir=${1:-"$repo_root/zig-out/bin"}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for executable in prefablens git-merge-prefablens; do
  [ -x "$native_bin_dir/$executable" ] || fail "missing native executable: $native_bin_dir/$executable"
done

primary_version=$("$native_bin_dir/prefablens" --version)
helper_version=$("$native_bin_dir/git-merge-prefablens" --version)
case "$primary_version" in
  "prefablens "*) ;;
  *) fail "unexpected prefablens version output: $primary_version" ;;
esac
case "$helper_version" in
  "git-merge-prefablens ${primary_version#prefablens }") ;;
  *) fail "the native executable versions differ" ;;
esac

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_target=macos-arm64 ;;
  Darwin-x86_64) host_target=macos-x64 ;;
  Linux-aarch64 | Linux-arm64) host_target=linux-arm64 ;;
  Linux-x86_64) host_target=linux-x64 ;;
  *) fail "unsupported test host: $(uname -s)-$(uname -m)" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dist="$tmp/dist"
mkdir -p "$dist"

targets=(
  macos-arm64
  macos-x64
  linux-x64
  linux-arm64
  windows-x64
  windows-arm64
)

make_archive() {
  local target=$1
  local include_helper=$2
  local stage="$tmp/stage-$target-$include_helper"
  local primary=prefablens
  local helper=git-merge-prefablens

  if [[ "$target" == windows-* ]]; then
    primary=prefablens.exe
    helper=git-merge-prefablens.exe
  fi

  mkdir -p "$stage"
  cp "$native_bin_dir/prefablens" "$stage/$primary"
  if [ "$include_helper" = yes ]; then
    cp "$native_bin_dir/git-merge-prefablens" "$stage/$helper"
  fi

  # A target comment gives each archive a different hash without an extra root entry.
  (cd "$stage" && zip -q -X "$dist/prefablens-$target.zip" ./*)
  printf '%s\n' "$target" | zip -q -z "$dist/prefablens-$target.zip"
}

for target in "${targets[@]}"; do
  make_archive "$target" yes
done

"$script_dir/render.sh" 1.2.3 "$dist" "$tmp/out"

[ -f "$tmp/out/prefablens.rb" ] || fail "missing Homebrew formula"
[ -f "$tmp/out/prefablens.json" ] || fail "missing Scoop manifest"

sha() {
  shasum -a 256 "$dist/prefablens-$1.zip" | cut -d' ' -f1
}

grep -q 'version "1.2.3"' "$tmp/out/prefablens.rb" || fail "formula version"
grep -q "$(sha macos-arm64)" "$tmp/out/prefablens.rb" || fail "formula macos-arm64 hash"
grep -q "$(sha macos-x64)" "$tmp/out/prefablens.rb" || fail "formula macos-x64 hash"
grep -q "$(sha linux-x64)" "$tmp/out/prefablens.rb" || fail "formula linux-x64 hash"
ruby -c "$tmp/out/prefablens.rb" >/dev/null || fail "formula syntax"

jq -e \
  --arg x64_hash "$(sha windows-x64)" \
  --arg arm64_hash "$(sha windows-arm64)" \
  '
    .version == "1.2.3" and
    .architecture["64bit"].url == "https://github.com/hashiiiii/PrefabLens/releases/download/v1.2.3/prefablens-windows-x64.zip" and
    .architecture["64bit"].hash == $x64_hash and
    .architecture.arm64.url == "https://github.com/hashiiiii/PrefabLens/releases/download/v1.2.3/prefablens-windows-arm64.zip" and
    .architecture.arm64.hash == $arm64_hash and
    .bin == ["prefablens.exe", "git-merge-prefablens.exe"]
  ' "$tmp/out/prefablens.json" >/dev/null || fail "Scoop manifest contract"

if grep -R -q '{{' "$tmp/out"; then
  fail "unrendered placeholder"
fi

mkdir -p "$tmp/install"
unzip -q "$dist/prefablens-$host_target.zip" -d "$tmp/install"
[ -x "$tmp/install/prefablens" ] || fail "the extracted prefablens file is not executable"
[ -x "$tmp/install/git-merge-prefablens" ] || fail "the extracted helper is not executable"
[ "$("$tmp/install/prefablens" --version)" = "$primary_version" ] || fail "the extracted prefablens command failed"
[ "$("$tmp/install/git-merge-prefablens" --version)" = "$helper_version" ] || fail "the extracted helper command failed"

# Each target must fail when its archive does not contain the complete pair.
for target in "${targets[@]}"; do
  good_archive="$tmp/prefablens-$target.good.zip"
  mv "$dist/prefablens-$target.zip" "$good_archive"
  make_archive "$target" no
  if "$script_dir/render.sh" 1.2.3 "$dist" "$tmp/out-$target" 2>"$tmp/error-$target"; then
    fail "accepted an incomplete $target archive"
  fi
  grep -q "prefablens-$target.zip" "$tmp/error-$target" || fail "missing archive name for $target error"
  [ ! -e "$tmp/out-$target/prefablens.rb" ] || fail "rendered formula from an incomplete $target archive"
  [ ! -e "$tmp/out-$target/prefablens.json" ] || fail "rendered manifest from an incomplete $target archive"
  mv "$good_archive" "$dist/prefablens-$target.zip"
done

echo "PASS"
