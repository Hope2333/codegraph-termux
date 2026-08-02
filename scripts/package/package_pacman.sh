#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_pacman.sh — Build the Termux pacman package
#
# Ported from opencode-termux's scripts/package/package_pacman.sh.
# Runs makepkg with a PKGBUILD that packs artifacts/staged/prefix.
# Version: $VERSION env or read from the staged bundle's package.json.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"

[[ -x "$STAGED_PREFIX/lib/codegraph-termux/current/node" ]] || {
	echo "Error: missing staged runtime" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/codegraph" ]] || {
	echo "Error: missing staged wrapper" >&2
	exit 1
}

# Version: explicit VERSION env, else from the staged bundle's package.json
if [[ -z "${VERSION:-}" ]]; then
	VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
		"$STAGED_PREFIX/lib/codegraph-termux/current/lib/package.json" 2>/dev/null | head -n1)"
fi
[[ -n "$VERSION" ]] || { echo "Error: unable to determine version (set VERSION=...)" >&2; exit 1; }

cd "$ROOT_DIR/packaging/pacman"
rm -rf "$ROOT_DIR/packaging/pacman/pkg" "$ROOT_DIR/packaging/pacman/src"

TMP_MAKEPKG_CONF="$ROOT_DIR/packaging/pacman/.makepkg-codegraph.conf"
TMP_PKGBUILD="$ROOT_DIR/packaging/pacman/.PKGBUILD.codegraph.tmp"
cleanup() {
	rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"
}
trap cleanup EXIT

cp /data/data/com.termux/files/usr/etc/makepkg.conf "$TMP_MAKEPKG_CONF"
printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"

cp "$ROOT_DIR/packaging/pacman/PKGBUILD" "$TMP_PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"

STAGED_PREFIX="$STAGED_PREFIX" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"

echo "Pacman package created under: $ROOT_DIR/packaging/pacman"
