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
cp "$REPO_ROOT/pak/defaults/dsperate.ini" "$PAK/defaults/dsperate.ini"
cp "$REPO_ROOT/pak/defaults/config.version" "$PAK/defaults/config.version"
cat >"$PAK/bin/dsperate" <<'FAKE'
#!/bin/sh
: >"$DS_FAKE_OUT"
for a in "$@"; do printf '%s\n' "$a" >>"$DS_FAKE_OUT"; done
printf '%s\n' "$XDG_CONFIG_HOME" >"$DS_FAKE_OUT.xdg"
printf '%s\n' "$SDL_VIDEODRIVER" "${DS_ROTATE-unset}" >"$DS_FAKE_OUT.video"
FAKE
chmod 755 "$PAK/scripts/run.sh" "$PAK/bin/dsperate"

mkdir -p "$SD/Roms/NDS/Some Folder" "$SD/Saves" "$SD/States" "$SD/BIOS/NDS" "$TMP/run"
ROM="$SD/Roms/NDS/Some Folder/Game (USA).nds"
: >"$ROM"

run_wrapper() {
    DS_FAKE_OUT="$OUT" \
    PLATFORM=mlp1 \
    SDCARD_PATH="${TEST_PRIMARY:-$SD}" \
    USERDATA_PATH="$SD/.userdata/mlp1" \
    LOGS_PATH="$SD/.userdata/mlp1/logs" \
    ROMS_PATH="${TEST_SOURCE:-$SD}/Roms" \
    ROMS_PATHS="${TEST_ROOTS:-$SD/Roms:$TMP/secondary/Roms}" \
    SAVES_PATH="${TEST_SOURCE:-$SD}/Saves" \
    STATES_PATH="${TEST_SOURCE:-$SD}/States" \
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
SAVE1="$(sed -n '/^--save$/{n;p;}' "$OUT")"
KEY1="$(basename "$(dirname "$SAVE1")")"
case "$SAVE1" in "$SD/Saves/DSperate/v2-"*"/Game (USA).sav") pass ;; *) fail "save path is per-game" ;; esac

# --- data separation ---------------------------------------------------------
GAME_DIR="$(find "$SD/.userdata/mlp1/dsperate/games" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
GAME_INI="$GAME_DIR/xdg/dsperate/games/Game (USA).ini"
if [ -f "$GAME_INI" ]; then pass; else fail "per-game config file was written"; fi
check_contains "$GAME_INI" "states = $SD/States/DSperate/$KEY1" "per-game states path"
check_contains "$GAME_INI" "cache = $SD/.userdata/mlp1/dsperate/cache/$KEY1" "per-game cache path"

# A same-named ROM in another folder must not share the per-game directory.
mkdir -p "$SD/Roms/NDS/Other"
cp "$ROM" "$SD/Roms/NDS/Other/Game (USA).nds"
run_wrapper "$SD/Roms/NDS/Other/Game (USA).nds"
GAME_DIRS="$(find "$SD/.userdata/mlp1/dsperate/games" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$GAME_DIRS" = "2" ]; then pass; else fail "two same-named ROMs got separate game keys (got $GAME_DIRS)"; fi

SAVE2="$(sed -n '/^--save$/{n;p;}' "$OUT")"
KEY2="$(basename "$(dirname "$SAVE2")")"
[ "$SAVE1" != "$SAVE2" ] && pass || fail "same basenames share a save"
INI2="$(cat "$OUT.xdg")/dsperate/games/Game (USA).ini"
check_contains "$INI2" "states = $SD/States/DSperate/$KEY2" "separate game-code states namespace"
check_contains "$GAME_INI" "firmware_override = $GAME_DIR/firmware.ovr" "firmware sidecar stays in userdata"

# Both slots share primary userdata, so a source slot must enter the game key.
SECONDARY="$TMP/secondary"
mkdir -p "$SECONDARY/Roms/NDS/Some Folder"
cp "$ROM" "$SECONDARY/Roms/NDS/Some Folder/Game (USA).nds"
( TEST_SOURCE="$SECONDARY" run_wrapper "$SECONDARY/Roms/NDS/Some Folder/Game (USA).nds" )
INI3="$(cat "$OUT.xdg")/dsperate/games/Game (USA).ini"
[ "$INI3" != "$GAME_INI" ] && pass || fail "cards share a per-game INI"
case "$(sed -n '/^--save$/{n;p;}' "$OUT")" in "$SECONDARY/Saves/DSperate/"*) pass ;; *) fail "secondary saves binding lost" ;; esac

# A mount rename keeps the same logical slot and relative path.
MOVED="$TMP/remounted"
mv "$SECONDARY" "$MOVED"
( TEST_SOURCE="$MOVED" TEST_ROOTS="$SD/Roms:$MOVED/Roms" run_wrapper "$MOVED/Roms/NDS/Some Folder/Game (USA).nds" )
[ "$(cat "$OUT.xdg")/dsperate/games/Game (USA).ini" = "$INI3" ] && pass || fail "mount prefix changed identity"

# Config and calibration are user-owned; neither a bogus profile nor a roster
# proves calibration. Preserve an explicit per-game zero and unrelated layout.
printf '\n[pad]\nstick_deadzone = 8000\n[video]\nlayout = horizontal\n' >>"$GAME_INI"
mkdir -p "$SD/.userdata/mlp1/input"
printf '{"version":1,"left":{"x_min":-100,"x_max":100,"y_min":-100,"y_max":100}}\n' \
    >"$SD/.userdata/mlp1/input/loong-gamepad-calibration.json"
( SDL_JOYSTICK_DEVICE=/dev/input/event5 run_wrapper "$ROM" )
check_contains "$GAME_INI" "stick_deadzone = 8000" "invalid calibration does not override controls"
check_contains "$GAME_INI" "layout = horizontal" "layout preserved"
sed 's/stick_deadzone = 8000/stick_deadzone = 0/' "$GAME_INI" >"$GAME_INI.edit"
mv "$GAME_INI.edit" "$GAME_INI"
run_wrapper "$ROM"
check_contains "$GAME_INI" "stick_deadzone = 0" "explicit calibrated setting preserved"
check_contains "$SD/.userdata/mlp1/dsperate/dsperate.ini" "stick_deadzone = 12000" "global raw default preserved"

( SDL_VIDEODRIVER=kmsdrm DS_ROTATE=90 run_wrapper "$ROM" )
check_contains "$OUT.video" "wayland" "forces Weston backend"
check_contains "$OUT.video" "unset" "clears rotation"

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

# Required config failures must stop BEFORE the emulator starts.
rm "$GAME_INI" "$OUT"
mkdir "$GAME_INI"
if run_wrapper "$ROM" >/dev/null 2>&1; then fail "INI directory should fail"; else pass; fi
[ ! -e "$OUT" ] && pass || fail "launched after config creation failure"
rmdir "$GAME_INI"
run_wrapper "$ROM"
cp "$GAME_INI" "$TMP/previous.ini"
mkdir "$TMP/fail-bin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/fail-bin/mv"
chmod +x "$TMP/fail-bin/mv"
rm "$OUT"
if ( PATH="$TMP/fail-bin:$PATH" run_wrapper "$ROM" >/dev/null 2>&1 ); then fail "rename failure should fail"; else pass; fi
[ ! -e "$OUT" ] && pass || fail "launched after rename failure"
cmp -s "$GAME_INI" "$TMP/previous.ini" && pass || fail "failed config write changed original"

for BAD in "$TMP/card#one" "$TMP/card;two"; do
    rm -f "$OUT"
    if ( TEST_SOURCE="$BAD" TEST_ROOTS="$BAD/Roms" run_wrapper "$ROM" >/dev/null 2>&1 ); then fail "mismatched ROM source should fail"; else pass; fi
    mkdir -p "$BAD/Roms/NDS"
    cp "$ROM" "$BAD/Roms/NDS/Game.nds"
    if ( TEST_SOURCE="$BAD" TEST_ROOTS="$BAD/Roms" run_wrapper "$BAD/Roms/NDS/Game.nds" >/dev/null 2>&1 ); then fail "unrepresentable INI root should fail"; else pass; fi
    [ ! -e "$OUT" ] && pass || fail "launched with truncated config path"
done
if ( TEST_ROOTS="$SD/Roms:$SD/Roms" run_wrapper "$ROM" >/dev/null 2>&1 ); then fail "duplicate source roots should fail"; else pass; fi
if ( TEST_ROOTS="$SD/Roms:" run_wrapper "$ROM" >/dev/null 2>&1 ); then fail "empty source root should fail"; else pass; fi

# ROM names need no INI serialization; punctuation is safe in the filename.
SPECIAL="$SD/Roms/NDS/Space 'quote';hash#.nds"
cp "$ROM" "$SPECIAL"
run_wrapper "$SPECIAL"
[ "$(tail -n 1 "$OUT")" = "$SPECIAL" ] && pass || fail "special filename did not round-trip"

# --- defaults migration ------------------------------------------------------
# The global config is seeded once and never refreshed, so an upgrade must
# rewrite only keys that still hold an earlier shipped default. Customized
# controls and layouts survive; the work is idempotent.
GLOBAL_INI="$SD/.userdata/mlp1/dsperate/dsperate.ini"
STAMP="$SD/.userdata/mlp1/dsperate/.umrk-defaults-version"
SHIPPED_VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/pak/defaults/config.version")"

# A fresh install records the shipped revision.
rm -f "$STAMP"
run_wrapper "$ROM"
[ "$(cat "$STAMP" 2>/dev/null | tr -d '[:space:]')" = "$SHIPPED_VERSION" ] \
    && pass || fail "fresh install records the defaults version"

# Upgrading the revision before the MLP1 profile was fixed.
cat >"$GLOBAL_INI" <<'INI'
[emu]
realtime = off

[pad]
stick_dpad = left
stylus_axis = right
a = y

[video]
layout = vertical
INI
rm -f "$STAMP"
run_wrapper "$ROM"
check_contains "$GLOBAL_INI" "stick_dpad = none" "old stick_dpad migrated"
check_contains "$GLOBAL_INI" "stylus_axis = left" "old stylus_axis migrated"
check_contains "$GLOBAL_INI" "stylus_button = +righttrigger" "missing stylus_button added"
check_contains "$GLOBAL_INI" "stylus_button.alt = +lefttrigger" "missing stylus_button.alt added"
check_contains "$GLOBAL_INI" "pause.alt = guide" "missing pause.alt added"
check_contains "$GLOBAL_INI" "a = y" "custom pad binding preserved"
check_contains "$GLOBAL_INI" "layout = vertical" "custom layout preserved"
[ "$(cat "$STAMP" | tr -d '[:space:]')" = "$SHIPPED_VERSION" ] \
    && pass || fail "upgrade records the defaults version"

# Repeated launch is a no-op and never duplicates a key.
cp "$GLOBAL_INI" "$TMP/after-migration.ini"
run_wrapper "$ROM"
cmp -s "$GLOBAL_INI" "$TMP/after-migration.ini" && pass || fail "repeated launch rewrote the global config"
[ "$(grep -c '^stylus_button = +righttrigger$' "$GLOBAL_INI")" = "1" ] \
    && pass || fail "stylus_button duplicated"

# A deliberate change away from a shipped default is kept.
cat >"$GLOBAL_INI" <<'INI'
[pad]
stick_dpad = left
stylus_axis = none
INI
rm -f "$STAMP"
run_wrapper "$ROM"
check_contains "$GLOBAL_INI" "stylus_axis = none" "custom stylus_axis preserved"
check_contains "$GLOBAL_INI" "stick_dpad = none" "old stick_dpad still migrates beside a custom key"

# An interrupted migration (keys written, version not recorded) is safe to
# repeat: nothing duplicates and the stamp is then written.
rm -f "$STAMP"
run_wrapper "$ROM"
[ "$(grep -c '^stylus_axis = none$' "$GLOBAL_INI")" = "1" ] \
    && pass || fail "interrupted migration duplicated a key"
[ -f "$STAMP" ] && pass || fail "interrupted migration did not record the version"

# An invalid installed stamp is treated as an unversioned install.
printf 'bogus\n' >"$STAMP"
run_wrapper "$ROM"
[ "$(cat "$STAMP" | tr -d '[:space:]')" = "$SHIPPED_VERSION" ] \
    && pass || fail "invalid installed stamp was not repaired"

echo "test-wrapper: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
