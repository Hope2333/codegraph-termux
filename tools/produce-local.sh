#!/data/data/com.termux/files/usr/bin/bash
# tools/produce-local.sh — Produce the codegraph runtime for Termux
#
# Ported from opencode-termux's tools/produce-local.sh. Downloads the
# upstream release tarball (colbymchenry/codegraph), patches the bundled
# glibc node (single patchelf --set-interpreter — never --set-rpath, never
# twice: both corrupt the 121 MB binary), and caches the result so repeat
# builds are instant.
#
# Usage: tools/produce-local.sh [version]
#   version omitted -> resolve latest from GitHub releases/latest redirect
# Env:
#   CODEGRAPH_TARBALL=/path/to/codegraph-linux-arm64.tar.gz  (offline builds)
#   CACHE_DIR (default: $HOME/.cache/codegraph-termux)
# Output:
#   artifacts/codegraph/runtime/codegraph-termux/  (extracted bundle, node patched)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/artifacts/codegraph/runtime"
RUNTIME_OUT="$RUNTIME_DIR/codegraph-termux"
INPUT_VER="${1:-}"

log() { printf '[produce] %s\n' "$*"; }
die() { printf '[produce] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
[ -f "$GLIBC_LD" ] || die "glibc not found: $GLIBC_LD (pkg install glibc)"
need patchelf
need tar
if [[ -z "${CODEGRAPH_TARBALL:-}" ]]; then
	need curl
fi

# ── resolve version ──────────────────────────────────────────────────────────
if [[ -z "$INPUT_VER" ]]; then
	log "Resolving latest codegraph version from GitHub releases..."
	if ! INPUT_VER="$(curl -fsSL https://github.com/colbymchenry/codegraph/releases/latest 2>/dev/null \
		| sed -n 's#.*/tag/v\([0-9][0-9.]*\).*#\1#p' | head -n1)"; then
		die "failed to resolve latest version (offline? pass a version explicitly)"
	fi
fi
[[ -n "$INPUT_VER" ]] || die "no version specified"
VER="$INPUT_VER"
log "codegraph v$VER"

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/codegraph-termux}"
CACHE_BUNDLE="$CACHE_DIR/codegraph-$VER"
EXTRACT="${TMPDIR:-$PREFIX/tmp}/produce-$$"
mkdir -p "$RUNTIME_DIR" "$CACHE_DIR" "$EXTRACT"
trap 'rm -rf "$EXTRACT"' EXIT

# ── cache check ──────────────────────────────────────────────────────────────
cached_ok() {
	[[ -x "$CACHE_BUNDLE/node" ]] || return 1
	[[ -f "$CACHE_BUNDLE/lib/dist/bin/codegraph.js" ]] || return 1
	local cached_ver
	cached_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
		"$CACHE_BUNDLE/lib/package.json" 2>/dev/null | head -n1)"
	[[ -n "$cached_ver" && "$cached_ver" = "$VER" ]] || return 1
	return 0
}

if cached_ok; then
	log "cache hit: $CACHE_BUNDLE"
	rm -rf "$RUNTIME_OUT"
	cp -a "$CACHE_BUNDLE" "$RUNTIME_OUT"
	rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packaging/dpkg/work" "$ROOT_DIR/packaging/pacman/src"
	log "DONE"
	exit 0
fi

# ── download + extract ───────────────────────────────────────────────────────
cd "$EXTRACT"
if [[ -n "${CODEGRAPH_TARBALL:-}" ]]; then
	log "using local tarball: $CODEGRAPH_TARBALL"
	cp "$CODEGRAPH_TARBALL" "codegraph-linux-arm64.tar.gz"
else
	local_url="https://github.com/colbymchenry/codegraph/releases/download/v${VER}/codegraph-linux-arm64.tar.gz"
	log "downloading $local_url"
	curl -fL --retry 3 -o "codegraph-linux-arm64.tar.gz" "$local_url"
fi
tar -xzf codegraph-linux-arm64.tar.gz
RAW="codegraph-linux-arm64"
[[ -x "$RAW/node" ]] || die "bundled node not found in tarball"

# ── patch bundled node: single patchelf, interpreter only ────────────────────
INTERP="$(patchelf --print-interpreter "$RAW/node" 2>/dev/null || true)"
if [[ "$INTERP" != "$GLIBC_LD" ]]; then
	log "patching node interpreter -> $GLIBC_LD"
	patchelf --set-interpreter "$GLIBC_LD" "$RAW/node"
fi
[[ "$(head -c4 "$RAW/node")" = $'\x7fELF' ]] || die "node corrupted after patchelf"

# ── install into runtime dir + cache ─────────────────────────────────────────
rm -rf "$RUNTIME_OUT" "$CACHE_BUNDLE"
cp -a "$RAW" "$RUNTIME_OUT"
mkdir -p "$CACHE_DIR"
cp -a "$RAW" "$CACHE_BUNDLE"
log "runtime ready: $RUNTIME_OUT"

rm -rf "$ROOT_DIR/artifacts/staged" "$ROOT_DIR/packaging/dpkg/work" "$ROOT_DIR/packaging/pacman/src"
log "DONE"
