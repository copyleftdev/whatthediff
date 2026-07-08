#!/usr/bin/env bash
# Build, package, and checksum release artifacts for all supported targets.
#
# Produces dist/wtd-v<version>-<triple>.{tar.gz,zip} + dist/SHA256SUMS.
# Runs the full test suite first; a release never ships untested.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -oP 'pub const version = "\K[^"]+' src/cli.zig)"
[ -n "$VERSION" ] || { echo "release: cannot read version from src/cli.zig" >&2; exit 1; }

# Version-consistency guard. src/cli.zig is the single source of truth; every
# user-facing "this is the current version" surface must agree with it. Twice
# now a batched string-replace has silently no-matched on a version bump and
# shipped a stale field: --help missed a flag at v1.0.1, and the JSON-LD
# softwareVersion sat two releases behind at 1.0.1 because the replace looked
# for a string that had already drifted. A silent no-match is the failure mode,
# so each anchor below must match AT LEAST ONCE (a vanished anchor is a bug in
# this guard, not a pass) and every match must equal $VERSION.
#
# Historical version mentions (the roadmap's v0.2.0…, the macOS 10.9.9 floor)
# are deliberately NOT scanned — only these "current version" anchors are.
echo "==> wtd v$VERSION: version-consistency guard"
guard_fail=0
check_anchor() {   # <file> <perl-regex-with-\K-before-version> <label>
  local file="$1" re="$2" label="$3" hits
  hits="$(grep -oP "$re" "$file" || true)"
  if [ -z "$hits" ]; then
    echo "  MISSING: $label anchor not found in $file (renamed/removed?)" >&2
    guard_fail=1
    return
  fi
  local v
  while IFS= read -r v; do
    if [ "$v" != "$VERSION" ]; then
      echo "  STALE: $label in $file is '$v', expected '$VERSION'" >&2
      guard_fail=1
    fi
  done <<< "$hits"
}
check_anchor README.md       'version-\K[0-9]+\.[0-9]+\.[0-9]+'                       'README version badge'
check_anchor README.md       'WTD_VERSION=v\K[0-9]+\.[0-9]+\.[0-9]+'                  'README install pin example'
check_anchor docs/index.html '"softwareVersion": "\K[0-9]+\.[0-9]+\.[0-9]+'           'site JSON-LD softwareVersion'
check_anchor docs/index.html 'Deterministic semantic diff · v\K[0-9]+\.[0-9]+\.[0-9]+' 'site hero eyebrow'
check_anchor docs/index.html 'WTD_VERSION=v\K[0-9]+\.[0-9]+\.[0-9]+'                  'site install pin example'
if [ "$guard_fail" -ne 0 ]; then
  echo "release: version-consistency guard failed — bump the fields above to v$VERSION and retry." >&2
  exit 1
fi
echo "    all version anchors == v$VERSION"

echo "==> wtd v$VERSION: tests"
zig build test
zig fmt --check src tools build.zig

echo "==> cross-compiling"
zig build release

echo "==> packaging"
rm -rf dist
mkdir -p dist

for dir in zig-out/release/*/; do
  triple="$(basename "$dir")"
  name="wtd-v$VERSION-$triple"
  stage="dist/.stage/$name"
  mkdir -p "$stage"
  cp README.md intent.md "$stage/"
  [ -f LICENSE ] && cp LICENSE "$stage/"
  case "$triple" in
    *windows*)
      cp "$dir/wtd.exe" "$stage/"
      if command -v zip >/dev/null; then
        (cd dist/.stage && zip -qr "../$name.zip" "$name")
      else
        tar -czf "dist/$name.tar.gz" -C dist/.stage "$name"
      fi
      ;;
    *)
      cp "$dir/wtd" "$stage/"
      tar -czf "dist/$name.tar.gz" -C dist/.stage "$name"
      ;;
  esac
done
rm -rf dist/.stage

(cd dist && sha256sum -- * > SHA256SUMS)

echo "==> dist/"
ls -l dist
