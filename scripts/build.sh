#!/data/data/com.termux/files/usr/bin/bash
# scripts/build.sh — Stage the codegraph runtime into a package-ready prefix
#
# Ported from opencode-termux's scripts/build.sh. Assembles
# artifacts/staged/prefix/ in the final install layout:
#   prefix/bin/codegraph                      (compiled C wrapper)
#   prefix/lib/codegraph-termux/<version>/    (extracted bundle, node patched)
#   prefix/lib/codegraph-termux/current -> <version>
#
# The wrapper resolves its runtime relative to itself, so the staged prefix
# behaves exactly like the packaged install (testable before packaging).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"

RUNTIME_INPUT="${CODEGRAPH_RUNTIME_INPUT:-$ROOT_DIR/artifacts/codegraph/runtime/codegraph-termux}"
OUT_DIR="${CODEGRAPH_OUT_DIR:-$ROOT_DIR/artifacts/staged}"
PREFIX_DIR="${CODEGRAPH_PREFIX_DIR:-$OUT_DIR/prefix}"

[[ -d "$RUNTIME_INPUT" ]] || fail "no runtime at $RUNTIME_INPUT — run 'make runtime' first"
[[ -x "$RUNTIME_INPUT/node" ]] || fail "runtime bundle missing node binary"

# Read codegraph version from the bundle's package.json
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
	"$RUNTIME_INPUT/lib/package.json" 2>/dev/null | head -n1)"
[[ -n "$VERSION" ]] || fail "cannot read version from $RUNTIME_INPUT/lib/package.json"
log "staging codegraph v$VERSION"

# Fresh stage
rm -rf "$PREFIX_DIR"
ensure_dir "$PREFIX_DIR/lib/codegraph-termux"
ensure_dir "$PREFIX_DIR/bin"

# Bundle
cp -a "$RUNTIME_INPUT" "$PREFIX_DIR/lib/codegraph-termux/$VERSION"
ln -sfn "$VERSION" "$PREFIX_DIR/lib/codegraph-termux/current"
log "installed bundle: lib/codegraph-termux/$VERSION (current -> $VERSION)"

# Wrapper (self-relative resolution makes the -D fallbacks irrelevant at runtime)
log "compiling wrapper -> $PREFIX_DIR/bin/codegraph"
bash "$ROOT_DIR/scripts/compile-wrapper.sh" "$PREFIX_DIR/bin/codegraph"

# Verify staged runtime end to end
if "$PREFIX_DIR/bin/codegraph" --version >/dev/null 2>&1; then
	log "staged runtime OK: $("$PREFIX_DIR/bin/codegraph" --version)"
else
	fail "staged runtime version check failed"
fi

write_build_meta "$ROOT_DIR/artifacts/codegraph/build.meta" \
	"component=codegraph" \
	"version=$VERSION" \
	"prefix=$PREFIX_DIR" \
	"runtime_path=$PREFIX_DIR/lib/codegraph-termux/$VERSION/node"

log "staged build ready: $PREFIX_DIR"
