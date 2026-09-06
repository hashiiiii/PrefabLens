#!/usr/bin/env bash
# Verify the package renderer with ZIP files that contain the real CLI and Git script.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
native_bin_dir=${1:-"$repo_root/zig-out/bin"}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -x "$native_bin_dir/prefablens" ] || fail "missing native executable: $native_bin_dir/prefablens"
[ -x "$native_bin_dir/git-merge-prefablens" ] || fail "missing executable script: $native_bin_dir/git-merge-prefablens"
printf '#!/bin/sh\nexec prefablens merge-strategy "$@"\n' > "$tmp/expected-script"
cmp -s "$tmp/expected-script" "$native_bin_dir/git-merge-prefablens" || fail "unexpected git-merge-prefablens script bytes"

primary_version=$("$native_bin_dir/prefablens" --version)
strategy_version=$(PATH="$native_bin_dir:$PATH" "$native_bin_dir/git-merge-prefablens" --version)
case "$primary_version" in
  "prefablens "*) ;;
  *) fail "unexpected prefablens version output: $primary_version" ;;
esac
[ "$strategy_version" = "prefablens merge-strategy ${primary_version#prefablens }" ] || fail "the script did not run the matching merge strategy"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_target=macos-arm64 ;;
  Darwin-x86_64) host_target=macos-x64 ;;
  Linux-aarch64 | Linux-arm64) host_target=linux-arm64 ;;
  Linux-x86_64) host_target=linux-x64 ;;
  *) fail "unsupported test host: $(uname -s)-$(uname -m)" ;;
esac

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
  local include_script=$2
  local stage="$tmp/stage-$target-$include_script"
  local primary=prefablens
  local script=git-merge-prefablens

  if [[ "$target" == windows-* ]]; then
    primary=prefablens.exe
  fi

  mkdir -p "$stage"
  cp "$native_bin_dir/prefablens" "$stage/$primary"
  if [ "$include_script" = yes ]; then
    cp "$native_bin_dir/git-merge-prefablens" "$stage/$script"
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
    .bin == "prefablens.exe" and
    .env_add_path == "."
  ' "$tmp/out/prefablens.json" >/dev/null || fail "Scoop manifest contract"

if grep -R -q '{{' "$tmp/out"; then
  fail "unrendered placeholder"
fi

install_dir="$tmp/install space-差分"
mkdir -p "$install_dir" "$tmp/empty-git-exec"
unzip -q "$dist/prefablens-$host_target.zip" -d "$install_dir"
[ -x "$install_dir/prefablens" ] || fail "the extracted prefablens file is not executable"
[ -x "$install_dir/git-merge-prefablens" ] || fail "the extracted script is not executable"
[ "$("$install_dir/prefablens" --version)" = "$primary_version" ] || fail "the extracted prefablens command failed"
[ "$(PATH="$install_dir:$PATH" GIT_EXEC_PATH="$tmp/empty-git-exec" git merge-prefablens --version)" = "$strategy_version" ] || fail "Git did not run the extracted script"

# Each target must fail when its archive does not contain the script.
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
