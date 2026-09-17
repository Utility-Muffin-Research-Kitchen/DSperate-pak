#!/usr/bin/env bash
# DSperate MLP1 device acceptance harness.
#
# Drives the installed pak on a device over SSH, using the Leaf uipad utility
# (scripts/devtools/uipad.c) to press buttons, and measures emulated speed and
# frame times. It is a qualification tool, not part of the pak build.
#
#   DS_SSH_PASS=... scripts/device-acceptance.sh scene  "ROM" TAG SECONDS "SEQ"
#   DS_SSH_PASS=... scripts/device-acceptance.sh report
#
# A "scene" run:
#   1. stops the launcher (so the pad is not consumed by it),
#   2. starts uipad and points DSperate at its event node,
#   3. launches the ROM through the pak wrapper with DS_FPS and a frame series,
#   4. waits out a warm-up, plays SEQ (uipad button names, space separated),
#   5. records for SECONDS total, screenshots, then SIGTERMs the emulator,
#   6. copies the log and frame series back under build/acceptance/TAG/.
#
# Then `report` summarises every scene: emulated speed, how much of the run held
# 95%, and frame-time percentiles from the series (warm-up frames dropped).
#
# Env:
#   DS_SSH_PASS   ssh password (required)
#   DS_SSH_TARGET default sshadmin@192.168.0.174
#   DS_SSH_PORT   default 2222
#   DS_ACCEPT_OUT default <repo>/build/acceptance
#   DS_WARMUP     default 20 (seconds before the sequence and the measurement)
set -euo pipefail

: "${DS_SSH_PASS:?set DS_SSH_PASS to the device ssh password}"
TARGET="${DS_SSH_TARGET:-}"
PORT="${DS_SSH_PORT:-2222}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${DS_ACCEPT_OUT:-$REPO/build/acceptance}"
WARMUP="${DS_WARMUP:-20}"

SD=/mnt/sdcard
PAK="$SD/Apps/mlp1/DSperate.pak"
ENVFILE="$SD/.system/leaf/platforms/mlp1/launcher/env.sh"
UIPAD=/tmp/uipad
FIFO=/tmp/uipad.fifo

log() { printf 'acceptance: %s\n' "$*" >&2; }

# The device's DHCP lease moves, so find it: an explicit DS_SSH_TARGET, else
# the address adb reports, else a /24 scan for a host whose SSH banner answers
# as the MLP1 rootfs.
resolve_target() {
    if [ -n "$TARGET" ]; then return; fi
    local serial ip myip sub found=""
    serial="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')"
    if [ -n "$serial" ]; then
        ip="$(adb -s "$serial" shell 'ip -4 addr show wlan0 2>/dev/null' | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
        if [ -n "$ip" ]; then TARGET="sshadmin@$ip"; return; fi
    fi
    myip="$(ifconfig 2>/dev/null | awk '/inet 192\.168\./{print $2; exit}')"
    [ -n "$myip" ] || { log "no adb and no 192.168 subnet; set DS_SSH_TARGET"; exit 1; }
    sub="$(printf '%s' "$myip" | cut -d. -f1-3)"
    local tmp; tmp="$(mktemp)"
    for i in $(seq 1 254); do ( nc -z -G 1 "$sub.$i" "$PORT" 2>/dev/null && printf '%s\n' "$sub.$i" >>"$tmp" ) & done
    wait
    for ip in $(sort -u "$tmp"); do
        if sshpass -p "$DS_SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 -p "$PORT" "sshadmin@$ip" 'test "$(hostname)" = rk3566-buildroot' 2>/dev/null; then
            found="$ip"; break
        fi
    done
    rm -f "$tmp"
    [ -n "$found" ] || { log "could not find the MLP1 on $sub.0/24; set DS_SSH_TARGET"; exit 1; }
    TARGET="sshadmin@$found"
}

resolve_target
SSH=(sshpass -p "$DS_SSH_PASS" ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -p "$PORT" "$TARGET")
SCP=(sshpass -p "$DS_SSH_PASS" scp -o StrictHostKeyChecking=no -P "$PORT")
rsh() { "${SSH[@]}" "$@"; }
log "device $TARGET"

dev_guard() {
    rsh 'test -f /mnt/sdcard/Apps/mlp1/DSperate.pak/pak.json' \
        || { log "DSperate pak not installed at $PAK"; exit 1; }
}

list_events() { rsh 'ls -1 /sys/class/input/ 2>/dev/null | grep "^event" | sort'; }

uipad_install() {   # push the built uipad if the device lost it (a reboot clears /tmp)
    rsh 'test -x /tmp/uipad' && return 0
    local bin="${DS_UIPAD_BIN:-$REPO/../Leaf/build/uipad}"
    if [ ! -x "$bin" ]; then log "no uipad binary at $bin (set DS_UIPAD_BIN)"; return 1; fi
    log "pushing uipad from $bin"
    "${SCP[@]}" "$bin" "$TARGET:$UIPAD" >/dev/null
    rsh "chmod 755 $UIPAD"
}

uipad_start() {   # prints the uipad's event node
    local before after
    uipad_install || return 1
    before="$(list_events)"
    rsh "rm -f $FIFO /tmp/uipad.out; mkfifo $FIFO; setsid $UIPAD --settle 1500 --hold 90 --gap 250 --serve $FIFO >/tmp/uipad.out 2>&1 < /dev/null & true"
    for _ in $(seq 1 20); do
        rsh 'grep -q ready /tmp/uipad.out 2>/dev/null' && break
        sleep 0.5
    done
    rsh 'grep -q ready /tmp/uipad.out 2>/dev/null' || { log "uipad did not start:"; rsh 'cat /tmp/uipad.out 2>/dev/null'; return 1; }
    after="$(list_events)"
    local node
    node="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)"
    [ -n "$node" ] || node="$(rsh 'for e in /sys/class/input/event*; do [ "$(cat $e/device/name 2>/dev/null)" = "Loong Gamepad" ] && [ ! -s "$e/device/phys" ] && basename "$e"; done | tail -1')"
    [ -n "$node" ] || { log "could not find the uipad event node"; return 1; }
    printf '/dev/input/%s' "$node"
}

uipad_send() { rsh "echo '$*' > $FIFO"; }
uipad_stop() { rsh 'pkill -x uipad 2>/dev/null; rm -f /tmp/uipad.fifo; true'; }

# The launcher is NOT stopped: it is supervised by Jawaka, and stopping the
# daemon also kills the supervised SSH server this harness runs over. The
# launcher enumerated its pads at startup, so it does not open the uipad that
# appears afterwards, and DSperate reads it by SDL_JOYSTICK_DEVICE.
emulator_running() { rsh 'pgrep -x dsperate >/dev/null && echo yes || echo no'; }

launch() {   # ROM TAG NODE
    local rom="$1" tag="$2" node="$3"
    # ROMs can live on either card; bind the wrapper's source paths to the one
    # the ROM is on, the way Jawaka would for a per-source launch.
    local src="" srcenv=""
    case "$rom" in
        /mnt/sdcard/*)    src=/mnt/sdcard ;;
        /media/sdcard1/*) src=/media/sdcard1 ;;
    esac
    if [ -n "$src" ]; then
        srcenv="ROMS_PATH=$src/Roms ROMS_PATHS=/mnt/sdcard/Roms:/media/sdcard1/Roms SAVES_PATH=$src/Saves STATES_PATH=$src/States"
    fi
    rsh "rm -f /tmp/ds-$tag.log /tmp/series-$tag.txt
         setsid sh -c '. $ENVFILE 2>/dev/null; export SDL_JOYSTICK_DEVICE=$node SDL_JOYSTICK_DISABLE_UDEV=1 DS_FPS=1 DS_FRAME_SERIES=/tmp/series-$tag.txt $srcenv; exec $PAK/scripts/run.sh \"$rom\" >>/tmp/ds-$tag.log 2>&1' >/dev/null 2>&1 < /dev/null &
         echo launched"
}

screenshot() {   # TAG
    local tag="$1"
    rsh 'kmsgrab --crtc 85 2>/dev/null' >"$OUT/$tag/screen.raw"
    python3 "$(dirname "${BASH_SOURCE[0]}")/../../umrk-workspace/.claude/skills/mlp1-screenshot/scripts/fb_to_png.py" \
        "$OUT/$tag/screen.raw" "$OUT/$tag/screen.png" >/dev/null 2>&1 || true
}

scene() {   # ROM TAG SECONDS "SEQ"
    local rom="$1" tag="$2" secs="$3" seq="${4:-}"
    local dir="$OUT/$tag"
    mkdir -p "$dir"
    dev_guard

    log "$tag: starting uipad"
    local node
    node="$(uipad_start)" || exit 1
    log "$tag: uipad at $node"
    printf 'rom=%s\nseconds=%s\nseq=%s\nnode=%s\n' "$rom" "$secs" "$seq" "$node" >"$dir/run.txt"

    log "$tag: launching $rom"
    launch "$rom" "$tag" "$node"
    sleep "$WARMUP"

    if [ -n "$seq" ]; then
        log "$tag: sending $seq"
        uipad_send "$seq"
        sleep 3
    fi

    local elapsed=$WARMUP
    while [ "$elapsed" -lt "$secs" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ "$(emulator_running)" = "no" ]; then log "$tag: emulator exited early"; break; fi
    done

    screenshot "$tag"
    log "$tag: stopping"
    rsh 'pkill -TERM -x dsperate 2>/dev/null; true'
    sleep 4
    uipad_stop

    "${SCP[@]}" "$TARGET:/tmp/ds-$tag.log" "$dir/run.log" >/dev/null 2>&1 || true
    "${SCP[@]}" "$TARGET:/tmp/series-$tag.txt" "$dir/series.txt" >/dev/null 2>&1 || true
    rsh "rm -f /tmp/ds-$tag.log /tmp/series-$tag.txt" || true
    log "$tag: done -> $dir"
}

report() {
    python3 - "$OUT" <<'PY'
import os, re, sys
root = sys.argv[1]
def pct(vals, p):
    if not vals: return float('nan')
    vals = sorted(vals)
    i = min(len(vals)-1, int(round((p/100)*(len(vals)-1))))
    return vals[i]
for tag in sorted(os.listdir(root)):
    d = os.path.join(root, tag)
    f = os.path.join(d, 'run.log')
    if not os.path.isfile(f): continue
    speeds, queued = [], []
    for line in open(f, errors='replace'):
        m = re.search(r'(\d+\.\d+) fps \((\d+)%\).*audio queued (\d+\.\d+) frames', line)
        if m:
            speeds.append(int(m.group(2)))
            queued.append(float(m.group(3)))
    series = []
    sf = os.path.join(d, 'series.txt')
    if os.path.isfile(sf):
        for i, line in enumerate(open(sf, errors='replace')):
            if i < 900: continue            # drop ~15 s warm-up
            p = line.split()
            if len(p) == 2:
                try: series.append((float(p[0]), float(p[1])))
                except ValueError: pass
    emu = [a for a, _ in series]
    work = [b for _, b in series]
    print(f'== {tag} ==')
    run = open(os.path.join(d, 'run.txt')).read().split('\n')[:3] if os.path.isfile(os.path.join(d,'run.txt')) else []
    for r in run:
        if r: print('  ' + r)
    if speeds:
        ok = sum(1 for s in speeds if s >= 95)
        print(f'  emulated speed: min {min(speeds)}% mean {sum(speeds)/len(speeds):.1f}% max {max(speeds)}%  '
              f'({ok}/{len(speeds)} seconds >=95%, {100*ok/len(speeds):.1f}%)')
    if queued:
        print(f'  audio queued frames: min {min(queued):.2f} mean {sum(queued)/len(queued):.2f} max {max(queued):.2f}')
    if emu:
        print(f'  emu ms : mean {sum(emu)/len(emu):.3f} p50 {pct(emu,50):.3f} p90 {pct(emu,90):.3f} p99 {pct(emu,99):.3f} max {max(emu):.3f} (n={len(emu)})')
        print(f'  work ms: mean {sum(work)/len(work):.3f} p50 {pct(work,50):.3f} p90 {pct(work,90):.3f} p99 {pct(work,99):.3f} max {max(work):.3f}')
    print()
PY
}

usage() {
    cat >&2 <<EOF
usage: DS_SSH_PASS=... $0 scene "ROM" TAG SECONDS "SEQ"
       DS_SSH_PASS=... $0 report
EOF
    exit 2
}

main() {
    case "${1:-}" in
        scene) [ "$#" -ge 4 ] || usage; scene "$2" "$3" "$4" "${5:-}" ;;
        report) report ;;
        *) usage ;;
    esac
}

main "$@"
