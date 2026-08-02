#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_deb.sh — Build the Termux .deb package
#
# Ported from opencode-termux's scripts/package/package_deb.sh.
# Packages artifacts/staged/prefix into a dpkg .deb.
# Version: $VERSION env or read from the staged bundle's package.json.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"

command -v dpkg-deb >/dev/null 2>&1 || { echo "Error: dpkg-deb not found" >&2; exit 1; }
if [[ -z "${ARCH_DEB:-}" ]]; then
	ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo aarch64)"
fi

[[ -x "$STAGED_PREFIX/bin/codegraph" ]] || { echo "Error: missing staged wrapper" >&2; exit 1; }
[[ -x "$STAGED_PREFIX/lib/codegraph-termux/current/node" ]] || { echo "Error: missing staged runtime" >&2; exit 1; }

# Version: explicit VERSION env, else from the staged bundle's package.json
if [[ -z "${VERSION:-}" ]]; then
	VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
		"$STAGED_PREFIX/lib/codegraph-termux/current/lib/package.json" 2>/dev/null | head -n1)"
fi
[[ -n "$VERSION" ]] || { echo "Error: unable to determine version (set VERSION=...)" >&2; exit 1; }

DEB_ROOT="$ROOT_DIR/packaging/dpkg/work"
OUT_DIR="$ROOT_DIR/packaging/dpkg"
OUT_FILE="$OUT_DIR/codegraph_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: codegraph
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Description: CodeGraph — local-first code intelligence for AI agents (MCP), for Termux
Depends: glibc, bash
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "CodeGraph for Termux installed"
echo "Run: codegraph init  (in your project) then: codegraph index"
echo "Runtime: glibc node (patchelf interpreter) via proot CPU fakes"
echo "If os.cpus() reports 0 cores: pkg install proot"
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

cat >"$DEB_ROOT/DEBIAN/prerm" <<'PRERM'
#!/data/data/com.termux/files/usr/bin/bash
set -e
exit 0
PRERM
chmod 755 "$DEB_ROOT/DEBIAN/prerm"

cat >"$DEB_ROOT/DEBIAN/postrm" <<'POSTRM'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "CodeGraph for Termux removed"
exit 0
POSTRM
chmod 755 "$DEB_ROOT/DEBIAN/postrm"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
