#!/usr/bin/env bash
# Host checks for DSperate's standalone-ra-account-v1 consumer (patch 0005).
#
#   bash tests/test-ra-account.sh CONTRACT_DIR [WORK_DIR]     (make test-ra-account)
#
# The adapter's three files are new files in patch 0005, so they are taken
# straight out of the locked patch and compiled with the host C++ compiler --
# the same bytes the MLP1 build compiles, with no upstream checkout, Docker or
# device. Then:
#
#   1. the shared leaf-contracts fixtures, at the commit and sha256 pinned in
#      tests/ra-account/contract.lock.json, replayed through the emulator's own
#      classifier;
#   2. the marker and transition table (state_test.cpp);
#   3. the bridge itself (bridge_test.cpp): explicit "achievements off",
#      interrupted token and marker writes at every boundary, low storage,
#      corruption, a missing managed directory, pop-up notices, and an
#      unmanaged sign-in that persists nothing;
#   4. source checks on the patch for what a host test cannot run: the
#      frontend decides "achievements off" before import(), and nothing in the
#      adapter persists an unmanaged sign-in.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${1:?usage: test-ra-account.sh CONTRACT_DIR [WORK_DIR]}"
WORK="${2:-$REPO_ROOT/build/ra-account}"
TESTS="$REPO_ROOT/tests/ra-account"
LOCK="$TESTS/contract.lock.json"
CXX="${CXX:-c++}"

fail() { echo "test-ra-account: FAIL $*" >&2; exit 1; }
lock() { python3 -c 'import functools,json,sys;print(functools.reduce(lambda v,k:v[k],sys.argv[2:],json.load(open(sys.argv[1]))))' "$LOCK" "$@"; }
sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# --- the pin -----------------------------------------------------------------
PIN="$(lock leaf_contracts commit)"
FIXTURES="$CONTRACT_DIR/$(lock leaf_contracts fixtures path)"
[ -f "$FIXTURES" ] || fail "no fixtures at $FIXTURES; is $CONTRACT_DIR leaf-contracts at $PIN?"
[ "$(sha "$FIXTURES")" = "$(lock leaf_contracts fixtures sha256)" ] \
  || fail "fixtures.json sha256 $(sha "$FIXTURES") is not the pinned $(lock leaf_contracts fixtures sha256)"
if head="$(git -C "$CONTRACT_DIR" rev-parse HEAD 2>/dev/null)" && [ "$head" != "$PIN" ]; then
  echo "note: $CONTRACT_DIR is at $head, not the pinned $PIN; its fixtures match the pinned sha256"
fi
grep -q "^CONTRACT_REF ?= $PIN\$" "$REPO_ROOT/Makefile" || fail "Makefile CONTRACT_REF is not the pinned $PIN"
grep -q "CONTRACT_REF: $PIN\$" "$REPO_ROOT/.github/workflows/ci.yml" || fail "CI CONTRACT_REF is not the pinned $PIN"
echo "ok   leaf-contracts $PIN, fixtures.json $(lock leaf_contracts fixtures sha256)"

# --- the adapter source, straight out of the locked patch --------------------
PATCH="$REPO_ROOT/standalone/patches/$(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1]))["patches"]:
    if "ra-account" in p["file"]: print(p["file"])' "$REPO_ROOT/standalone/upstream.lock.json")"
[ -f "$PATCH" ] || fail "no account adapter patch in the lock"
rm -rf "$WORK"
mkdir -p "$WORK/src"
# GIT_CEILING_DIRECTORIES: WORK usually sits inside this repository's own
# checkout, and git apply inside a work tree resolves paths from its top.
(cd "$WORK/src" && GIT_CEILING_DIRECTORIES="$WORK" git apply --include='src/cheevos/ra_account*' "$PATCH") \
  || fail "could not extract the adapter from $(basename "$PATCH")"
SRC="$WORK/src/src"
for f in ra_account.h ra_account_contract.cpp ra_account_bridge.cpp; do
  [ -f "$SRC/cheevos/$f" ] || fail "patch does not add src/cheevos/$f"
done

FLAGS=(-std=c++17 -Wall -Wextra -Werror -O1 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
       -DDS_RA_ACCOUNT_TESTING -I "$SRC")
LIBS=()
[ "$(uname -s)" = Linux ] && LIBS=(-ldl)
"$CXX" "${FLAGS[@]}" -o "$WORK/probe" "$TESTS/probe.cpp" "$SRC/cheevos/ra_account_contract.cpp"
"$CXX" "${FLAGS[@]}" -o "$WORK/state_test" "$TESTS/state_test.cpp" "$SRC/cheevos/ra_account_contract.cpp"
"$CXX" "${FLAGS[@]}" -o "$WORK/bridge_test" "$TESTS/bridge_test.cpp" \
  "$SRC/cheevos/ra_account_contract.cpp" "$SRC/cheevos/ra_account_bridge.cpp" ${LIBS[@]+"${LIBS[@]}"}

# --- 1-3 -----------------------------------------------------------------------
python3 "$TESTS/run-contract-fixtures.py" "$WORK/probe" "$FIXTURES" > "$WORK/fixtures.log" \
  || { cat "$WORK/fixtures.log"; fail "contract fixtures"; }
cases="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["cases"]))' "$FIXTURES")"
[ "$cases" = "$(lock leaf_contracts fixtures cases)" ] || fail "expected $(lock leaf_contracts fixtures cases) fixtures, found $cases"
tail -n 1 "$WORK/fixtures.log"
"$WORK/state_test" > "$WORK/state.log" || { grep -v '^ok' "$WORK/state.log"; fail "account state checks"; }
tail -n 1 "$WORK/state.log"
"$WORK/bridge_test" > "$WORK/bridge.log" || { grep -v '^ok' "$WORK/bridge.log"; fail "account bridge checks"; }
tail -n 1 "$WORK/bridge.log"

# --- 4. source checks ------------------------------------------------------------
added() { awk -v f="$1" '/^diff --git /{on = ($0 ~ f)} on && /^\+/' "$PATCH"; }
MAIN="$(added 'src/frontend/sdl/main.cpp')"
grep -q 'cfg.has("cheevos.enabled")' <<<"$MAIN" \
  || fail "the frontend does not look for an explicit cheevos.enabled before import()"
grep -q 'ra_account::import(cheevos_setting && !cheevos_setting_on)' <<<"$MAIN" \
  || fail "the frontend does not hand an explicit off to import()"
grep -q 'ra_account::achievementsOn(' <<<"$MAIN" \
  || fail "the frontend does not take cheevos_on from achievementsOn()"
grep -q 'ra_account::captureEnv()' <<<"$MAIN" \
  || fail "the frontend does not capture the handoff at startup"
grep -q '!m.account' <<<"$MAIN" \
  || fail "account pop-ups are not exempt from the toasts switch"
if grep -Eq 'save_credentials\(|setNativeDir|Config::dir\(\)' <<<"$(added 'src/')"; then
  fail "the adapter persists a sign-in outside the managed directory (G22)"
fi
grep -q 'ra_account::takeNotices()' <<<"$(added 'src/cheevos/cheevos_client.cpp')" \
  || fail "the achievement client does not drain the bridge's notices into its pop-ups"
echo "ok   frontend wiring: explicit off before import, startup capture, account pop-ups, no unmanaged persistence"
echo "test-ra-account: passed"
