#!/data/data/com.termux/files/usr/bin/bash
# gen-flat-packages.sh — regenerate + upload the flat APT Packages.gz for this
# repo's rolling release, then verify it through the same channel apt consumes.
#
# Chain: list release .deb assets (gh api) -> download each (octet-stream) ->
# index (tools/gen_flat_packages.py, single-version doctrine) -> gzip -9n ->
# gh release upload --clobber -> re-download + assert.
#
# Usage: tools/gen-flat-packages.sh [TAG]
#   TAG defaults to $TAG env, else Push260803 (this repo's rolling release).
# Env knobs:
#   REPO        override owner/slug (derived from origin URL by default)
#   KEEP_DEBS=1 keep downloaded .debs in the temp dir (debug)
#
# DOWNLOAD CHANNELS (network-midbox survival):
#   1) `GODEBUG=http2client=0 gh api ... -H 'Accept: application/octet-stream'`
#      — forces gh's Go HTTP client onto HTTP/1.1. The midbox on some networks
#      kills long HTTP/2 streams with "stream error: PROTOCOL_ERROR" (observed
#      on 33-40MB release assets); HTTP/1.1 streams complete.
#   2) fallback: signed CDN redirect (tiny probe against api.github.com with
#      the gh token) + `curl --http1.1 -C -` against
#      release-assets.githubusercontent.com. Raw curl against github.com
#      itself is NEVER used (known to be cut mid-stream).
set -euo pipefail

REPO_FALLBACK="Hope2333/codegraph-termux"
TAG="${1:-${TAG:-Push260803}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/gen_flat_packages.py"

fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

for bin in gh python3 gzip git curl; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing dependency: $bin"
done
[ -f "$PY" ] || fail "missing $PY"

# --- repo slug: derive from origin URL of THIS repo (script-location anchored,
# never the caller's cwd), hardcode fallback ---------------------------------
REPO_ROOT="$(cd "$HERE/.." && pwd)"
origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
REPO="${REPO:-$(printf '%s' "$origin_url" | sed -E 's#.*github\.com[:/]##; s#\.git$##')}"
case "$REPO" in */*) ;; *) REPO="$REPO_FALLBACK";; esac
[ -n "$REPO" ] || REPO="$REPO_FALLBACK"
echo "REPO=$REPO TAG=$TAG"

# --- release status: prerelease/latest resolution ---------------------------
status="$(gh release view "$TAG" --repo "$REPO" --json tagName,isPrerelease,isDraft)" \
  || fail "release $TAG not found in $REPO"
pre="$(printf '%s' "$status" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["isPrerelease"]).lower())')"
latest_tag="$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || true)"
echo "RELEASE: tag=$TAG prerelease=$pre; /releases/latest resolves to ${latest_tag:-<none>}"
pinned_url="https://github.com/$REPO/releases/download/$TAG/Packages.gz"
alias_url="https://github.com/$REPO/releases/latest/download/Packages.gz"
echo "CANDIDATE pinned-tag URL:  $pinned_url"
echo "CANDIDATE latest-alias URL: $alias_url"
if [ "$latest_tag" = "$TAG" ]; then
  apt_url="$alias_url"
  echo "APT-URL-CORRECT: latest-alias (latest resolves to $TAG; not a prerelease)"
else
  apt_url="$pinned_url"
  echo "APT-URL-CORRECT: pinned-tag (latest resolves to ${latest_tag:-<none>}, NOT $TAG; prereleases are excluded from Latest resolution)"
fi
echo "SOURCES LINE: deb [trusted=yes] ${apt_url%Packages.gz} ./"

# --- asset download (dual channel, size-checked) -----------------------------
fetch_asset() {
  local aid="$1" asize="$2" dest="$3"
  if GODEBUG=http2client=0 gh api "repos/$REPO/releases/assets/$aid" \
      -H 'Accept: application/octet-stream' > "$dest" 2>/dev/null \
      && [ "$(wc -c < "$dest" | tr -d ' ')" = "$asize" ]; then
    echo "  channel: gh-api(http1.1)"
    return 0
  fi
  echo "  gh-api channel failed/short — fallback to signed-URL curl(http1.1)"
  local token loc
  token="$(gh auth token)" || return 1
  loc="$(curl -s --http1.1 -o /dev/null -w '%{redirect_url}' \
    -H "Authorization: token $token" -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/$REPO/releases/assets/$aid")"
  [ -n "$loc" ] || return 1
  curl -sS --http1.1 --retry 3 --retry-delay 2 -C - -o "$dest" "$loc" || return 1
  [ "$(wc -c < "$dest" | tr -d ' ')" = "$asize" ] || return 1
  echo "  channel: signed-url curl(http1.1)"
  return 0
}

# --- temp workspace ----------------------------------------------------------
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/flatpkgs.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
state="$tmpdir/state.json"

# --- list .deb assets --------------------------------------------------------
gh api "repos/$REPO/releases/tags/$TAG" --paginate \
  --jq '.assets[] | select(.name | endswith(".deb")) | "\(.id)\t\(.name)\t\(.size)"' \
  > "$tmpdir/assets.tsv" || fail "failed to list assets of $TAG"
deb_count="$(wc -l < "$tmpdir/assets.tsv" | tr -d ' ')"
[ "$deb_count" -ge 1 ] || fail "no .deb assets on release $TAG — nothing to index"
echo "ASSETS: $deb_count .deb file(s) on $TAG"

# --- download + index + delete, one deb at a time (disk hygiene) -------------
while IFS=$'\t' read -r aid aname asize; do
  [ -n "$aid" ] || continue
  dest="$tmpdir/$aname"
  echo "DOWNLOAD $aname ($asize bytes)"
  fetch_asset "$aid" "$asize" "$dest" || fail "asset download failed: $aname"
  python3 "$PY" add --deb "$dest" --state "$state" || fail "index add failed: $aname"
  if [ "${KEEP_DEBS:-0}" = "1" ]; then
    echo "  indexed (kept: KEEP_DEBS=1)"
  else
    rm -f "$dest"
    echo "  indexed + deleted"
  fi
done < "$tmpdir/assets.tsv"

# --- finalize: single-version filter + gzip -9n + guards ---------------------
out="$tmpdir/Packages.gz"
if ! python3 "$PY" finalize --state "$state" --out "$out" > "$tmpdir/finalize.log" 2>&1; then
  cat "$tmpdir/finalize.log" >&2
  fail "finalize failed"
fi
cat "$tmpdir/finalize.log"
entries="$(sed -n 's/^PACKAGES_INDEX .* entries=\([0-9]*\) bytes=.*/\1/p' "$tmpdir/finalize.log")"
[ -n "$entries" ] && [ "$entries" -ge 1 ] || fail "guard: zero-entry index — refusing to upload"
[ -s "$out" ] || fail "guard: empty Packages.gz — refusing to upload"
grep '^ENTRY ' "$tmpdir/finalize.log" > "$tmpdir/expected.tsv" || true

# --- upload (--clobber) ------------------------------------------------------
gh release upload "$TAG" "$out" --repo "$REPO" --clobber \
  || fail "gh release upload failed"
echo "UPLOADED Packages.gz -> release $TAG (--clobber)"

# --- verify: re-download via gh api (same content the apt URL serves) --------
pkg_id="$(gh api "repos/$REPO/releases/tags/$TAG" --paginate \
  --jq '.assets[] | select(.name == "Packages.gz") | .id' | head -n1)"
[ -n "$pkg_id" ] || fail "Packages.gz asset not found after upload"
GODEBUG=http2client=0 gh api "repos/$REPO/releases/assets/$pkg_id" \
  -H 'Accept: application/octet-stream' > "$tmpdir/Packages.gz.verify" \
  || fail "verification download failed"
if ! python3 "$PY" inspect "$tmpdir/Packages.gz.verify" > "$tmpdir/inspect.log" 2>&1; then
  cat "$tmpdir/inspect.log" >&2
  fail "verification parse failed"
fi
cat "$tmpdir/inspect.log"
vcount="$(sed -n 's/^PACKAGES_INDEX .* entries=\([0-9]*\).*/\1/p' "$tmpdir/inspect.log")"
[ "$vcount" = "$entries" ] || fail "entry count drift: generated=$entries verified=$vcount"
while IFS=$'\t' read -r vpkg vfile; do
  [ -n "$vpkg" ] || continue
  grep -qF "$(printf '%s\t%s' "$vpkg" "$vfile")" "$tmpdir/expected.tsv" \
    || fail "verification mismatch: ($vpkg, $vfile) not in freshly generated manifest"
done < <(sed -n 's/^ENTRY //p' "$tmpdir/inspect.log")

bytes="$(wc -c < "$out" | tr -d ' ')"
echo "DONE repo=$REPO tag=$TAG entries=$entries bytes=$bytes"
echo "APT URL (correct): $apt_url"
