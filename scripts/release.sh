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
