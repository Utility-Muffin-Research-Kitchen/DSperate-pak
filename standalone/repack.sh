#!/usr/bin/env bash
# One command: pull the latest upstream, check its UI text against what the
# localization patch already covers, and -- when nothing new needs translating --
# build and package.
#
#   ./standalone/repack.sh                 check, then build and package
#   ./standalone/repack.sh --check-only    the check alone, no build
#   ./standalone/repack.sh --ref v2.0.1    check a specific upstream ref
#   ./standalone/repack.sh --follow        move the pinned commit to the
#                                          checked ref and rebuild
#   ./standalone/repack.sh --refresh-baseline
#                                          record the pinned tree as baseline
#
# Upstream is fetched from the lock's source_url. "Latest" is the newest tag
# that is not the pinned one; failing that, the head of the default branch. If
# upstream has moved, the candidate is checked before anything is built: a
# string the localization does not yet cover stops the run with exit 3 and a
# list of what to translate. If the text is unchanged, the pinned commit still
# builds -- it is the same text upstream has, so there is nothing to translate
# and nothing to rebase.
#
# Exit codes:
#   0  packed
#   3  upstream text moved; translate into 0005 and rerun
#   4  the pinned upstream ref no longer exists upstream
#   5  no baseline recorded yet, or the scanner version changed
#   6  a build or packaging step failed
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/standalone/upstream.lock.json"
BASELINE="$REPO_ROOT/standalone/localization.baseline.tsv"
CHECKER="$REPO_ROOT/standalone/check-upstream-text.py"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
SRC_DIR="$BUILD_DIR/dsperate-src"
PROBE_DIR="$BUILD_DIR/upstream-probe"

die() { echo "repack: $*" >&2; exit "${EXIT_CODE:-6}"; }
say() { echo "repack: $*"; }
warn() { echo "repack: warning: $*" >&2; }

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

REF=""
CHECK_ONLY=0
FOLLOW=0
SKIP_CHECK=0
REFRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --check-only) CHECK_ONLY=1 ;;
    --skip-check) SKIP_CHECK=1; warn "skipping the text check; the pack is not verified against upstream" ;;
    --follow) FOLLOW=1 ;;
    --refresh-baseline) REFRESH=1 ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "$LOCK" ] || die "no lock at $LOCK"
[ -f "$CHECKER" ] || die "no check-upstream-text.py at $CHECKER"

# lock KEY [KEY...] prints one value from the lock; list indices are numbers.
lock() {
  python3 - "$LOCK" "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
PY
}

# The files check-upstream-text.py scans, taken from the scanner itself so the
# two cannot drift apart.
SCANNED_FILES="$(python3 - "$CHECKER" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("\n".join(m.FILES))
PY
)"

SOURCE_URL="$(lock core source_url)"
PINNED_TAG="$(lock core source_tag)"
PINNED_COMMIT="$(lock core source_commit)"

say "pinned: $PINNED_TAG $PINNED_COMMIT"

# ---------------------------------------------------------------------------
# 1. the clone
# ---------------------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  say "cloning $SOURCE_URL (large; one time)"
  mkdir -p "$BUILD_DIR"
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$SOURCE_URL"
fi

# A patch or a hand edit left behind would block the switch, so every checkout
# starts from the commit itself. The clean runs before any patch is applied,
# when the only files present are upstream's, which is why it is -fd and not
# -fdx: a later patch may create a file that is untracked at this point.
checkout_commit() {
  local commit="$1"
  if [ "$(git -C "$SRC_DIR" rev-parse -q --verify HEAD 2>/dev/null)" != "$commit" ]; then
    say "fetching $commit"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$commit" \
      || EXIT_CODE=4 die "could not fetch $commit from $SOURCE_URL"
    git -C "$SRC_DIR" reset -q --hard "$commit"
    git -C "$SRC_DIR" clean -qfd
    git -C "$SRC_DIR" checkout -q --detach "$commit"
  fi
  [ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$commit" ] \
    || EXIT_CODE=4 die "checked out the wrong commit"
}

# ---------------------------------------------------------------------------
# 2. what is new upstream
# ---------------------------------------------------------------------------
# The newest tag that is not the pinned one, or -- with no such tag -- the head
# of the default branch. Neither needs history, so a shallow clone is enough.
candidate_upstream() {
  local want="$1" line name
  if [ -n "$want" ]; then
    while read -r line name; do
      if [ "$name" = "refs/tags/$want" ]; then
        printf '%s %s\n' "$line" "$want"
        return 0
      fi
    done < <(git -C "$SRC_DIR" ls-remote --tags --refs origin 2>/dev/null)
    return 0
  fi

  local candidates=()
  while read -r line name; do
    [ "$name" = "refs/tags/$PINNED_TAG" ] && continue
    name="${name#refs/tags/}"
    case "$name" in v[0-9]*) candidates+=("$name $line") ;; esac
  done < <(git -C "$SRC_DIR" ls-remote --tags --refs origin 2>/dev/null)
  if [ "${#candidates[@]}" -gt 0 ]; then
    local best name sha
    best="$(printf '%s\n' "${candidates[@]}" | sort -V -k1 | tail -1)"
    name="${best%% *}"
    sha="${best#* }"
    printf '%s %s\n' "$sha" "$name"
    return 0
  fi

  # With no newer release, fall back to the default branch head.
  while read -r line name; do
    case "$name" in
      refs/heads/master|refs/heads/main)
        printf '%s %s(default branch head)\n' "$line" "${name#refs/heads/}"
        return 0 ;;
    esac
  done < <(git -C "$SRC_DIR" ls-remote --heads origin 2>/dev/null)
}

TARGET_COMMIT=""
TARGET_LABEL="$PINNED_TAG"
if git -C "$SRC_DIR" ls-remote --exit-code --heads origin >/dev/null 2>&1; then
  TARGET_LABEL="$(candidate_upstream "$REF" || true)"
  if [ -n "$TARGET_LABEL" ]; then
    TARGET_COMMIT="${TARGET_LABEL%% *}"
    TARGET_LABEL="${TARGET_LABEL#* }"
  else
    warn "upstream reported nothing newer than $PINNED_TAG $PINNED_COMMIT"
  fi
else
  warn "cannot reach $SOURCE_URL; falling back to the pinned commit"
fi

if [ -z "$TARGET_COMMIT" ] || [ "$TARGET_COMMIT" = "$PINNED_COMMIT" ]; then
  say "upstream latest is the pinned commit $PINNED_COMMIT"
  TARGET_COMMIT="$PINNED_COMMIT"
  TARGET_LABEL="$PINNED_TAG"
else
  say "upstream latest: $TARGET_LABEL $TARGET_COMMIT"
fi

# ---------------------------------------------------------------------------
# 3. the text check
# ---------------------------------------------------------------------------
# Only the two scanned files are taken out of the candidate commit; the scanner
# needs nothing else, and this keeps the probe directory two files wide.
probe_dir="$PROBE_DIR/candidate"
rm -rf "$probe_dir"
mkdir -p "$probe_dir"
probe_commit() {
  local commit="$1" dest="$2" rel
  for rel in $SCANNED_FILES; do
    mkdir -p "$dest/$(dirname "$rel")"
    git -C "$SRC_DIR" show "$commit:$rel" >"$dest/$rel" \
      || die "the candidate commit has no $rel"
  done
}

run_check() {
  local commit="$1" rc
  say "probing $commit"
  probe_commit "$commit" "$probe_dir"
  python3 "$CHECKER" --src "$probe_dir" --quiet
  rc=$?
  case "$rc" in
    0) ;;
    3)
      echo
      say "upstream moved its UI text. Translating it is manual work:"
      say "  take each '+ string' above into tr_data.inc and the literals in"
      say "  menu.cpp / settings.cpp, regenerate 0005, then rerun this script."
      exit 3 ;;
    5) EXIT_CODE=5 die "no usable baseline at $BASELINE" ;;
    *) EXIT_CODE="$rc" die "check-upstream-text.py failed ($rc)" ;;
  esac
}

if [ "$REFRESH" = "1" ]; then
  checkout_commit "$PINNED_COMMIT"
  rm -rf "$PROBE_DIR/pinned"
  mkdir -p "$PROBE_DIR/pinned"
  probe_commit "$PINNED_COMMIT" "$PROBE_DIR/pinned"
  say "recording the baseline from the pinned commit"
  python3 "$CHECKER" --src "$PROBE_DIR/pinned" --write-baseline "$BASELINE"

  # The fingerprint comes from the scanner, not from a second copy of the
  # rules here: one implementation of the hash, or the lock would start to
  # disagree with the tool that is supposed to check it.
  FP="$(python3 "$CHECKER" --fingerprint-of "$PROBE_DIR/pinned")"
  ENTRIES="$(python3 -c "
import sys
print(sum(1 for l in open(sys.argv[1], encoding='utf-8')
          if l.strip() and not l.startswith('#')))" "$BASELINE")"

  python3 - "$LOCK" "$PINNED_COMMIT" "$PINNED_TAG" "$FP" "$ENTRIES" <<'PY'
import json, sys
path, commit, tag, fp, entries = sys.argv[1:6]

lock = json.load(open(path, encoding="utf-8"))
section = {
    "scanner": 1,
    "baseline_file": "standalone/localization.baseline.tsv",
    "baseline_commit": commit,
    "baseline_tag": tag,
    "fingerprint": fp,
    "entries": int(entries),
    "note": "The menu's UI text at the pinned commit, as check-upstream-text.py "
            "reads it. repack.sh re-reads the same files out of the newest "
            "upstream tag and stops with exit 3 on anything the localization "
            "does not cover, so a pack never ships a string nobody translated.",
}
ordered = {}
for key, value in lock.items():
    if key == "patches":
        ordered["localization"] = section
    ordered[key] = value
ordered.setdefault("localization", section)
lock = ordered
with open(path, "w", encoding="utf-8") as f:
    json.dump(lock, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  say "recorded the baseline fingerprint in $LOCK"
  exit 0
fi

if [ "$SKIP_CHECK" = "1" ]; then
  say "skipping the text check"
elif [ ! -f "$BASELINE" ]; then
  EXIT_CODE=5 die "no baseline at $BASELINE; run 'standalone/repack.sh --refresh-baseline' once"
elif [ -n "$REF" ]; then
  # An explicit ref: examine it, whatever it turns out to be.
  checkout_commit "$TARGET_COMMIT"
  run_check "$TARGET_COMMIT"
elif [ "$TARGET_COMMIT" = "$PINNED_COMMIT" ]; then
  # Reaches here only when the pin is the newest release and "latest" fell back
  # to the pin itself.
  say "the pinned commit is upstream's newest release; there is nothing newer to translate"
elif [ ! "$TARGET_LABEL" = "${TARGET_LABEL#v}" ] &&
     ! printf '%s\n%s\n' "$TARGET_LABEL" "$PINNED_TAG" | sort -V | tail -1 | grep -qx "$TARGET_LABEL"; then
  # The candidate predates the pin. The check exists so a pack never ships a
  # string nobody translated, and this binary draws the pinned release's text:
  # an older tag's strings (v2.1.0's SMOOTH, which v2.1.1 replaced with
  # ACCURATE/ENHANCED) are not drawn anywhere, so failing over them would stop a
  # correct build for text that ships in nothing.
  say "upstream's newest tag $TARGET_LABEL predates the pinned $PINNED_TAG"
  say "its text is not drawn by this build, so there is nothing to check"
elif [ "$TARGET_COMMIT" != "$PINNED_COMMIT" ]; then
  checkout_commit "$TARGET_COMMIT"
  run_check "$TARGET_COMMIT"
fi

if [ "$CHECK_ONLY" = "1" ]; then
  say "check only; nothing built"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. build and package
# ---------------------------------------------------------------------------
if [ "$FOLLOW" = "1" ] && [ "$TARGET_COMMIT" != "$PINNED_COMMIT" ]; then
  say "moving the pin from $PINNED_COMMIT to $TARGET_COMMIT ($TARGET_LABEL)"
  python3 - "$LOCK" "$PINNED_COMMIT" "$TARGET_COMMIT" "$TARGET_LABEL" <<'PY'
import json, re, sys
path, old, new, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(path, encoding="utf-8").read()
text = text.replace('"source_commit": "%s"' % old, '"source_commit": "%s"' % new)
text = re.sub(r'"source_tag": "[^"]*"', '"source_tag": "%s"' % label, text, count=1)
text = re.sub(r'("source_commit": ")[0-9a-f]{40}', r'\g<1>%s' % new, text, count=1)
open(path, "w", encoding="utf-8").write(text)
assert json.load(open(path, encoding="utf-8"))["core"]["source_commit"] == new
PY
  say "the artifact hash in the lock is now stale: reproduce twice with"
  say "FORCE=1 and record the new one before publishing."
  say "the PGO profile was trained on $PINNED_COMMIT; re-train if emulation changed."
fi

say "building and packaging"
(cd "$REPO_ROOT" && make dist-pakrat) || EXIT_CODE=6 die "make dist-pakrat failed"

ZIP="$(ls -t "$BUILD_DIR"/dist/*.pak.zip 2>/dev/null | head -1)"
say "packed $ZIP"
say "done"
