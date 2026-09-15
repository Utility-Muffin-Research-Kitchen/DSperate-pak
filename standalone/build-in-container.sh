#!/usr/bin/env bash
# Runs inside the pinned MLP1 toolchain image; started by build-dsperate.sh,
# which has already checked the source against upstream.lock.json.
#
#   /src         DSperate at the pinned commit, unmodified
#   /standalone  this directory: toolchain file, verifier, device allowlist
#   /work        cached CMake build tree
#   /out         the stripped binary and the verification report
set -euo pipefail

: "${CROSS:?}" "${SOURCE_DATE_EPOCH:?}" "${GLIBC_CEILING:?}" "${ARTIFACT:?}" "${CHEEVOS_VERSION:?}"
export SOURCE_DATE_EPOCH
export PATH="/opt/mlp1-toolchain/bin:$PATH"

BUILD=/work/build
JOBS="$(nproc)"

log() { echo "build-in-container: $*"; }

if [ -d "$BUILD" ]; then
  rm -rf "$BUILD"
fi

log "configuring (SDL frontend, AArch64 JIT + NEON, Wayland tier)"
cmake -S /src -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/standalone/mlp1-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DDSPERATE_TESTS=OFF \
  -DDSPERATE_HEADLESS=OFF \
  -DDSPERATE_CHEEVOS=ON \
  -DDSPERATE_WAYLAND=ON \
  -DDSPERATE_CHEEVOS_VERSION="$CHEEVOS_VERSION" \
  >/work/configure.log 2>&1 || { echo "build-in-container: configure failed;" >&2; tail -60 /work/configure.log >&2; exit 1; }

# The playable SDL frontend is the whole point of this package. If SDL2 was not
# found the target simply does not exist, and a package without it must not be
# produced.
if ! grep -q '^-- Configuring done' /work/configure.log; then
  echo "build-in-container: configure did not complete" >&2
  tail -60 /work/configure.log >&2
  exit 1
fi
if grep -q 'DSperate: SDL2 not found' /work/configure.log; then
  echo "build-in-container: SDL2 was not found; refusing to build a package without the playable frontend" >&2
  exit 1
fi
if grep -q 'DSperate: SDL2 built without Wayland' /work/configure.log; then
  log "NOTE: the toolchain sysroot SDL2 has no Wayland support; the dmabuf scanout tier is not built."
  log "      The SDL renderer path is still built and runs under SDL_VIDEODRIVER=wayland."
fi

log "compiling (long)"
cmake --build "$BUILD" --target dsperate -j"$JOBS" >/work/build.log 2>&1 || {
  echo "build-in-container: build failed; last lines of /work/build.log:" >&2
  tail -60 /work/build.log >&2
  exit 1
}

BIN="$(find "$BUILD" -type f -name dsperate -perm -u+x -print -quit)"
[ -n "$BIN" ] || { echo "build-in-container: no dsperate executable was produced" >&2; exit 1; }
log "built $BIN"

"$CROSS-strip" --strip-unneeded -o "/out/$ARTIFACT" "$BIN"

log "verifying the binary"
bash /standalone/verify-binary.sh "/out/$ARTIFACT" /standalone/device-libs.txt "$GLIBC_CEILING" \
  | tee /out/verify-binary.txt
