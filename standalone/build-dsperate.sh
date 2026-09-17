#!/usr/bin/env bash
# Build the standalone DSperate executable for the Miniloong Pocket 1.
#
# Self-contained on purpose. A clean clone of THIS repository plus Docker is
# the entire toolchain: no sibling checkouts, no UMRK workspace layout, no
# locally built images. Everything it needs is pinned in
# standalone/upstream.lock.json.
#
#   ./standalone/build-dsperate.sh              build into build/, verify the lock
#   FORCE=1 ./standalone/build-dsperate.sh      rebuild from a clean tree
#
# The source clone and the CMake build tree are cached under build/ so a second
# run is cheap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/standalone/upstream.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
SRC_DIR="$BUILD_DIR/dsperate-src"
WORK_DIR="$BUILD_DIR/dsperate-work"
OUT_DIR="$BUILD_DIR/standalone"

die() { echo "build-dsperate: $*" >&2; exit 1; }
say() { echo "build-dsperate: $*"; }

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# lock KEY [KEY...] prints one value from the lock; list indices are numbers.
lock() {
  python3 - "$LOCK" "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
PY
}

sha256() {
  python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

# Deterministic digest of the whole PGO profile directory: every file's name and
# bytes in sorted order, so the lock pins the exact profile the artifact was
# built from and a drift is caught before the build, not by a drifting hash.
profile_sha256() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for name in sorted(os.listdir(root)):
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    h.update(name.encode("utf-8"))
    h.update(b"\0")
    with open(path, "rb") as f:
        h.update(f.read())
print(h.hexdigest())
PY
}

SOURCE_URL="$(lock core source_url)"
SOURCE_COMMIT="$(lock core source_commit)"
IMAGE="$(lock toolchain image)"
DIGEST="$(lock toolchain digest)"
CROSS="$(lock toolchain cross_prefix)"
ARTIFACT="$(lock artifact file_name)"
EXPECTED_SHA="$(lock artifact sha256)"
NOTICE_ARTIFACT="$(lock notice file_name)"
EXPECTED_NOTICE_SHA="$(lock notice sha256)"
SOURCE_EPOCH="$(lock build source_date_epoch)"
GLIBC_CEILING="$(lock device glibc_ceiling)"
CHEEVOS_VERSION="$(lock build cheevos_version)"
PGO_DIR_REL="$(lock pgo dir)"
PGO_SHA="$(lock pgo sha256)"

# A tag can move; a digest cannot.
IMAGE_REF="${IMAGE%%:*}@${DIGEST}"

mkdir -p "$BUILD_DIR" "$WORK_DIR" "$OUT_DIR"

if [ -f "$OUT_DIR/$ARTIFACT" ] && [ "${FORCE:-0}" != "1" ]; then
  say "binary already present (FORCE=1 to rebuild)"
else
  if [ ! -d "$SRC_DIR/.git" ]; then
    say "cloning $SOURCE_URL (large; one time)"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$SOURCE_URL"
  fi
  if [ "$(git -C "$SRC_DIR" rev-parse -q --verify HEAD 2>/dev/null)" != "$SOURCE_COMMIT" ]; then
    say "fetching pinned commit $SOURCE_COMMIT"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$SOURCE_COMMIT"
    git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
  fi
  [ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$SOURCE_COMMIT" ] \
    || die "checked out $(git -C "$SRC_DIR" rev-parse HEAD), lock says $SOURCE_COMMIT"

  # Reset to the pinned commit and apply this pak's patches. A cached clone can
  # drift (a previous run's patch, a hand edit), so every build starts from the
  # exact pinned tree and applies the same locked patches in order.
  git -C "$SRC_DIR" reset -q --hard "$SOURCE_COMMIT"
  git -C "$SRC_DIR" clean -qfd

  PATCH_ROWS="$(python3 - "$LOCK" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1], encoding="utf-8")).get("patches", []):
    print(f"{p['file']} {p['sha256']}")
PY
)"
  if [ -n "$PATCH_ROWS" ]; then
    while IFS=' ' read -r pfile psha; do
      [ -n "$pfile" ] || continue
      patch_path="$REPO_ROOT/standalone/patches/$pfile"
      [ -f "$patch_path" ] || die "locked patch is missing: $pfile"
      actual="$(sha256 "$patch_path")"
      [ "$actual" = "$psha" ] \
        || die "patch $pfile sha256 mismatch
  file:   $actual
  locked: $psha"
      say "applying $pfile"
      git -C "$SRC_DIR" apply --whitespace=nowarn "$patch_path" \
        || die "could not apply $pfile to $SOURCE_COMMIT"
    done <<EOF
$PATCH_ROWS
EOF
  fi

  if [ "${FORCE:-0}" = "1" ]; then
    say "forcing a clean rebuild"
    git -C "$SRC_DIR" clean -qfdx
    rm -rf "$WORK_DIR" "$OUT_DIR"
    mkdir -p "$WORK_DIR" "$OUT_DIR"
  fi

  # The PGO profile is a build input like a patch: verify it against the lock
  # before a byte of the binary exists, so a probe-refresh or a stray edit is
  # caught here rather than as an artifact hash mismatch at the end.
  PGO_ABS="$REPO_ROOT/$PGO_DIR_REL"
  [ -d "$PGO_ABS" ] || die "PGO profile directory is missing: $PGO_DIR_REL"
  [ -f "$PGO_ABS/MANIFEST" ] || die "PGO profile MANIFEST is missing: $PGO_DIR_REL"
  actual_pgo="$(profile_sha256 "$PGO_ABS")"
  [ "$actual_pgo" = "$PGO_SHA" ] || die "PGO profile sha256 mismatch
  dir:    $PGO_DIR_REL
  actual: $actual_pgo
  locked: $PGO_SHA"

  say "building in $IMAGE_REF with the locked PGO profile ($PGO_DIR_REL)"
  docker run --rm \
    -e CROSS="$CROSS" \
    -e SOURCE_DATE_EPOCH="$SOURCE_EPOCH" \
    -e GLIBC_CEILING="$GLIBC_CEILING" \
    -e ARTIFACT="$ARTIFACT" \
    -e NOTICE_ARTIFACT="$NOTICE_ARTIFACT" \
    -e CHEEVOS_VERSION="$CHEEVOS_VERSION" \
    -v "$SRC_DIR":/src \
    -v "$WORK_DIR":/work \
    -v "$OUT_DIR":/out \
    -v "$REPO_ROOT/standalone":/standalone:ro \
    -w /src \
    "$IMAGE_REF" \
    bash /standalone/build-in-container.sh
fi

[ -f "$OUT_DIR/$ARTIFACT" ] || die "build produced no $ARTIFACT"
[ -f "$OUT_DIR/$NOTICE_ARTIFACT" ] || die "build produced no $NOTICE_ARTIFACT"

ACTUAL_SHA="$(sha256 "$OUT_DIR/$ARTIFACT")"
SIZE_BYTES="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$OUT_DIR/$ARTIFACT")"
NOTICE_SHA="$(sha256 "$OUT_DIR/$NOTICE_ARTIFACT")"
NOTICE_SIZE="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$OUT_DIR/$NOTICE_ARTIFACT")"
say "binary sha256 $ACTUAL_SHA ($SIZE_BYTES bytes)"
say "notice sha256 $NOTICE_SHA ($NOTICE_SIZE bytes)"

if [ "$EXPECTED_SHA" = "PENDING-FIRST-VERIFIED-BUILD" ] ||
   [ "$EXPECTED_NOTICE_SHA" = "PENDING-FIRST-VERIFIED-BUILD" ]; then
  echo
  say "upstream.lock.json has no recorded hash yet for one of the artifacts."
  say "Reproduce this build with FORCE=1, confirm the same hashes, then record"
  say "them under artifact.* and notice.*."
  exit 0
fi

[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] \
  || die "binary sha256 mismatch
  built:  $ACTUAL_SHA
  locked: $EXPECTED_SHA
A mismatch means a source, a patch or the toolchain moved. Do not update the
lock without knowing which."

[ "$NOTICE_SHA" = "$EXPECTED_NOTICE_SHA" ] \
  || die "notice sha256 mismatch
  built:  $NOTICE_SHA
  locked: $EXPECTED_NOTICE_SHA"

say "matches the lock"
