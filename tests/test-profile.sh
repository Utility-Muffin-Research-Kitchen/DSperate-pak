#!/bin/sh
# Guards the shipped MLP1 default profile.
#
# The Miniloong Pocket 1 pad has one stick (left), no R3 and no right stick.
# SDL reports its controls as:
#
#   buttons a b x y back guide start leftstick leftshoulder rightshoulder
#           dpup dpdown dpleft dpright
#   axes    leftx lefty triggerleft triggerright
#
# (verified on the device with the SDL capability dump). Nothing this pak ships
# may bind rightx, righty or rightstick, and the stylus must use controls the
# pad has.
#
#   sh tests/test-profile.sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INI="$REPO_ROOT/pak/defaults/dsperate.ini"
MANIFEST="$REPO_ROOT/pak/pak.json"

checks=0
failures=0
pass() { checks=$((checks + 1)); }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $*"; }

# Active settings only; the comments name the forbidden controls on purpose.
ACTIVE="$(grep -v '^[[:space:]]*#' "$INI")"

# No binding may name a control the pad lacks.
for token in rightstick rightx righty; do
    if printf '%s\n' "$ACTIVE" | grep -iq "$token"; then fail "default profile names $token"; else pass; fi
done
if printf '%s\n' "$ACTIVE" | grep -iq 'stylus_axis[[:space:]]*=[[:space:]]*right'; then
    fail "stylus_axis is the right stick"
else pass; fi

# The stylus uses the one stick and a real button.
grep -q '^stylus_axis = left$' "$INI" && pass || fail "stylus_axis should be left"
grep -q '^stylus_button = +righttrigger$' "$INI" && pass || fail "stylus_button should be +righttrigger"
grep -q '^stick_dpad = none$' "$INI" && pass || fail "stick_dpad should be none (the stick is the pen)"

# The Menu contract this profile assumes.
grep -q '^modifier = back$' "$INI" && pass || fail "modifier should be back"
grep -q '^pause.alt = guide$' "$INI" && pass || fail "pause.alt should be guide"
grep -q '"supports_menu": true' "$MANIFEST" && pass || fail "pak.json should declare supports_menu: true"

# The wrapper must disable DSperate's deadzone when Jawaka's calibrated virtual
# pad already normalized the stick, and only then.
WRAPPER="$REPO_ROOT/pak/scripts/run.sh"
grep -q 'loong-gamepad-calibration.json' "$WRAPPER" && pass || fail "wrapper should look for the calibration profile"
grep -q 'ini_set "\$GAME_INI" pad stick_deadzone' "$WRAPPER" && pass || fail "wrapper should set the stick deadzone per launch"

echo "test-profile: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
