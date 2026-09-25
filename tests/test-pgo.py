#!/usr/bin/env python3
"""Check the locked PGO profile and the build's strictness gate, without a
build, Docker or a device.

    python3 tests/test-pgo.py

This is the PGO check. `tests/test-profile.sh` is a different thing: the MLP1
default *pad* profile (controls).

What it proves: the profile directory is exactly the one the lock pins (a
sha256 over every file's name and bytes, the same digest build-dsperate.sh
checks), its MANIFEST names the fingerprint, compiler, source commit, date and
scenes the lock records, and the container build consumes it with
-DDSPERATE_PGO_STRICT=ON and fails on an untrained object or a changed
function. What it does not prove: that the profile makes the binary faster on
the MLP1. That is a device measurement, and it is still pending for this
candidate.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK = REPO / "standalone" / "upstream.lock.json"
BUILD_SCRIPT = REPO / "standalone" / "build-in-container.sh"

checks = 0
failures = 0


def check(ok: bool, what: str) -> None:
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print(f"FAIL {what}")


def profile_sha256(root: Path) -> str:
    # Must stay identical to profile_sha256() in standalone/build-dsperate.sh.
    digest = hashlib.sha256()
    for name in sorted(os.listdir(root)):
        path = root / name
        if not path.is_file():
            continue
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> int:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    build = lock["build"]
    check(build.get("pgo") == "use", "lock: build.pgo is 'use'")
    pgo = lock["pgo"]
    root = REPO / pgo["dir"]
    check(root.is_dir(), f"profile directory exists: {pgo['dir']}")
    if not root.is_dir():
        print(f"test-pgo: {checks - failures}/{checks} checks passed")
        return 1

    files = sorted(p.name for p in root.iterdir() if p.is_file())
    check(len(files) == pgo["files"],
          f"profile has {pgo['files']} files (found {len(files)})")
    check("MANIFEST" in files, "profile has a MANIFEST")
    strays = [n for n in files if n != "MANIFEST" and not n.endswith(".gcda")]
    check(not strays, f"profile holds only .gcda files and MANIFEST (strays: {strays})")
    check(not [p for p in root.iterdir() if not p.is_file()],
          "profile directory has no subdirectories")
    check(profile_sha256(root) == pgo["sha256"],
          "profile directory sha256 matches the lock")

    manifest: dict[str, str] = {}
    for line in (root / "MANIFEST").read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition(" ")
        check(key not in manifest, f"MANIFEST key is not repeated: {key}")
        manifest[key] = value
    check(manifest.get("fingerprint") == pgo["fingerprint"],
          "MANIFEST fingerprint matches the lock")
    check(re.fullmatch(r"[0-9a-f]{40}", manifest.get("fingerprint", "")) is not None,
          "MANIFEST fingerprint is a SHA-1")
    check(manifest.get("compiler") == pgo["compiler"], "MANIFEST compiler matches the lock")
    check(manifest.get("commit") == pgo["source_commit"], "MANIFEST commit matches the lock")
    check(pgo["source_commit"] == lock["core"]["source_commit"],
          "profile was trained on the pinned source commit")
    check(manifest.get("date") == pgo["date"], "MANIFEST date matches the lock")
    check(manifest.get("scenes") == pgo["scenes"], "MANIFEST scenes match the lock")

    # The container build: every flag the lock records is passed, including the
    # strictness switch, and the gate that turns its warnings into a failure is
    # present.
    script = BUILD_SCRIPT.read_text(encoding="utf-8")
    passed = set(re.findall(r"^\s*(-D[A-Z_]+=\S+?)\s*\\?$", script, re.MULTILINE))
    # The one flag the script takes from the lock through the environment.
    passed = {flag.replace('"$CHEEVOS_VERSION"', build["cheevos_version"]) for flag in passed}
    locked = {flag.replace("<standalone>", "/standalone") for flag in build["cmake"]}
    check(passed == locked,
          f"build-in-container.sh passes exactly the lock's CMake flags "
          f"(only in script: {sorted(passed - locked)}, only in lock: {sorted(locked - passed)})")
    check("-DDSPERATE_PGO_STRICT=ON" in locked, "lock records -DDSPERATE_PGO_STRICT=ON")
    check(f"-DDSPERATE_PGO_DIR=/standalone/{Path(pgo['dir']).relative_to('standalone')}" in passed,
          "the build reads the locked profile directory")
    check("-DDSPERATE_PGO=use" in passed, "the build consumes the profile")
    gate = script[script.find("PGO_UNTRAINED="):]
    check("data file not found" in gate and "control flow of function" in gate,
          "the strict gate counts untrained objects and changed functions")
    check(re.search(r'if \[ "\$pgo_unexpected" != 0 \]; then.*?exit 1', gate, re.S) is not None,
          "an untrained object outside the never-trained groups fails the build")
    check(re.search(r'if \[ "\$pgo_mismatch" != 0 \]; then.*?exit 1', gate, re.S) is not None,
          "a control-flow mismatch fails the build")
    check(re.search(r'if \[ "\$pgo_missing" = 0 \]; then.*?exit 1', gate, re.S) is not None,
          "a build without any strict warnings fails (the gate must have run)")
    check(script.find("PGO_UNTRAINED=") < script.find('"$CROSS-strip"'),
          "the gate runs before the artifact is written")

    print(f"test-pgo: {checks - failures}/{checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
