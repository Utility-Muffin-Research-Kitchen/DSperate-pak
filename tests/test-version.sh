#!/usr/bin/env bash
# `dsperate --version` reports the lock's identity, `DSperate <tag> (<commit>)`,
# both for the binary built from the git checkout and for a binary rebuilt from
# the extracted corresponding-source archive, which has no git at all.
#
#   bash tests/test-version.sh BUILD_DIR IMAGE_REF      (make test-version)
#
# Upstream derives the tag from `git describe` and the commit from `git
# rev-parse`, so without patch 0004 and the lock-exported identity a source
# archive says "unknown" and the patched checkout says "<hash>-dirty". The
# rebuild from the archive must also reproduce the locked binary byte for byte:
# that is what makes the archive the corresponding source. Needs Docker, the
# built binary (make standalone) and the archive (make dist-source).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:?usage: test-version.sh BUILD_DIR IMAGE_REF}"
IMAGE_REF="${2:?usage: test-version.sh BUILD_DIR IMAGE_REF}"
ARCHIVE="$BUILD/dist/dsperate-corresponding-source.tar.gz"
SYSROOT=/opt/mlp1-toolchain/aarch64-buildroot-linux-gnu/sysroot
SCRATCH="$BUILD/test-version"

fail() { echo "test-version: FAIL $*" >&2; exit 1; }
lock() {
  python3 - "$1" "${@:2}" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2:]:
    value = value[key]
print(value)
PY
}
sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# run_version DIR prints what DIR/dsperate --version says on the AArch64 image.
run_version() {
  docker run --rm -v "$1":/bin-under-test:ro "$IMAGE_REF" \
    "$SYSROOT/lib/ld-linux-aarch64.so.1" --library-path "$SYSROOT/lib:$SYSROOT/usr/lib" \
    /bin-under-test/dsperate --version
}

LOCK="$REPO_ROOT/standalone/upstream.lock.json"
EXPECTED="DSperate $(lock "$LOCK" version tag) ($(lock "$LOCK" version commit))"
[ -f "$BUILD/standalone/dsperate" ] || fail "no built binary; run make standalone"
[ -f "$ARCHIVE" ] || fail "no source archive; run make dist-source"

# 1. The binary built from the (patched, so git-dirty) checkout.
got="$(run_version "$BUILD/standalone")"
[ "$got" = "$EXPECTED" ] || fail "git-checkout build says '$got', expected '$EXPECTED'"
echo "ok   git checkout build: $got"

# 2. Rebuild from the extracted archive, exactly as build-dsperate.sh drives
#    the container, but with the archive's own tree and its own lock.
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/src" "$SCRATCH/work" "$SCRATCH/out"
tar -xzf "$ARCHIVE" -C "$SCRATCH/src"
X="$SCRATCH/src"
[ ! -e "$X/dsperate-src/.git" ] || fail "the source archive carries .git"
XLOCK="$X/standalone/upstream.lock.json"
IMAGE="$(lock "$XLOCK" toolchain image)"
docker run --rm \
  -e CROSS="$(lock "$XLOCK" toolchain cross_prefix)" \
  -e SOURCE_DATE_EPOCH="$(lock "$XLOCK" build source_date_epoch)" \
  -e GLIBC_CEILING="$(lock "$XLOCK" device glibc_ceiling)" \
  -e ARTIFACT="$(lock "$XLOCK" artifact file_name)" \
  -e NOTICE_ARTIFACT="$(lock "$XLOCK" notice file_name)" \
  -e CHEEVOS_VERSION="$(lock "$XLOCK" build cheevos_version)" \
  -e DSPERATE_LOCK_VERSION="$(lock "$XLOCK" version tag)" \
  -e DSPERATE_LOCK_COMMIT="$(lock "$XLOCK" version commit)" \
  -v "$X/dsperate-src":/src \
  -v "$SCRATCH/work":/work \
  -v "$SCRATCH/out":/out \
  -v "$X/standalone":/standalone:ro \
  -w /src \
  "${IMAGE%%:*}@$(lock "$XLOCK" toolchain digest)" \
  bash /standalone/build-in-container.sh >"$SCRATCH/build.log" 2>&1 \
  || { tail -40 "$SCRATCH/build.log" >&2; fail "the source archive did not build"; }
[ ! -e "$X/dsperate-src/.git" ] || fail "the archive build created .git"

built="$(sha "$SCRATCH/out/dsperate")"
[ "$built" = "$(lock "$XLOCK" artifact sha256)" ] \
  || fail "the archive rebuilt $built, the lock says $(lock "$XLOCK" artifact sha256)"
echo "ok   archive rebuild reproduces the locked binary $built"
notice="$(sha "$SCRATCH/out/dsperate-notice")"
[ "$notice" = "$(lock "$XLOCK" notice sha256)" ] \
  || fail "the archive rebuilt the notice as $notice"
got="$(run_version "$SCRATCH/out")"
[ "$got" = "$EXPECTED" ] || fail "archive build says '$got', expected '$EXPECTED'"
echo "ok   source archive build: $got"
rm -rf "$SCRATCH" 2>/dev/null || true
echo "test-version: both builds report $EXPECTED"
