#!/usr/bin/env bash
# PrefabLens: verify the five release version strings agree before tagging.
# The Editor package downloads prefablens CLI from the release tagged v<Cli.Version>,
# so a drift between these files silently ships a 404 or a version-mismatched binary.
#
# Usage (from repo root): .claude/skills/cut-release/scripts/check-versions.sh <X.Y.Z>
set -euo pipefail

want="${1:-}"
if [[ -z "$want" ]]; then
  echo "usage: $0 <version>   e.g. $0 0.2.0" >&2
  exit 2
fi

# Each source's current version, extracted by its own surrounding syntax.
cli=$(sed -n 's/.*public const string Version = "\([^"]*\)".*/\1/p' editor/Editor/Cli.cs | head -1)
epkg=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' editor/package.json | head -1)
xpkg=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' extension/package.json | head -1)
xman=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' extension/manifest.json | head -1)
zver=$(sed -n 's/.*pub const version = "\([^"]*\)".*/\1/p' cli/src/main.zig | head -1)

fail=0
check() {
  local label="$1" got="$2"
  if [[ "$got" == "$want" ]]; then
    printf '  ok    %-26s %s\n' "$label" "$got"
  else
    printf '  DIFF  %-26s %s (want %s)\n' "$label" "${got:-<none>}" "$want"
    fail=1
  fi
}

check "editor/Editor/Cli.cs"      "$cli"
check "editor/package.json"       "$epkg"
check "extension/package.json"    "$xpkg"
check "extension/manifest.json"   "$xman"
check "cli/src/main.zig"          "$zver"

if [[ "$fail" -ne 0 ]]; then
  echo "version mismatch: bump every source to $want before tagging v$want" >&2
  exit 1
fi
echo "all five version sources at $want"
