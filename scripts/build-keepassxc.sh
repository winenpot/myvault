#!/usr/bin/env bash
# Build KeePassXC from upstream/keepassxc following upstream INSTALL.md.
# Usage: scripts/build-keepassxc.sh --check-deps
set -euo pipefail

DEPS=(asciidoctor qt6-base-dev qt6-base-private-dev qt6-svg-dev qt6-tools-dev
  qt6-tools-dev-tools qt6-l10n-tools libusb-1.0-0-dev libbotan-3-dev zlib1g-dev
  libminizip-dev libpcsclite-dev libkeyutils-dev libxi-dev libxtst-dev
  libqrencode-dev libxkbcommon-dev libreadline-dev xvfb)

check_deps() {
  local missing=()
  for p in "${DEPS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing+=("$p")
  done
  if ((${#missing[@]})); then
    echo "MISSING: ${missing[*]}"
    echo "Run: sudo apt install ${missing[*]}"
    return 1
  fi
  echo "OK: all build deps installed"
}

case "${1:-}" in
  --check-deps) check_deps ;;
  *) echo "usage: $0 --check-deps" >&2; exit 2 ;;
esac
