#!/bin/sh
# Checks for pak/scripts/run.sh, run in dry-run mode so no DSperate binary is
# needed.
#
#   sh tests/test-wrapper.sh
#
# The wrapper is copied into a fake installed pak with a stand-in `bin/dsperate`
# that records its arguments, so every launch decision can be asserted without
# building anything. POSIX sh only, so the same file runs on a host and on an
# MLP1 (BusyBox grep/sed).
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/pak/scripts/run.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsperate-wrapper.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

failures=0
checks=0
pass() { checks=$((checks + 1)); }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $*"; }
check_contains() {
    # check_contains <file> <needle> <label>
    if grep -Fq -- "$2" "$1"; then pass; else fail "$3 (missing: $2)"; fi
}

SD="$TMP/sd"
PAK="$TMP/DSperate.pak"
OUT="$TMP/args.txt"
mkdir -p "$PAK/scripts" "$PAK/bin" "$PAK/defaults"
cp "$WRAPPER" "$PAK/scripts/run.sh"
: >"$PAK/defaults/dsperate.ini"
cat >"$PAK/bin/dsperate" <<'FAKE'
#!/bin/sh
: >"$DS_FAKE_OUT"
for a in "$@"; do printf '%s\n' "$a" >>"$DS_FAKE_OUT"; done
FAKE
chmod 755 "$PAK/scripts/run.sh" "$PAK/bin/dsperate"

mkdir -p "$SD/Roms/NDS/Some Folder" "$SD/Saves" "$SD/States" "$SD/BIOS/NDS" "$TMP/run"
ROM="$SD/Roms/NDS/Some Folder/Game (USA).nds"
: >"$ROM"

run_wrapper() {
    DS_FAKE_OUT="$OUT" \
    PLATFORM=mlp1 \
    SDCARD_PATH="$SD" \
    USERDATA_PATH="$SD/.userdata/mlp1" \
    LOGS_PATH="$SD/.userdata/mlp1/logs" \
    ROMS_PATH="$SD/Roms" \
    SAVES_PATH="$SD/Saves" \
    STATES_PATH="$SD/States" \
    BIOS_PATH="$SD/BIOS" \
    UMRK_RUNTIME_PATH="$TMP/run" \
    XDG_RUNTIME_DIR="$TMP/run" \
    sh "$PAK/scripts/run.sh" "$@"
}

# --- argument contract -------------------------------------------------------
run_wrapper "$ROM"
check_contains "$OUT" "--config" "passes --config"
check_contains "$OUT" "--save" "passes --save"
check_contains "$OUT" "--no-disp" "passes --no-disp"
check_contains "$OUT" "--no-fbdev" "passes --no-fbdev"
check_contains "$OUT" "--fullscreen" "passes --fullscreen"
check_contains "$OUT" "--no-mic" "passes --no-mic"
if [ "$(tail -n 1 "$OUT")" = "$ROM" ]; then pass; else fail "content path is the last argument"; fi
if grep -Fq -- "$SD/Saves/DSperate/Game (USA).sav" "$OUT"; then pass; else fail "save path is per-source and per-ROM"; fi

# --- data separation ---------------------------------------------------------
GAME_DIR="$(find "$SD/.userdata/mlp1/dsperate/games" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
GAME_INI="$GAME_DIR/xdg/dsperate/games/Game (USA).ini"
if [ -f "$GAME_INI" ]; then pass; else fail "per-game config file was written"; fi
check_contains "$GAME_INI" "states = $SD/States/DSperate" "per-game states path"
check_contains "$GAME_INI" "cache = $SD/.userdata/mlp1/dsperate/cache" "per-game cache path"

# A same-named ROM in another folder must not share the per-game directory.
mkdir -p "$SD/Roms/NDS/Other"
cp "$ROM" "$SD/Roms/NDS/Other/Game (USA).nds"
run_wrapper "$SD/Roms/NDS/Other/Game (USA).nds"
GAME_DIRS="$(find "$SD/.userdata/mlp1/dsperate/games" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$GAME_DIRS" = "2" ]; then pass; else fail "two same-named ROMs got separate game keys (got $GAME_DIRS)"; fi

# --- optional BIOS -----------------------------------------------------------
: >"$SD/BIOS/NDS/nds_bios_arm9.bin"
: >"$SD/BIOS/NDS/nds_bios_arm7.bin"
: >"$SD/BIOS/NDS/nds_firmware.bin"
run_wrapper "$ROM"
check_contains "$OUT" "--bios9" "passes --bios9 when present"
check_contains "$OUT" "--bios7" "passes --bios7 when present"
check_contains "$OUT" "--firmware" "passes --firmware when present"

# --- error cases -------------------------------------------------------------
if run_wrapper >/dev/null 2>&1; then fail "no argument should fail"; else pass; fi
if run_wrapper "$TMP/does-not-exist.nds" >/dev/null 2>&1; then fail "missing ROM should fail"; else pass; fi

echo "test-wrapper: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
