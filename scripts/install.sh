#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — Install codegraph (colbymchenry/codegraph) on Termux
#
# Usage:
#   bash scripts/install.sh            # latest release
#   bash scripts/install.sh 1.5.0      # specific version
#
# Env:
#   CODEGRAPH_TARBALL=/path/to/codegraph-linux-arm64.tar.gz   # use a local tarball
#   CODEGRAPH_INSTALL_DIR=...          # default: $PREFIX/lib/codegraph-termux
#   PREFIX=...                         # default: /data/data/com.termux/files/usr
#
# What it does:
#   1. resolve the version (GitHub releases/latest redirect, like upstream)
#   2. download + extract the release tarball (strip-components=1)
#   3. patchelf the bundled glibc node: single shot, --set-interpreter ONLY
#      (a second patchelf or any --set-rpath corrupts the 121 MB binary;
#       Termux's glibc ld.so has /data/data/com.termux/files/usr/glibc/lib/
#       compiled in as its default search path, so NO LD_LIBRARY_PATH needed)
#   4. compile the bionic C wrapper -> $PREFIX/bin/codegraph
#      (clears LD_*, fakes /proc/stat + /proc/loadavg via proot so
#       os.cpus() works on Android, binds them + /proc/cpuinfo and
#       /sys/devices/system/cpu/{present,online})
#   5. symlink .../codegraph-termux/current -> version

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${CODEGRAPH_INSTALL_DIR:-$PREFIX/lib/codegraph-termux}"
BIN_DIR="$PREFIX/bin"
TMP_DIR="${TMPDIR:-$PREFIX/tmp}/codegraph-termux-install"
ARCHIVE="$TMP_DIR/codegraph-linux-arm64.tar.gz"
URL_TEMPLATE="https://github.com/colbymchenry/codegraph/releases/download/v%s/codegraph-linux-arm64.tar.gz"
RELEASES_URL="https://github.com/colbymchenry/codegraph/releases/latest"

VERSION="${1:-}"

say()  { printf '[codegraph-termux] %s\n' "$*"; }
die()  { printf '[codegraph-termux] ERROR: %s\n' "$*" >&2; exit 1; }

# ── dependency checks ────────────────────────────────────────────────────────
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
[ -f "$GLIBC_LD" ] || die "glibc not found: $GLIBC_LD (pkg install glibc)"
command -v patchelf >/dev/null || die "patchelf not found (pkg install patchelf)"
command -v gcc      >/dev/null || die "gcc not found (pkg install gcc)"
command -v proot    >/dev/null || echo "warning: proot not found (pkg install proot) — CPU fakes will be skipped"

FETCHER=""
if command -v curl >/dev/null; then FETCHER="curl"; elif command -v wget >/dev/null; then FETCHER="wget"; fi
[ -n "$FETCHER" ] || die "curl or wget required (pkg install curl)"

# ── resolve version ──────────────────────────────────────────────────────────
if [ -z "$VERSION" ]; then
    say "Resolving latest codegraph version..."
    VERSION="$($FETCHER -fsSL "$RELEASES_URL" 2>/dev/null \
        | sed -n 's#.*/tag/v\([0-9][0-9.]*\).*#\1#p' | head -n1)"
    [ -n "$VERSION" ] || die "could not resolve latest version (offline? try: bash scripts/install.sh 1.5.0)"
fi
say "Installing codegraph v$VERSION"

# ── prepare ──────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$TMP_DIR"
TARGET="$INSTALL_DIR/$VERSION"
if [ -e "$TARGET" ]; then
    say "Already installed at $TARGET (reuse). Remove it to force a reinstall."
else
    # ── download ──────────────────────────────────────────────────────────
    if [ -n "${CODEGRAPH_TARBALL:-}" ]; then
        say "Using local tarball: $CODEGRAPH_TARBALL"
        cp "$CODEGRAPH_TARBALL" "$ARCHIVE"
    else
        URL="$(printf "$URL_TEMPLATE" "$VERSION")"
        say "Downloading $URL"
        if [ "$FETCHER" = "curl" ]; then
            curl -fL --retry 3 -o "$ARCHIVE" "$URL"
        else
            wget -qO "$ARCHIVE" "$URL"
        fi
    fi

    # ── extract ───────────────────────────────────────────────────────────
    say "Extracting to $TARGET"
    mkdir -p "$TARGET.tmp"
    tar -xzf "$ARCHIVE" -C "$TARGET.tmp" --strip-components=1
    rm -rf "$TARGET"
    mv "$TARGET.tmp" "$TARGET"
fi

# ── patch bundled node: single patchelf, interpreter only ───────────────────
NODE="$TARGET/node"
[ -f "$NODE" ] || die "node not found in tarball: $NODE"
INTERP="$(patchelf --print-interpreter "$NODE" 2>/dev/null || true)"
if [ "$INTERP" != "$GLIBC_LD" ]; then
    say "Patching node interpreter -> $GLIBC_LD (single patchelf; --set-rpath corrupts the binary)"
    patchelf --set-interpreter "$GLIBC_LD" "$NODE"
fi
# sanity: ensure it is still a valid ELF after patching
head -c4 "$NODE" | grep -q $'\x7fELF' || die "node corrupted after patchelf — restore from tarball"

# ── build wrapper ────────────────────────────────────────────────────────────
say "Building C wrapper (bionic ELF) -> $BIN_DIR/codegraph"
bash "$SCRIPT_DIR/compile-wrapper.sh" "$BIN_DIR/codegraph"
chmod 755 "$BIN_DIR/codegraph"

# ── symlink current ──────────────────────────────────────────────────────────
ln -sfn "$TARGET" "$INSTALL_DIR/current"
say "current -> $TARGET"

# ── smoke test ───────────────────────────────────────────────────────────────
if "$BIN_DIR/codegraph" --version >/dev/null 2>&1; then
    say "OK: $("$BIN_DIR/codegraph" --version)"
else
    echo "warning: 'codegraph --version' failed — see troubleshooting in README.cn.md"
fi

echo
say "Installed. Run 'codegraph init' in your project to start."
say "Uninstall: rm -rf $INSTALL_DIR $BIN_DIR/codegraph"
