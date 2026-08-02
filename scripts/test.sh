#!/data/data/com.termux/files/usr/bin/bash
#
# test.sh — End-to-end tests for codegraph-termux
#
# Usage: bash scripts/test.sh
#
# Mirrors the harness used by sibling repos (codebuff-termux etc.):
# every check prints PASS / FAIL / SKIP; exits non-zero if any FAIL.

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WRAPPER="$PREFIX/bin/codegraph"
INSTALL_DIR="${CODEGRAPH_INSTALL_DIR:-$PREFIX/lib/codegraph-termux}"
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
TMP_TEST="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/cg-test.XXXXXX")"
FAKE_DIR="${TMPDIR:-$PREFIX/tmp}/.codegraph-fake"

PASS=0; FAIL=0; SKIP=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf 'SKIP: %s\n' "$1"; SKIP=$((SKIP+1)); }
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

cleanup() { rm -rf "$TMP_TEST"; }
trap cleanup EXIT

# ── 1. installed layout ──────────────────────────────────────────────────────
[ -x "$WRAPPER" ];                     check $? "wrapper executable exists at $WRAPPER"
[ -x "$INSTALL_DIR/current/node" ];    check $? "bundled node exists (current/node)"

if [ -x "$INSTALL_DIR/current/node" ]; then
    # ── 2. node is a valid ELF with the glibc interpreter ──────────────────
    MAGIC="$(head -c4 "$INSTALL_DIR/current/node")"
    [ "$MAGIC" = $'\x7fELF' ];         check $? "node is a valid ELF (not corrupted by patchelf)"
    INTERP="$(patchelf --print-interpreter "$INSTALL_DIR/current/node" 2>/dev/null || true)"
    [ "$INTERP" = "$GLIBC_LD" ];       check $? "node interpreter is Termux glibc ($INTERP)"

    # ── 3. wrapper is a bionic ELF (compiled on-device, not for glibc) ──────
    FILE_OUT="$(file "$WRAPPER" 2>/dev/null)"
    echo "$FILE_OUT" | grep -q "aarch64";  check $? "wrapper is aarch64 ELF"

    # ── 4. version works (through proot, with CPU fakes) ────────────────────
    VER_OUT="$("$WRAPPER" --version 2>&1)"; VER_RC=$?
    [ $VER_RC -eq 0 ] && [ -n "$VER_OUT" ]
    check $? "codegraph --version works (v${VER_OUT})"
fi

# ── 5. os.cpus() sees real cores (proot /proc/stat fake) ─────────────────────
#    os.cpus() returns 0 on raw Termux because /proc/stat and /proc/loadavg
#    are Permission denied; the wrapper's proot bind of its fake files fixes
#    it. Verify the same bind works for the bundle node directly:
if command -v proot >/dev/null && [ -x "$INSTALL_DIR/current/node" ]; then
    NODE="$INSTALL_DIR/current/node"
    if [ -f "$FAKE_DIR/stat" ]; then
        CPUS="$(proot \
            -b "$FAKE_DIR/stat:/proc/stat" \
            -b "$FAKE_DIR/cpuinfo:/proc/cpuinfo" \
            -b "$FAKE_DIR/loadavg:/proc/loadavg" \
            -b "$FAKE_DIR/cpu-present:/sys/devices/system/cpu/present" \
            -b "$FAKE_DIR/cpu-online:/sys/devices/system/cpu/online" \
            env -i PATH="$PREFIX/bin" "$NODE" -e 'console.log(require("os").cpus().length)' 2>/dev/null || echo 0)"
        [ "$CPUS" -ge 1 ] 2>/dev/null;  check $? "os.cpus() reports >= 1 core (got: $CPUS)"
    else
        skip "os.cpus test (fake files not created yet — run wrapper once first)"
    fi
else
    skip "os.cpus test (proot or node missing)"
fi

# ── 6. fake /proc files are created by the wrapper at runtime ────────────────
[ -f "$FAKE_DIR/stat" ] && [ -f "$FAKE_DIR/loadavg" ]
check $? "wrapper created fake /proc/stat + /proc/loadavg ($FAKE_DIR)"

# ── 7. MCP liveness: daemon subcommand at least parses ───────────────────────
"$WRAPPER" daemons >/dev/null 2>&1;     check $? "codegraph daemons subcommand runs"

# ── 8. real project index smoke test ─────────────────────────────────────────
if [ -x "$WRAPPER" ]; then
    mkdir -p "$TMP_TEST/repo"
    printf 'function hello() { return 42; }\nclass Foo { bar() {} }\n' > "$TMP_TEST/repo/a.js"
    ( cd "$TMP_TEST/repo" && git init -q && git add a.js && \
        git -c user.email=t@t -c user.name=t commit -qm init )
    INIT_OUT="$(cd "$TMP_TEST/repo" && "$WRAPPER" init 2>&1)"; INIT_RC=$?
    [ $INIT_RC -eq 0 ]
    check $? "codegraph init works (bionic git spawn)"
    IDX_OUT="$(cd "$TMP_TEST/repo" && "$WRAPPER" index 2>&1)"; IDX_RC=$?
    [ $IDX_RC -eq 0 ]
    check $? "codegraph index works in a git repo (bionic git spawn)"
    echo "    $IDX_OUT" | grep -q "Indexed" && echo "       -> $(echo "$IDX_OUT" | tail -n1)"
    ST_OUT="$(cd "$TMP_TEST/repo" && "$WRAPPER" status 2>&1)"
    echo "$ST_OUT" | grep -qi "up to date"
    check $? "codegraph status reports index up to date"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo
printf 'TOTAL: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
