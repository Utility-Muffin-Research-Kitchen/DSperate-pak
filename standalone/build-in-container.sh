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

log "configuring (SDL frontend, AArch64 JIT + NEON, Wayland dmabuf tier)"
# The toolchain sysroot's SDL2 2.28.5 is built without its Wayland video driver,
# so its SDL_config.h leaves SDL_VIDEO_DRIVER_WAYLAND undefined and SDL_syswm.h
# hides SDL_SysWMinfo's Wayland fields. DSperate's Wayland dmabuf tier needs
# those fields, and the public union reserves their space regardless, so define
# the macro this build's way: the compile-time header then matches the device's
# Wayland-capable SDL, which the binary is dynamically linked to. This only
# exposes the header fields; it cannot add a Wayland driver to a runtime SDL
# that lacks one. See standalone/PROVENANCE.md.
cmake -S /src -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/standalone/mlp1-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_CXX_FLAGS=-DSDL_VIDEO_DRIVER_WAYLAND=1 \
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
# The dmabuf tier is intended to ship. If the Wayland probe still failed, the
# build would quietly take DSperate's stub instead, so fail instead of
# substituting it.
if ! grep -q 'DSPERATE_SDL2_HAS_WAYLAND:INTERNAL=1' "$BUILD/CMakeCache.txt"; then
  echo "build-in-container: the SDL2 Wayland probe failed; refusing to ship the stub instead of the dmabuf tier" >&2
  exit 1
fi
log "Wayland probe passed; the dmabuf tier is built"

log "compiling (long)"
cmake --build "$BUILD" --target dsperate -j"$JOBS" >/work/build.log 2>&1 || {
  echo "build-in-container: build failed; last lines of /work/build.log:" >&2
  tail -60 /work/build.log >&2
  exit 1
}

BIN="$(find "$BUILD" -type f -name dsperate -perm -u+x -print -quit)"
[ -n "$BIN" ] || { echo "build-in-container: no dsperate executable was produced" >&2; exit 1; }
log "built $BIN"

# The tier is only real if its source compiled; display_wl_stub.cpp is used
# otherwise. Fail rather than ship the stub.
if ! find "$BUILD" -name 'display_wl.cpp.o' -print -quit | grep -q .; then
  echo "build-in-container: display_wl.cpp did not compile; the dmabuf tier is missing" >&2
  exit 1
fi
log "confirmed display_wl.cpp (real dmabuf tier) compiled"

"$CROSS-strip" --strip-unneeded -o "/out/$ARTIFACT" "$BIN"

log "verifying the binary"
bash /standalone/verify-binary.sh "/out/$ARTIFACT" /standalone/device-libs.txt "$GLIBC_CEILING" \
  | tee /out/verify-binary.txt
