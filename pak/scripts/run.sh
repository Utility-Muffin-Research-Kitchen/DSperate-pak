#!/bin/sh
# DSperate launch wrapper for Leaf on MLP1.
#
# This is the `type: "path"` core target declared in pak.json
# (`scripts/run.sh`). Leaf/Jawaka execs it with one absolute content path:
#
#     run.sh /path/to/game.nds
#
# Everything the emulator needs at runtime is resolved here and passed
# explicitly, so nothing is inferred from the working directory. Paths come
# from the public runtime contract (docs/runtime-paths.md); the only fallbacks
# below are for a direct/manual launch outside the launcher.
#
# Game identity is the ROM's path relative to the selected source's
# Roms/NDS plus the selected source slot. Saves, states and per-game settings
# are kept in per-game directories keyed on that identity, so two same-named
# ROMs in different folders do not share progress. A path-based key means
# renaming or moving a ROM starts a new identity; that is deliberate.
#
set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# --- runtime environment -----------------------------------------------------
# Source the launcher's exported environment when it is present, without
# overwriting per-launch bindings Jawaka already made for the selected source.
if [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
elif [ -n "${SDCARD_PATH:-}" ] && [ -n "${PLATFORM:-}" ] &&
     [ -f "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh" ]; then
    . "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh"
fi

: "${PLATFORM:=mlp1}"
: "${SDCARD_PATH:=/mnt/sdcard}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
: "${ROMS_PATH:=$SDCARD_PATH/Roms}"
: "${SAVES_PATH:=$SDCARD_PATH/Saves}"
: "${STATES_PATH:=$SDCARD_PATH/States}"
: "${BIOS_PATH:=$SDCARD_PATH/BIOS}"
: "${UMRK_RUNTIME_PATH:=${TMPDIR:-/tmp}/jawaka-runtime}"
export SDCARD_PATH ROMS_PATH

STATE_ROOT="$USERDATA_PATH/dsperate"
CACHE_DIR="$STATE_ROOT/cache"
RUNTIME_DIR="$UMRK_RUNTIME_PATH/dsperate"
GLOBAL_INI="$STATE_ROOT/dsperate.ini"
BIN="$ROOT_DIR/bin/dsperate"
LOG_FILE="$LOGS_PATH/dsperate.log"

die() { echo "dsperate: $*" >&2; log "$*"; exit 1; }

log() { printf 'dsperate: %s\n' "$*" 2>/dev/null >>"$LOG_FILE" || true; }

usage() {
    echo "usage: $0 ROM" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

ROM_PATH="$1"
case "$ROM_PATH" in
    /*) ;;
    *) ROM_PATH="$PWD/$ROM_PATH" ;;
esac
if [ ! -f "$ROM_PATH" ]; then
    echo "dsperate: ROM not found: $ROM_PATH" >&2
    exit 1
fi

if [ ! -x "$BIN" ]; then
    echo "dsperate: emulator binary missing: $BIN" >&2
    exit 1
fi

# --- game identity -----------------------------------------------------------
# The launcher binds singular content roots to the selected source while the
# public plural list retains its stable slot order (including absent cards).
# Never infer the slot from a physical mount name or the presence of a card.
SOURCE_ID="$(awk 'BEGIN {
    roots = ENVIRON["ROMS_PATHS"]
    if (roots == "") roots = ENVIRON["SDCARD_PATH"] "/Roms"
    n = split(roots, r, ":")
    if (n < 1 || n > 2) exit 1
    selected = -1
    for (i = 1; i <= n; i++) {
        sub(/\/$/, "", r[i])
        if (r[i] == "" || seen[r[i]]++) exit 1
        if (r[i] == ENVIRON["ROMS_PATH"]) selected = i
    }
    if (selected < 0) exit 1
    print (selected == 1 ? "primary" : "secondary_sd")
}')" || die "cannot identify the selected source in ROMS_PATHS"
ROM_ROOT="${ROMS_PATH%/}/NDS"
case "$ROM_PATH" in
    "$ROM_ROOT"/*) ROM_REL="${ROM_PATH#"$ROM_ROOT"/}" ;;
    *) die "ROM must be inside the selected source's Roms/NDS" ;;
esac
# Reject traversal aliases: one spelling of a relative path means one identity.
case "/$ROM_REL/" in
    *'/../'*|*'/./'*|*'//'*) die "ROM path must not contain . or .. components" ;;
esac
DIGEST="$(printf '%s\000%s' "$SOURCE_ID" "$ROM_REL" | sha256sum)" || die "cannot hash game identity"
GAME_KEY="v2-${DIGEST%% *}"
GAME_DIR="$STATE_ROOT/games/$GAME_KEY"
SAVES_DIR="$SAVES_PATH/DSperate/$GAME_KEY"
STATES_DIR="$STATES_PATH/DSperate/$GAME_KEY"
SHOTS_DIR="$STATES_DIR/screenshots"
CACHE_DIR="$CACHE_DIR/$GAME_KEY"
mkdir -p "$RUNTIME_DIR" "$STATE_ROOT" "$SAVES_DIR" "$STATES_DIR" "$SHOTS_DIR" \
         "$CACHE_DIR" "$LOGS_PATH" || die "cannot create game data directories"

ROM_STEM="$(basename -- "$ROM_PATH")"
case "$ROM_STEM" in
    *.*) ROM_STEM="${ROM_STEM%.*}" ;;
esac

# A scoped XDG root gives DSperate a private config directory per game, so its
# per-game override files cannot collide between two ROMs with the same
# basename. The shared global config is passed with --config instead.
export XDG_CONFIG_HOME="$GAME_DIR/xdg"
CFG_DIR="$XDG_CONFIG_HOME/dsperate"
GAME_INI="$CFG_DIR/games/$ROM_STEM.ini"
mkdir -p "$CFG_DIR/games" || die "cannot create game config directory"

# Seed the shared global config once, from the pak's defaults. It is the user's
# file from then on; launches never rewrite it.
if [ ! -e "$GLOBAL_INI" ]; then
    cp "$ROOT_DIR/defaults/dsperate.ini" "$GLOBAL_INI.tmp.$$" &&
        mv "$GLOBAL_INI.tmp.$$" "$GLOBAL_INI" || die "cannot seed global config"
fi
[ -f "$GLOBAL_INI" ] && [ -r "$GLOBAL_INI" ] || die "cannot read global config"

# ini_set FILE SECTION KEY VALUE
#
# Set one key in one section, preserving every other line, comment and section.
# Refuse values DSperate's INI parser cannot represent; required paths must
# never silently fall back to the ROM directory. Writes through a temp file and
# renames, so the destination is never left half-written.
ini_set() {
    _file="$1" _section="$2" _key="$3" _value="$4"
    case "$_value" in
        *[\#\;\\]*|*"
"*|*"$(printf '\r')"*|[[:space:]]*|*[[:space:]])
            log "config value cannot be represented: $_key"
            return 1
            ;;
    esac
    [ ! -e "$_file" ] || [ -f "$_file" ] || return 1
    [ -f "$_file" ] || : >"$_file" || return 1
    _tmp="$_file.tmp.$$"
    if DS_INI_VALUE="$_value" awk -v S="$_section" -v K="$_key" '
        BEGIN { V = ENVIRON["DS_INI_VALUE"]; in_s = 0; have_s = 0; done = 0 }
        {
            line = $0
            if (line ~ /^[ \t]*\[[^]]*\][ \t]*$/) {
                if (in_s && !done) { print K " = " V; done = 1 }
                hdr = line
                sub(/^[ \t]*\[/, "", hdr)
                sub(/\][ \t]*$/, "", hdr)
                gsub(/^[ \t]+|[ \t]+$/, "", hdr)
                if (hdr == S) { in_s = 1; have_s = 1 } else { in_s = 0 }
                print line
                next
            }
            if (in_s) {
                k = line
                sub(/=.*/, "", k)
                gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == K) { print K " = " V; done = 1; next }
            }
            print line
        }
        END {
            if (!done) {
                if (have_s) { print K " = " V }
                else { print ""; print "[" S "]"; print K " = " V }
            }
        }
    ' "$_file" >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$_file" 2>/dev/null; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        log "could not update $_file"
        return 1
    fi
}

# Only launch-bound paths are pak-owned. Controls/deadzones stay user-owned.
# A roster and a JSON file do not prove the selected pad was calibrated.
ini_set "$GAME_INI" paths states "$STATES_DIR" || die "cannot bind save-state path"
ini_set "$GAME_INI" paths screenshots "$SHOTS_DIR" || die "cannot bind screenshot path"
ini_set "$GAME_INI" paths cache "$CACHE_DIR" || die "cannot bind cache path"
ini_set "$GAME_INI" paths firmware_override "$GAME_DIR/firmware.ovr" || die "cannot bind firmware sidecar"

# --- presentation ------------------------------------------------------------
# Weston owns the panel transform on MLP1, so the emulator runs a plain
# fullscreen Wayland window and never rotates the output itself. DS_ROTATE is
# cleared so an inherited value cannot make the display engine rotate a second
# time.
export SDL_VIDEODRIVER=wayland
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export SDL_JOYSTICK_DISABLE_UDEV=1
unset DS_ROTATE

# The frozen controller roster that Jawaka publishes for the launch is kept.
# Without one, SDL scans for itself; a direct-launch fallback is not invented.
if [ -n "${SDL_JOYSTICK_DEVICE:-}" ]; then
    log "using inherited controller roster"
fi

# --- optional BIOS and firmware ----------------------------------------------
# The three dumps Leaf names under BIOS/NDS. They are never shipped and are
# never required: DSperate's own FreeBIOS/generated firmware boot games without
# them. An absent dump is the normal case.
NDS_BIOS_DIR="$BIOS_PATH/NDS"
bios_file() {
    [ -f "$1" ] && printf '%s' "$1"
}
ARM9="$(bios_file "$NDS_BIOS_DIR/nds_bios_arm9.bin")"
ARM7="$(bios_file "$NDS_BIOS_DIR/nds_bios_arm7.bin")"
FW="$(bios_file "$NDS_BIOS_DIR/nds_firmware.bin")"

# --- launch ------------------------------------------------------------------
# Battery saves go to a per-source, per-game file under Saves/DSperate; the
# states and cache paths were set above. --no-disp and --no-fbdev keep the
# direct-panel tiers out of the way; --no-mic disables real capture.
set -- --config "$GLOBAL_INI" \
       --save "$SAVES_DIR/$ROM_STEM.sav" \
       --no-disp --no-fbdev --fullscreen --no-mic

[ -n "$ARM9" ] && set -- "$@" --bios9 "$ARM9"
[ -n "$ARM7" ] && set -- "$@" --bios7 "$ARM7"
[ -n "$FW" ]   && set -- "$@" --firmware "$FW"

log "launching $BIN for $ROM_REL (saves=$SAVES_DIR states=$STATES_DIR)"
exec "$BIN" "$@" "$ROM_PATH"
