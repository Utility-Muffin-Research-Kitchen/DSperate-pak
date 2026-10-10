#!/usr/bin/env bash
# Runs inside the pinned MLP1 toolchain image; started by pgo-train.sh.
#
#   /src         the pinned commit with the locked patches applied (read-only)
#   /standalone  this directory: the lock and the toolchain file
#   /roms        the scene ROMs, under upstream's names (below)
#   /bios        bios9.bin, bios7.bin, firmware.bin
#   /work        scratch build tree
#   /pgo-out     the new profile: .gcda files and MANIFEST
set -euo pipefail

: "${CROSS:?}" "${SOURCE_COMMIT:?}" "${CHEEVOS_VERSION:?}" "${DSPERATE_LOCK_VERSION:?}" "${DSPERATE_LOCK_COMMIT:?}"
export DSPERATE_LOCK_VERSION DSPERATE_LOCK_COMMIT
export PATH="/opt/mlp1-toolchain/bin:$PATH"

BUILD=/work/pgo-gen
log() { echo "pgo-train-in-container: $*"; }

# The release build's own flags, from the lock, turned into a training build:
# instrument instead of consume, and build the headless frontend that runs the
# scenes. Everything the fingerprint covers (compiler, build type, CXX flags,
# JIT, NEON, tuning, hardening) is left exactly as the release has it, so the
# profile's fingerprint is the release build's.
mapfile -t FLAGS < <(python3 - /standalone/upstream.lock.json <<'PY'
import json, sys
for flag in json.load(open(sys.argv[1], encoding="utf-8"))["build"]["cmake"]:
    flag = flag.replace("<standalone>", "/standalone")
    if flag == "-DDSPERATE_PGO=use":
        flag = "-DDSPERATE_PGO=generate"
    elif flag == "-DDSPERATE_HEADLESS=OFF":
        flag = "-DDSPERATE_HEADLESS=ON"
    elif flag == "-DDSPERATE_PGO_STRICT=ON":
        continue
    elif flag.startswith("-DDSPERATE_PGO_DIR="):
        flag = "-DDSPERATE_PGO_DIR=/pgo-out"
    print(flag)
PY
)
grep -qx -- "-DDSPERATE_PGO=generate" < <(printf '%s\n' "${FLAGS[@]}") \
  || { echo "pgo-train-in-container: the lock's flags have no -DDSPERATE_PGO=use to turn into a training build" >&2; exit 1; }

rm -rf "$BUILD"
find /pgo-out -mindepth 1 -delete
log "configuring the instrumented headless build"
cmake -S /src -B "$BUILD" -G Ninja "${FLAGS[@]}" >/work/configure.log 2>&1 \
  || { echo "pgo-train-in-container: configure failed" >&2; tail -40 /work/configure.log >&2; exit 1; }
log "compiling"
cmake --build "$BUILD" --target dsperate-headless -j"$(nproc)" >/work/build.log 2>&1 \
  || { echo "pgo-train-in-container: build failed" >&2; tail -40 /work/build.log >&2; exit 1; }
HEADLESS="$(find "$BUILD" -type f -name dsperate-headless -perm -u+x -print -quit)"
[ -n "$HEADLESS" ] || { echo "pgo-train-in-container: no dsperate-headless was produced" >&2; exit 1; }

# Upstream's scene list (tools/pgo_refresh.sh at the pinned tag): five recorded
# replays, and three boots from frame 0 that reach their attract-mode demos,
# the only training for the boot path and the cold translation burst after it.
# The real BIOS and firmware matter: without them the JIT translates
# one-instruction blocks and the profile describes another program.
COMMON=(--direct --bios9 /bios/bios9.bin --bios7 /bios/bios7.bin --firmware /bios/firmware.bin)
mkdir -p /work/scenes
train() {
  local name="$1"; shift
  if "$HEADLESS" "${COMMON[@]}" "$@" >"/work/scenes/$name.log" 2>&1; then
    : >"/work/scenes/$name.ok"
  else
    echo "pgo-train-in-container: scene $name failed:" >&2
    tail -5 "/work/scenes/$name.log" >&2
  fi
}
log "training"
train mlbis  --save /src/scenes/mlbis.sav --replay /src/scenes/mlbis.dsin --frames 600 "/roms/Mario & Luigi - Bowser's Inside Story.nds" &
train sm64   --replay /src/scenes/sm64.dsin   --frames 600 "/roms/Super Mario 64 DS.nds" &
train etody  --replay /src/scenes/etody.dsin  --frames 600 "/roms/Etrian Odyssey.nds" &
train dbori  --replay /src/scenes/dbori.dsin  --frames 600 "/roms/Dragon Ball - Origins.nds" &
train meteos --replay /src/scenes/meteos.dsin --frames 600 "/roms/Meteos.nds" &
train gsdd   --frames 2400 "/roms/Golden Sun - Dark Dawn.nds" &
train st     --frames 2400 "/roms/Legend of Zelda, The - Spirit Tracks.nds" &
train nsmb   --frames 1500 "/roms/New Super Mario Bros..nds" &
wait

SCENES=""
for name in mlbis sm64 etody dbori meteos gsdd st nsmb; do
  [ -f "/work/scenes/$name.ok" ] && SCENES="${SCENES:+$SCENES }$name"
done
[ -n "$SCENES" ] || { echo "pgo-train-in-container: no scene ran" >&2; exit 1; }
count="$(find /pgo-out -name '*.gcda' | wc -l)"
[ "$count" -gt 0 ] || { echo "pgo-train-in-container: no profile was written" >&2; exit 1; }
# GCC writes the profile under a directory per object when the path has
# slashes; the release build reads the flat, '#'-mangled names upstream uses,
# which -fprofile-prefix-path already produces. Refuse anything else.
if find /pgo-out -mindepth 1 -type d | grep -q .; then
  echo "pgo-train-in-container: the profile has subdirectories; expected flat .gcda names" >&2
  exit 1
fi

{
  echo "fingerprint $(cat "$BUILD/pgo-fingerprint")"
  echo "compiler $("$CROSS-g++" -dumpfullversion) ($("$CROSS-g++" -dumpmachine))"
  echo "commit $SOURCE_COMMIT"
  echo "date $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "scenes $SCENES"
} >/pgo-out/MANIFEST
log "profile: $count .gcda files; scenes: $SCENES"
