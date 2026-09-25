#!/usr/bin/env bash
# Runs inside the pinned MLP1 toolchain image; started by build-dsperate.sh,
# which has already checked the source against upstream.lock.json.
#
#   /src         DSperate at the pinned commit, unmodified
#   /standalone  this directory: toolchain file, verifier, device allowlist
#   /work        cached CMake build tree
#   /out         the stripped binary and the verification report
set -euo pipefail

: "${CROSS:?}" "${SOURCE_DATE_EPOCH:?}" "${GLIBC_CEILING:?}" "${ARTIFACT:?}" "${CHEEVOS_VERSION:?}" "${NOTICE_ARTIFACT:?}"
export SOURCE_DATE_EPOCH
# The locked --version identity. cmake/version.cmake prefers these over git, so
# the stamp is the same from a git checkout and a corresponding-source archive.
export DSPERATE_LOCK_VERSION="${DSPERATE_LOCK_VERSION:?}"
export DSPERATE_LOCK_COMMIT="${DSPERATE_LOCK_COMMIT:?}"
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
  -DDSPERATE_PGO=use \
  -DDSPERATE_PGO_STRICT=ON \
  -DDSPERATE_PGO_DIR=/standalone/pgo/aarch64 \
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

# PGO strictness. DSPERATE_PGO_STRICT=ON keeps GCC's per-object
# "profile count data file not found" and per-function "control flow ...
# does not match" warnings in the log instead of silencing them. Whole groups
# are never trained, because a headless training run never executes them: the
# SDL frontend, the achievement code, the standalone tools, miniz's inflate and
# the reference kernels. Anything outside those groups without a profile is a
# scene that stopped running, and a control-flow mismatch is a function that
# changed since the profile was made. Either one means the shipped binary is
# not the profile-guided build the lock describes, so the build fails. This is
# the same count upstream's tools/pgo_refresh.sh prints after a refresh.
PGO_UNTRAINED='src/frontend/sdl/|rcheevos|cheevos|tools#|miniz|kernels_ref'
pgo_missing="$(grep -c 'data file not found' /work/build.log || true)"
pgo_unexpected="$(grep 'data file not found' /work/build.log | grep -cEv "$PGO_UNTRAINED" || true)"
pgo_mismatch="$(grep -c 'control flow of function' /work/build.log || true)"
log "PGO strict: objects without a profile: $pgo_missing, of which $pgo_unexpected outside the never-trained groups; control-flow mismatches: $pgo_mismatch"
if [ "$pgo_unexpected" != 0 ]; then
  echo "build-in-container: trained objects are missing their profile:" >&2
  grep 'data file not found' /work/build.log | grep -Ev "$PGO_UNTRAINED" \
    | sed -E 's/.*pgo\/aarch64\/(.*)\.gcda.*/    \1/' >&2
  exit 1
fi
if [ "$pgo_mismatch" != 0 ]; then
  echo "build-in-container: functions no longer match the locked profile:" >&2
  grep 'control flow of function' /work/build.log | head -20 >&2
  exit 1
fi
if [ "$pgo_missing" = 0 ]; then
  # STRICT always reports the never-trained groups. Seeing none means the
  # warnings were not produced at all, so the gate above proved nothing.
  echo "build-in-container: PGO strict warnings are absent; the strictness check did not run" >&2
  exit 1
fi

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

# The pak's own small notice program: the fullscreen message the wrapper shows
# when a launch cannot proceed. It is this repository's source, not upstream's,
# and links only SDL2 and SDL_ttf, both device-provided.
[ -f /standalone/notice/notice.c ] || { echo "build-in-container: notice source missing" >&2; exit 1; }
log "compiling the notice program"
# shellcheck disable=SC2086
"$CROSS-gcc" -O2 -std=c11 -Wall -Wextra -Werror -DSDL_VIDEO_DRIVER_WAYLAND=1 \
  $(pkg-config --cflags sdl2 SDL2_ttf) -o /out/notice-raw /standalone/notice/notice.c \
  $(pkg-config --libs sdl2 SDL2_ttf) >/work/notice-build.log 2>&1 || {
  echo "build-in-container: notice build failed:" >&2
  tail -40 /work/notice-build.log >&2
  exit 1
}
"$CROSS-strip" --strip-unneeded -o "/out/$NOTICE_ARTIFACT" /out/notice-raw
rm -f /out/notice-raw
log "verifying the notice program"
bash /standalone/verify-binary.sh "/out/$NOTICE_ARTIFACT" /standalone/device-libs.txt "$GLIBC_CEILING" \
  | tee /out/verify-notice.txt
