#!/usr/bin/env sh
# ZiggyZag install script for Linux and macOS.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/PascalAI2024/ZiggyZag/master/scripts/install.sh | sh
#
# Or, to install a specific version:
#   curl -sSL https://raw.githubusercontent.com/PascalAI2024/ZiggyZag/master/scripts/install.sh | ZZ_VERSION=v0.1.0-alpha.2 sh
#
# Environment variables:
#   ZZ_VERSION       Release tag to install (default: latest)
#   ZZ_INSTALL_DIR   Where to drop binaries (default: ~/.ziggyzag/bin)
#
# What this script does:
#   1. Detects platform (linux/macos, x86_64/aarch64)
#   2. Downloads the matching release zip
#   3. Verifies SHA256 against the published checksums file
#   4. Extracts to ZZ_INSTALL_DIR
#   5. Prints a single-line export to add the binaries to PATH

set -eu

REPO="PascalAI2024/ZiggyZag"
INSTALL_DIR="${ZZ_INSTALL_DIR:-$HOME/.ziggyzag/bin}"
VERSION="${ZZ_VERSION:-}"

bold() { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m%s\033[0m" "$1"; }
red() { printf "\033[31m%s\033[0m" "$1"; }
dim() { printf "\033[2m%s\033[0m" "$1"; }

err() {
  printf "%s: %s\n" "$(red "install.sh")" "$1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"
}

need curl
need unzip
need uname

# --- Detect platform --------------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
  linux*)  TARGET_OS="linux" ;;
  darwin*) TARGET_OS="macos" ;;
  *)       err "unsupported OS: $OS (only linux and macos)" ;;
esac

case "$ARCH" in
  x86_64|amd64)   TARGET_ARCH="x86_64" ;;
  aarch64|arm64)  TARGET_ARCH="aarch64" ;;
  *)              err "unsupported arch: $ARCH (only x86_64 and aarch64)" ;;
esac

TARGET="${TARGET_OS}-${TARGET_ARCH}"

# --- Resolve version --------------------------------------------------------
if [ -z "$VERSION" ]; then
  printf "%s resolving latest release...\n" "$(dim "->")"
  # GitHub's "latest" redirect; we follow it and pull the tag from the URL.
  VERSION="$(curl -sSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||')"
  [ -n "$VERSION" ] || err "could not resolve latest release tag"
fi

ARCHIVE_NAME="ZiggyZag-${VERSION}-${TARGET}.zip"
CHECKSUMS_NAME="checksums.sha256"
DOWNLOAD_BASE="https://github.com/$REPO/releases/download/$VERSION"

printf "\n%s\n" "$(bold "Installing ZiggyZag $VERSION for $TARGET")"
printf "  archive:    %s\n" "$ARCHIVE_NAME"
printf "  install to: %s\n\n" "$INSTALL_DIR"

# --- Download and verify ----------------------------------------------------
TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t ziggyzag-install)"
trap 'rm -rf "$TMPDIR"' EXIT

printf "%s downloading archive...\n" "$(dim "->")"
curl -sSL -o "$TMPDIR/$ARCHIVE_NAME" "$DOWNLOAD_BASE/$ARCHIVE_NAME" \
  || err "download failed (tried $DOWNLOAD_BASE/$ARCHIVE_NAME)"

printf "%s downloading checksums...\n" "$(dim "->")"
curl -sSL -o "$TMPDIR/$CHECKSUMS_NAME" "$DOWNLOAD_BASE/$CHECKSUMS_NAME" \
  || err "checksum file download failed"

printf "%s verifying SHA256...\n" "$(dim "->")"
EXPECTED="$(grep "  $ARCHIVE_NAME$" "$TMPDIR/$CHECKSUMS_NAME" | awk '{print $1}')"
[ -n "$EXPECTED" ] || err "no checksum entry for $ARCHIVE_NAME in $CHECKSUMS_NAME"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMPDIR/$ARCHIVE_NAME" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$TMPDIR/$ARCHIVE_NAME" | awk '{print $1}')"
else
  err "no sha256sum or shasum on PATH"
fi

[ "$EXPECTED" = "$ACTUAL" ] || err "checksum mismatch (expected $EXPECTED, got $ACTUAL)"
printf "   %s checksum matches\n" "$(green "✓")"

# --- Install ----------------------------------------------------------------
printf "%s extracting...\n" "$(dim "->")"
mkdir -p "$INSTALL_DIR"
unzip -qo "$TMPDIR/$ARCHIVE_NAME" -d "$TMPDIR/extracted"

# Each zip ships a top-level ZiggyZag launcher and a bin/ directory.
# Copy bin/* into the install dir so all four binaries land together.
if [ -d "$TMPDIR/extracted/bin" ]; then
  cp -f "$TMPDIR/extracted/bin/"* "$INSTALL_DIR/"
else
  # Older layout: flat zip
  find "$TMPDIR/extracted" -maxdepth 2 -type f -name 'ziggyzag*' -exec cp -f {} "$INSTALL_DIR/" \;
fi

chmod +x "$INSTALL_DIR/"* 2>/dev/null || true

# --- Done -------------------------------------------------------------------
printf "\n%s installed to %s\n\n" "$(green "✓")" "$INSTALL_DIR"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf "%s add to your shell rc:\n\n" "$(bold "Next:")"
    printf "  export PATH=\"%s:\$PATH\"\n\n" "$INSTALL_DIR"
    ;;
esac

printf "Try it:\n"
printf "  %s\n" "$INSTALL_DIR/ziggyzag        # then type 'about' for version info"
printf "\nDocs: https://github.com/$REPO\n"
