#!/usr/bin/env bash
# The pak ZIP and the corresponding-source tarball are byte-deterministic.
#
#   bash tests/test-archives.sh BUILD_DIR      (make test-archives)
#
# Builds each archive, disturbs everything the old archives leaked (every
# input's mtime, a different umask and a fresh package tree), builds it again
# and requires the same sha256. Then it opens both and checks the
# normalisation itself: sorted entries, SOURCE_DATE_EPOCH mtimes, owner 0 with
# no names, 0644/0755 modes, no ZIP extra fields and a gzip header with no name
# and no mtime. Needs the built binary (make standalone) and Docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:?usage: test-archives.sh BUILD_DIR}"
ZIP="$BUILD/dist/DSperate.mlp1.pak.zip"
TAR="$BUILD/dist/dsperate-corresponding-source.tar.gz"
EPOCH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"]["source_date_epoch"])' \
  "$REPO_ROOT/standalone/upstream.lock.json")"

sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
fail() { echo "test-archives: FAIL $*" >&2; exit 1; }

make -s -C "$REPO_ROOT" BUILD="$BUILD" dist-pakrat >/dev/null
make -s -C "$REPO_ROOT" BUILD="$BUILD" dist-source >/dev/null
zip1="$(sha "$ZIP")"
tar1="$(sha "$TAR")"

# Disturb every input: a fresh package tree (package-mlp1 recopies it, so its
# mtimes are new), new mtimes on every source input, and a looser umask. None
# of it may reach the archives.
find "$BUILD/dsperate-src" "$REPO_ROOT/standalone" "$REPO_ROOT/pak" "$REPO_ROOT/tests" \
  -path '*/.git' -prune -o -type f -exec touch -t 203001010101 {} +
(umask 000 && make -s -C "$REPO_ROOT" BUILD="$BUILD" dist-pakrat >/dev/null)
(umask 000 && make -s -C "$REPO_ROOT" BUILD="$BUILD" dist-source >/dev/null)
zip2="$(sha "$ZIP")"
tar2="$(sha "$TAR")"

[ "$zip1" = "$zip2" ] || fail "pak ZIP differs between two builds: $zip1 vs $zip2"
[ "$tar1" = "$tar2" ] || fail "source archive differs between two builds: $tar1 vs $tar2"

python3 - "$ZIP" "$TAR" "$EPOCH" <<'PY'
import gzip, stat, struct, sys, tarfile, time, zipfile
zip_path, tar_path, epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
problems = []

dos = time.gmtime(epoch)[:6]
dos = dos[:5] + (dos[5] // 2 * 2,)
with zipfile.ZipFile(zip_path) as z:
    infos = z.infolist()
    names = [i.filename for i in infos]
    if names != sorted(names):
        problems.append("zip entries are not sorted")
    for i in infos:
        mode = i.external_attr >> 16
        perm = stat.S_IMODE(mode)
        if i.date_time != dos:
            problems.append(f"zip mtime {i.date_time} on {i.filename}")
        if i.extra:
            problems.append(f"zip extra field on {i.filename}")
        if i.create_system != 3:
            problems.append(f"zip entry not marked Unix: {i.filename}")
        if i.is_dir():
            if perm != 0o755:
                problems.append(f"zip dir mode {oct(perm)} on {i.filename}")
        elif perm not in (0o644, 0o755):
            problems.append(f"zip file mode {oct(perm)} on {i.filename}")
    for exe in ("DSperate.pak/bin/dsperate", "DSperate.pak/bin/dsperate-notice",
                "DSperate.pak/scripts/run.sh"):
        if stat.S_IMODE(z.getinfo(exe).external_attr >> 16) != 0o755:
            problems.append(f"zip lost the executable bit on {exe}")

with open(tar_path, "rb") as f:
    head = f.read(10)
flags, mtime = head[3], struct.unpack("<I", head[4:8])[0]
if flags & 0x08:
    problems.append("gzip header carries a file name")
if mtime != 0:
    problems.append(f"gzip header mtime {mtime}")
with tarfile.open(tar_path) as t:
    members = t.getmembers()
    names = [m.name + ("/" if m.isdir() else "") for m in members]
    if names != sorted(names):
        problems.append("tar entries are not sorted")
    for m in members:
        if m.mtime != epoch:
            problems.append(f"tar mtime {m.mtime} on {m.name}")
        if m.uid or m.gid or m.uname or m.gname:
            problems.append(f"tar owner {m.uid}:{m.gid} {m.uname!r}:{m.gname!r} on {m.name}")
        if m.mode not in (0o644, 0o755) or (m.isdir() and m.mode != 0o755):
            problems.append(f"tar mode {oct(m.mode)} on {m.name}")
        if not (m.isfile() or m.isdir()):
            problems.append(f"tar entry is neither a file nor a directory: {m.name}")
        if "/.git/" in "/" + m.name + "/" or "__pycache__" in m.name:
            problems.append(f"tar carries VCS or cache data: {m.name}")

for p in problems[:20]:
    print("  " + p, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
echo "test-archives: pak ZIP  sha256 $zip1 (identical across two builds, normalised)"
echo "test-archives: source   sha256 $tar1 (identical across two builds, normalised)"
