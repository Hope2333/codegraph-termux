#!/data/data/com.termux/files/usr/bin/bash
#
# compile-wrapper.sh — Compile the codegraph C wrapper (Bionic ELF) for Termux
#
# Usage: bash scripts/compile-wrapper.sh [output-path]
#   output-path defaults to scripts/codegraph-wrapper
#
# Env:
#   PREFIX      (default: /data/data/com.termux/files/usr)  — -D default paths
#   PROOT_PATH  (default: $PREFIX/bin/proot)
#   FAKE_DIR    (default: ${TMPDIR:-$PREFIX/tmp}/.codegraph-fake)
#
# The wrapper resolves node/JS paths relative to its own location at runtime
# (<self-prefix>/lib/codegraph-termux/current/...), so the -D values are only
# fallbacks — the same binary works from a staged prefix and after packaging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

WRAPPER_SRC="$SCRIPT_DIR/codegraph-wrapper.c"
WRAPPER_OUT="${1:-$SCRIPT_DIR/codegraph-wrapper}"

NODE_PATH="${PREFIX}/lib/codegraph-termux/current/node"
CODEGRAPH_JS="${PREFIX}/lib/codegraph-termux/current/lib/dist/bin/codegraph.js"
PROOT_PATH="${PROOT_PATH:-$PREFIX/bin/proot}"
FAKE_DIR="${FAKE_DIR:-${TMPDIR:-${PREFIX}/tmp}/.codegraph-fake}"

command -v gcc >/dev/null || { echo "gcc required: pkg install gcc"; exit 1; }

mkdir -p "$(dirname "$WRAPPER_OUT")"

echo "[*] Compiling C wrapper (Bionic ELF) -> $WRAPPER_OUT"
gcc -O2 -s -o "$WRAPPER_OUT" "$WRAPPER_SRC" \
    -DNODE_PATH='"'"$NODE_PATH"'"' \
    -DCODEGRAPH_JS='"'"$CODEGRAPH_JS"'"' \
    -DPROOT_PATH='"'"$PROOT_PATH"'"' \
    -DFAKE_DIR='"'"$FAKE_DIR"'"'
chmod 755 "$WRAPPER_OUT"

file "$WRAPPER_OUT" | sed "s/^/    /"
echo ""
echo "    NODE_PATH  = $NODE_PATH (fallback; self-relative at runtime)"
echo "    JS_ENTRY   = $CODEGRAPH_JS (fallback)"
echo "    PROOT      = $PROOT_PATH"
echo "    FAKE_DIR   = $FAKE_DIR"
