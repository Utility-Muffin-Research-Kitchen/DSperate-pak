#!/usr/bin/env python3
"""Check the candidate is self-consistent: the runtime manifest, the lock and
the patch series describe the same DSperate.

    python3 tests/test-lock.py

- `pak/pak.json`'s `pak_version` is the pinned upstream release (the pak
  version tracks the emulator), and so is the achievement client version the
  build passes;
- every patch the lock names exists, in numeric order, with the locked sha256,
  and no patch file sits in `standalone/patches/` without a lock entry (the
  build would silently skip it).

`pakrat.json` is the store listing and deliberately trails the candidate until
it is published, so it is not checked here.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
checks = 0
failures = 0


def check(ok: bool, what: str) -> None:
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print(f"FAIL {what}")


def main() -> int:
    lock = json.loads((REPO / "standalone/upstream.lock.json").read_text(encoding="utf-8"))
    manifest = json.loads((REPO / "pak/pak.json").read_text(encoding="utf-8"))

    tag = lock["version"]["tag"]
    check(tag == lock["core"]["source_tag"], "version.tag is the pinned source tag")
    check(lock["core"]["source_commit"].startswith(lock["version"]["commit"]),
          "version.commit abbreviates the pinned source commit")
    release = tag[1:] if tag.startswith("v") else tag
    check(manifest.get("pak_version") == release,
          f"pak.json pak_version is {release} (found {manifest.get('pak_version')})")
    check(lock["build"]["cheevos_version"] == release,
          "the achievement client version is the pinned release")

    patches = lock.get("patches", [])
    names = [p["file"] for p in patches]
    check(names == sorted(names), "locked patches are listed in apply order")
    for index, patch in enumerate(patches, start=1):
        check(re.match(rf"{index:04d}-[a-z0-9-]+\.patch$", patch["file"]) is not None,
              f"patch {index} is numbered {index:04d}: {patch['file']}")
        path = REPO / "standalone/patches" / patch["file"]
        check(path.is_file(), f"locked patch exists: {patch['file']}")
        if path.is_file():
            check(hashlib.sha256(path.read_bytes()).hexdigest() == patch["sha256"],
                  f"patch sha256 matches the lock: {patch['file']}")
    on_disk = sorted(p.name for p in (REPO / "standalone/patches").glob("*.patch"))
    check(on_disk == names, f"no unlocked patch files (on disk {on_disk})")

    print(f"test-lock: {checks - failures}/{checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
