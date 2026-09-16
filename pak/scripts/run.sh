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
NOTICE_BIN="$ROOT_DIR/bin/dsperate-notice"
LOG_FILE="$LOGS_PATH/dsperate.log"
CACHE_ROOT="$STATE_ROOT/cache"
NOTICE_FONT=""

log() { printf 'dsperate: %s\n' "$*" 2>/dev/null >>"$LOG_FILE" || true; }

# The launcher's font, resolved the way Jawaka's on-screen display resolves it:
# CAT_FONT_PATH (absolute, or relative to CAT_FONTS_DIR), then the launcher res
# tree. The notice program resolves the same fallbacks itself if this is empty.
if [ -n "${CAT_FONT_PATH:-}" ]; then
    case "$CAT_FONT_PATH" in
        /*) [ -r "$CAT_FONT_PATH" ] && NOTICE_FONT="$CAT_FONT_PATH" ;;
        *) [ -n "${CAT_FONTS_DIR:-}" ] && [ -r "$CAT_FONTS_DIR/$CAT_FONT_PATH" ] &&
               NOTICE_FONT="$CAT_FONTS_DIR/$CAT_FONT_PATH" ;;
    esac
fi
if [ -z "$NOTICE_FONT" ] && [ -n "${UMRK_LAUNCHER_PATH:-}" ] &&
   [ -r "$UMRK_LAUNCHER_PATH/res/font.ttf" ]; then
    NOTICE_FONT="$UMRK_LAUNCHER_PATH/res/font.ttf"
fi

# Show the pak's fullscreen message when a launch cannot proceed. Leaf has no
# error surface a content pak can use, so this is the only way the player sees
# why: without it a refused archive is a silent return to the launcher. Best
# effort -- a missing notice binary or a disabled test run must not become a
# second failure.
show_notice() {
    [ -n "${DS_NO_NOTICE:-}" ] && return 0
    [ -x "$NOTICE_BIN" ] || return 0
    if [ -n "$NOTICE_FONT" ]; then
        SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}" \
        SDL_JOYSTICK_DISABLE_UDEV=1 \
        "$NOTICE_BIN" --font "$NOTICE_FONT" --timeout "${DS_NOTICE_TIMEOUT:-10}" \
            "$@" >>"$LOG_FILE" 2>&1 || true
    else
        SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}" \
        SDL_JOYSTICK_DISABLE_UDEV=1 \
        "$NOTICE_BIN" --timeout "${DS_NOTICE_TIMEOUT:-10}" \
            "$@" >>"$LOG_FILE" 2>&1 || true
    fi
}

die() { echo "dsperate: $*" >&2; log "$*"; show_notice "DSperate could not start" "$*"; exit 1; }

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

# Extension, lower-cased, for the archive checks below.
ROM_EXT=""
case "$ROM_PATH" in
    *.*) ROM_EXT="$(printf '%s' "${ROM_PATH##*.}" | tr '[:upper:]' '[:lower:]')" ;;
esac

# DSperate reads .nds and .zip, not .7z. The NDS system passes archives through,
# so a .7z reaches here; refusing it with an on-screen explanation is the point,
# not a log line and a silent return to the launcher.
if [ "$ROM_EXT" = "7z" ]; then
    log "refused unsupported .7z archive: $ROM_PATH"
    show_notice "This archive is not supported" \
        "DSperate does not read .7z files." \
        "Extract the ROM to a .nds file, or choose another Nintendo DS emulator."
    exit 0
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

# --- defaults migration ------------------------------------------------------
# The global config is seeded once and then belongs to the user, so a new pak
# cannot refresh it wholesale. Each shipped revision of the defaults carries a
# number; a launch rewrites a key only while it still holds the value an earlier
# revision shipped, and only adds a key that is absent. Customized controls,
# layouts and unrelated lines are never touched. Re-running is safe: a key
# already at its new value no longer matches its old one.
DEFAULTS_VERSION_FILE="$ROOT_DIR/defaults/config.version"
INSTALLED_VERSION_FILE="$STATE_ROOT/.umrk-defaults-version"

# read_version FILE prints a plain integer, or fails for a missing/invalid file.
read_version() {
    [ -f "$1" ] || return 1
    _v="$(tr -d '[:space:]' <"$1" 2>/dev/null)" || return 1
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$_v"
}

# ini_get FILE SECTION KEY prints the key's value, or nothing when absent.
ini_get() {
    awk -v S="$2" -v K="$3" '
        BEGIN { in_s = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[ \t]*\[[^]]*\][ \t]*$/) {
                hdr = line
                sub(/^[ \t]*\[/, "", hdr)
                sub(/\][ \t]*$/, "", hdr)
                gsub(/^[ \t]+|[ \t]+$/, "", hdr)
                in_s = (hdr == S)
                next
            }
            if (!in_s) next
            k = line
            sub(/=.*/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != K) next
            v = line
            sub(/^[^=]*=/, "", v)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v
            exit
        }
    ' "$1" 2>/dev/null
}

# Add a key only when it is absent or empty; leave a present value alone.
cfg_ensure_key() {
    [ -n "$(ini_get "$1" "$2" "$3")" ] && return 0
    ini_set "$1" "$2" "$3" "$4"
}

# Replace a key only while it still holds a previously shipped default.
cfg_migrate_key() {
    [ "$(ini_get "$1" "$2" "$3")" = "$4" ] || return 0
    ini_set "$1" "$2" "$3" "$5"
}

record_defaults_version() {
    _tmp="$INSTALLED_VERSION_FILE.tmp.$$"
    printf '%s\n' "$1" >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$INSTALLED_VERSION_FILE" 2>/dev/null \
        || { rm -f "$_tmp" 2>/dev/null; log "could not record the installed defaults version"; return 1; }
}

if DEFAULTS_VERSION="$(read_version "$DEFAULTS_VERSION_FILE")"; then
    if INSTALLED_VERSION="$(read_version "$INSTALLED_VERSION_FILE")"; then
        :
    else
        [ -e "$INSTALLED_VERSION_FILE" ] && log "invalid installed defaults version; treating as 0"
        INSTALLED_VERSION=0
    fi
    if [ "$INSTALLED_VERSION" -lt "$DEFAULTS_VERSION" ]; then
        # Revision 2 added the Menu binding. Revision 3 moved the stylus to the
        # one stick the MLP1 has and added its tap buttons.
        if [ "$INSTALLED_VERSION" -lt 2 ]; then
            cfg_ensure_key "$GLOBAL_INI" padhotkeys pause.alt guide || die "cannot migrate global config"
        fi
        if [ "$INSTALLED_VERSION" -lt 3 ]; then
            cfg_migrate_key "$GLOBAL_INI" pad stick_dpad left none || die "cannot migrate global config"
            cfg_migrate_key "$GLOBAL_INI" pad stylus_axis right left || die "cannot migrate global config"
            cfg_ensure_key "$GLOBAL_INI" pad stick_dpad none || die "cannot migrate global config"
            cfg_ensure_key "$GLOBAL_INI" pad stylus_axis left || die "cannot migrate global config"
            cfg_ensure_key "$GLOBAL_INI" pad stylus_button +righttrigger || die "cannot migrate global config"
            cfg_ensure_key "$GLOBAL_INI" pad stylus_button.alt +lefttrigger || die "cannot migrate global config"
        fi
        record_defaults_version "$DEFAULTS_VERSION" || die "cannot record the defaults version"
        log "defaults migration: $INSTALLED_VERSION -> $DEFAULTS_VERSION"
    fi
else
    log "missing or invalid defaults/config.version; skipping defaults migration"
fi

# Only launch-bound paths are pak-owned. Controls/deadzones stay user-owned.
# A roster and a JSON file do not prove the selected pad was calibrated.
ini_set "$GAME_INI" paths states "$STATES_DIR" || die "cannot bind save-state path"
ini_set "$GAME_INI" paths screenshots "$SHOTS_DIR" || die "cannot bind screenshot path"
ini_set "$GAME_INI" paths cache "$CACHE_DIR" || die "cannot bind cache path"
ini_set "$GAME_INI" paths firmware_override "$GAME_DIR/firmware.ovr" || die "cannot bind firmware sidecar"

# --- archive policy ----------------------------------------------------------
# The emulator unpacks a deflated ROM from a .zip under paths.cache, which the
# per-game file above pins to this game's directory. Upstream would prefer a
# .dsperate directory beside the ROM when that is writable; --cache-root-only
# makes the configured root authoritative. The per-directory cap it enforces is
# per game, so the cross-game total and the free-space check live here, before
# anything is written. --single-rom makes an archive with more than one .nds a
# refusal rather than a database guess.
# Overridable so the wrapper tests can exercise the bounds without a 1 GiB
# fixture; the shipped defaults are the pak policy.
TOTAL_CACHE_MB="${DS_TOTAL_CACHE_MB:-1024}"
PER_ROM_CACHE_MB="${DS_PER_ROM_CACHE_MB:-512}"
CACHE_MARGIN_MB="${DS_CACHE_MARGIN_MB:-16}"

# Total size in KiB of every game cache except the one named.
cache_other_kb() {
    _keep="${1%/}"
    _sum=0
    for _d in "$CACHE_ROOT"/v2-*; do
        [ -d "$_d" ] || continue
        [ "$_d" = "$_keep" ] && continue
        _sz="$(du -sk "$_d" 2>/dev/null | awk '{print $1}')"
        [ -n "$_sz" ] && _sum=$((_sum + _sz))
    done
    printf '%s' "$_sum"
}

# The least recently used other game cache directory, or nothing.
cache_oldest_other() {
    _keep="${1%/}"
    _victim=""
    for _d in $(ls -dt "$CACHE_ROOT"/v2-* 2>/dev/null); do
        [ -d "$_d" ] || continue
        [ "$_d" = "$_keep" ] && continue
        _victim="$_d"   # last in newest-first order is the oldest
    done
    printf '%s' "$_victim"
}

cache_free_kb() {
    df -Pk "$CACHE_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Evict other games' caches until $1 KiB fit the total budget and the card, or
# refuse the launch with an explanation.
require_cache_room() {
    _need="$1"
    if [ "$_need" -gt $((PER_ROM_CACHE_MB * 1024)) ]; then
        log "ROM needs ${_need} KiB, over the ${PER_ROM_CACHE_MB} MiB per-ROM cache limit"
        show_notice "This game is too large to unpack" \
            "It needs more space than DSperate's per-game cache allows." \
            "Set a larger cache_mb in your configuration, or use another emulator."
        exit 0
    fi
    _budget=$((TOTAL_CACHE_MB * 1024))
    _margin=$((CACHE_MARGIN_MB * 1024))
    while :; do
        _others="$(cache_other_kb "$CACHE_DIR")"
        _free="$(cache_free_kb)"
        [ -n "$_free" ] || _free=0
        if [ $((_others + _need)) -le "$_budget" ] &&
           [ "$_free" -ge $((_need + _margin)) ]; then
            return 0
        fi
        _victim="$(cache_oldest_other "$CACHE_DIR")"
        [ -n "$_victim" ] || break
        rm -rf "$_victim" || break
        log "cache evicted for space: $_victim"
    done
    log "not enough room to unpack: need=${_need}KiB free=${_free}KiB other=${_others}KiB budget=${_budget}KiB"
    show_notice "Not enough space to unpack this game" \
        "Free space on the card, or extract the ROM to .nds yourself." \
        "DSperate keeps a cache of unpacked zipped games."
    exit 0
}

if [ "$ROM_EXT" = "zip" ]; then
    if ! _report="$("$BIN" --config "$GLOBAL_INI" --cache-root-only --single-rom \
            --inspect-cart "$ROM_PATH" 2>"$RUNTIME_DIR/inspect.err")"; then
        _reason="$(cat "$RUNTIME_DIR/inspect.err" 2>/dev/null)"
        [ -n "$_reason" ] || _reason="the archive could not be read"
        log "cannot open archive: $_reason"
        show_notice "This archive cannot be opened" "$_reason" \
            "Extract the ROM to a .nds file, or choose another emulator."
        exit 0
    fi
    _extract="$(printf '%s\n' "$_report" | sed -n 's/^extract=//p')"
    _bytes="$(printf '%s\n' "$_report" | sed -n 's/^bytes=//p')"
    case "$_bytes" in ''|*[!0-9]*) die "cannot size the archive for the cache" ;; esac
    if [ "$_extract" = "yes" ]; then
        require_cache_room "$(( (_bytes + 1023) / 1024 ))"
    fi
else
    # A loose .nds needs no unpacking: --inspect-cart still reports it, but the
    # cache checks and the single-ROM rule do not apply to it.
    :
fi

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
set -- --config "$GLOBAL_INI" --cache-root-only --single-rom \
       --save "$SAVES_DIR/$ROM_STEM.sav" \
       --no-disp --no-fbdev --fullscreen --no-mic

[ -n "$ARM9" ] && set -- "$@" --bios9 "$ARM9"
[ -n "$ARM7" ] && set -- "$@" --bios7 "$ARM7"
[ -n "$FW" ]   && set -- "$@" --firmware "$FW"

log "launching $BIN for $ROM_REL (saves=$SAVES_DIR states=$STATES_DIR)"
exec "$BIN" "$@" "$ROM_PATH"
