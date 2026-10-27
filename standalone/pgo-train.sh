#!/usr/bin/env bash
# Retrain the locked PGO profile for the pinned DSperate source.
#
#   DS_ROMS=<rom dir> DS_BIOS=<bios dir> ./standalone/pgo-train.sh
#
# A profile is bound to the exact source, compiler and flags it was made with,
# so every upstream bump needs a new one. This trains it the way the release
# is built: inside the same digest-pinned toolchain image (aarch64, so the
# instrumented binary runs natively on an arm64 Docker host), against the same
# patched tree build-dsperate.sh prepares, with the lock's own CMake flags
# turned into a training build. Upstream's tools/pgo_refresh.sh assumes a
# Debian cross compiler and qemu, which this image does not have.
#
# DS_ROMS holds the scene ROMs under upstream's names, plus the pak's own
# `Mario Kart DS.nds` (see pgo-train-in-container.sh). DS_BIOS holds the real
# DS BIOS and firmware, as bios9.bin, bios7.bin and firmware.bin or Leaf's
# nds_bios_arm9.bin, nds_bios_arm7.bin and nds_firmware.bin. Neither is
# shipped or committed.
#
# On success standalone/pgo/aarch64 is replaced and the lock's pgo block
# records the new profile. Review the diff, then run `make standalone FORCE=1`:
# its strict gate is the check that the profile fits the release build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/standalone/upstream.lock.json"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
SRC_DIR="$BUILD_DIR/dsperate-src"
TRAIN_DIR="$BUILD_DIR/pgo-train"

die() { echo "pgo-train: $*" >&2; exit 1; }
say() { echo "pgo-train: $*"; }

: "${DS_ROMS:?set DS_ROMS to the directory holding the scene ROMs}"
: "${DS_BIOS:?set DS_BIOS to the directory holding the DS BIOS and firmware}"
[ -d "$DS_ROMS" ] || die "DS_ROMS is not a directory: $DS_ROMS"
DS_ROMS="$(cd "$DS_ROMS" && pwd)"

# first FILE... prints the first that exists.
first() { for f; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
BIOS9="$(first "$DS_BIOS/bios9.bin" "$DS_BIOS/nds_bios_arm9.bin")" || die "no ARM9 BIOS in $DS_BIOS"
BIOS7="$(first "$DS_BIOS/bios7.bin" "$DS_BIOS/nds_bios_arm7.bin")" || die "no ARM7 BIOS in $DS_BIOS"
FIRMWARE="$(first "$DS_BIOS/firmware.bin" "$DS_BIOS/nds_firmware.bin")" || die "no firmware in $DS_BIOS"

command -v docker >/dev/null 2>&1 || die "docker is required"

lock() {
  python3 - "$LOCK" "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
PY
}

IMAGE_REF="$(lock toolchain image)"
IMAGE_REF="${IMAGE_REF%%:*}@$(lock toolchain digest)"
PROFILE_REL="$(lock pgo dir)"
PROFILE="$REPO_ROOT/$PROFILE_REL"

say "preparing the pinned, patched source"
PREPARE_ONLY=1 FORCE=1 "$REPO_ROOT/standalone/build-dsperate.sh"

rm -rf "$TRAIN_DIR"
mkdir -p "$TRAIN_DIR/work" "$TRAIN_DIR/profile"

say "training in $IMAGE_REF"
docker run --rm \
  -e CROSS="$(lock toolchain cross_prefix)" \
  -e SOURCE_COMMIT="$(lock core source_commit)" \
  -e CHEEVOS_VERSION="$(lock build cheevos_version)" \
  -e DSPERATE_LOCK_VERSION="$(lock version tag)" \
  -e DSPERATE_LOCK_COMMIT="$(lock version commit)" \
  -v "$SRC_DIR":/src:ro \
  -v "$TRAIN_DIR/work":/work \
  -v "$TRAIN_DIR/profile":/pgo-out \
  -v "$REPO_ROOT/standalone":/standalone:ro \
  -v "$BUILD_DIR/vulkan-headers/$(lock vulkan_headers include_dir)":/vulkan-include:ro \
  -v "$DS_ROMS":/roms:ro \
  -v "$BIOS9":/bios/bios9.bin:ro \
  -v "$BIOS7":/bios/bios7.bin:ro \
  -v "$FIRMWARE":/bios/firmware.bin:ro \
  -w /work \
  "$IMAGE_REF" \
  bash /standalone/pgo-train-in-container.sh

[ -f "$TRAIN_DIR/profile/MANIFEST" ] || die "training wrote no MANIFEST"

rm -rf "$PROFILE"
mkdir -p "$PROFILE"
cp "$TRAIN_DIR/profile/"* "$PROFILE/"

python3 - "$LOCK" "$PROFILE" <<'PY'
import hashlib, json, os, sys
lock_path, root = sys.argv[1], sys.argv[2]
# Must stay identical to profile_sha256() in build-dsperate.sh and test-pgo.py.
digest = hashlib.sha256()
names = sorted(n for n in os.listdir(root) if os.path.isfile(os.path.join(root, n)))
for name in names:
    digest.update(name.encode("utf-8"))
    digest.update(b"\0")
    with open(os.path.join(root, name), "rb") as f:
        digest.update(f.read())
manifest = dict(line.split(" ", 1) for line in open(os.path.join(root, "MANIFEST"), encoding="utf-8").read().splitlines())
lock = json.load(open(lock_path, encoding="utf-8"))
pgo = lock["pgo"]
pgo["sha256"] = digest.hexdigest()
pgo["files"] = len(names)
pgo["fingerprint"] = manifest["fingerprint"]
pgo["compiler"] = manifest["compiler"]
pgo["source_commit"] = manifest["commit"]
pgo["date"] = manifest["date"]
pgo["scenes"] = manifest["scenes"]
with open(lock_path, "w", encoding="utf-8") as f:
    f.write(json.dumps(lock, indent=2, ensure_ascii=False) + "\n")
print(f"pgo-train: {len(names)} files, sha256 {pgo['sha256']}")
print(f"pgo-train: fingerprint {pgo['fingerprint']}, scenes: {pgo['scenes']}")
PY
say "updated $PROFILE_REL and the lock's pgo block; check pgo.note, then build with FORCE=1"
