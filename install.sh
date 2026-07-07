#!/bin/sh
# wtd installer — detects OS/arch, downloads the matching release binary,
# verifies its SHA256, and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/copyleftdev/whatthediff/main/install.sh | sh
#
# Environment overrides:
#   WTD_VERSION=v0.1.0        install a specific version (default: latest)
#   WTD_INSTALL_DIR=~/bin     install directory
#                             (default: /usr/local/bin if writable, else ~/.local/bin)
set -eu

REPO="copyleftdev/whatthediff"

say() { printf 'wtd-install: %s\n' "$1"; }
die() { printf 'wtd-install: error: %s\n' "$1" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
    fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
    fetch_stdout() { wget -qO- "$1"; }
else
    die "need curl or wget"
fi

case "$(uname -s)" in
    Linux) target_os="linux-musl" archive_ext="tar.gz" bin="wtd" ;;
    Darwin) target_os="macos" archive_ext="tar.gz" bin="wtd" ;;
    MINGW* | MSYS* | CYGWIN*) target_os="windows" archive_ext="zip" bin="wtd.exe" ;;
    *) die "unsupported OS: $(uname -s) (see https://github.com/$REPO/releases)" ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) target_arch="x86_64" ;;
    aarch64 | arm64) target_arch="aarch64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

version="${WTD_VERSION:-}"
if [ -z "$version" ]; then
    version=$(fetch_stdout "https://api.github.com/repos/$REPO/releases/latest" |
        grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/') ||
        die "could not query latest release"
fi
[ -n "$version" ] || die "could not determine latest version"

name="wtd-$version-$target_arch-$target_os"
asset="$name.$archive_ext"
base="https://github.com/$REPO/releases/download/$version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "downloading $asset ($version)"
fetch "$base/$asset" "$tmp/$asset"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

grep " $asset\$" "$tmp/SHA256SUMS" >"$tmp/wanted.sum" ||
    die "no checksum entry for $asset"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && sha256sum -c wanted.sum >/dev/null) || die "checksum verification FAILED"
elif command -v shasum >/dev/null 2>&1; then
    (cd "$tmp" && shasum -a 256 -c wanted.sum >/dev/null) || die "checksum verification FAILED"
else
    say "warning: no sha256sum/shasum found — skipping verification"
fi
say "checksum verified"

case "$archive_ext" in
    tar.gz) tar -xzf "$tmp/$asset" -C "$tmp" ;;
    zip)
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$tmp/$asset" -d "$tmp"
        else
            tar -xf "$tmp/$asset" -C "$tmp"
        fi
        ;;
esac
[ -f "$tmp/$name/$bin" ] || die "unexpected archive layout"

dir="${WTD_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
    if [ "$target_os" = "windows" ]; then
        dir="$HOME/bin"
    elif [ -w /usr/local/bin ]; then
        dir="/usr/local/bin"
    else
        dir="$HOME/.local/bin"
    fi
fi
mkdir -p "$dir"
cp "$tmp/$name/$bin" "$dir/$bin"
chmod 755 "$dir/$bin" 2>/dev/null || true

say "installed $("$dir/$bin" --version) → $dir/$bin"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) say "note: $dir is not on your PATH — add it to your shell profile" ;;
esac
