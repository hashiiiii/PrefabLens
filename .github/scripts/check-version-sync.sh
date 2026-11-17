#!/bin/sh
# Keep installation URLs in sync with release builds so users install the
# version whose artifacts the Release workflow publishes.
set -eu

cd "$(dirname "$0")/../.."

status=0
reference=""

# $1: file path, $2: extracted version (empty when the marker is missing)
check() {
  checked_file=$1
  checked_version=$2
  if [ -z "$checked_version" ]; then
    checked_version="(version marker not found)"
    status=1
  fi
  printf '%s: %s\n' "$checked_file" "$checked_version"
  if [ -z "$reference" ]; then
    reference=$checked_version
  elif [ "$checked_version" != "$reference" ]; then
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

editor_url='https://github.com/hashiiiii/PrefabLens.git?path=editor#v'
for file in README.md docs/editor.md site/index.liquid site/editor.liquid; do
  urls=$(grep -oE 'https://github[.]com/hashiiiii/PrefabLens[.]git[?]path=editor[^<`"[:space:]]*' "$file" || true)
  if [ -z "$urls" ]; then
    check "$file (Editor Git URL)" ""
    continue
  fi
  # A valid example must not hide another URL that would still install main.
  while IFS= read -r url; do
    check "$file (Editor Git URL)" "${url#"$editor_url"}"
  done <<EOF
$urls
EOF
done

check "docs/cli.md (Release guide URL)" \
  "$(sed -n 's|.*https://github.com/hashiiiii/PrefabLens/blob/v\([^/]*\)/docs/cli.md.*|\1|p' docs/cli.md)"

if [ "$status" -ne 0 ]; then
  echo "Version mismatch: the files above must all carry the same version." >&2
  exit 1
fi
echo "Version sync OK: $reference"
