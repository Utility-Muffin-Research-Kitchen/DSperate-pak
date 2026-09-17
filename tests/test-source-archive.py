#!/usr/bin/env python3
"""Check the distributed source contains the locked PGO and pak build inputs."""
import hashlib
import json
import sys
import tarfile
from pathlib import PurePosixPath


with tarfile.open(sys.argv[1]) as archive:
    def read(name):
        with archive.extractfile(name) as source:
            return source.read()

    lock = json.loads(read("standalone/upstream.lock.json"))
    for name in ("dsperate-src/CMakeLists.txt", "dsperate-src/LICENSE",
                 "standalone/build-dsperate.sh", "standalone/build-in-container.sh",
                 "standalone/mlp1-toolchain.cmake", "standalone/verify-binary.sh",
                 lock["notice"]["source"], lock["device"]["allowed_libraries"],
                 "LICENSES/REPO-LICENSE.txt", "Makefile", "pak/scripts/run.sh"):
        assert read(name), f"missing source input: {name}"
    for patch in lock["patches"]:
        assert hashlib.sha256(read("standalone/patches/" + patch["file"])).hexdigest() == patch["sha256"]
    profile_dir = PurePosixPath(lock["pgo"]["dir"])
    profile = sorted(member.name for member in archive.getmembers()
                     if member.isfile() and PurePosixPath(member.name).parent == profile_dir)
    assert str(profile_dir / "MANIFEST") in profile
    digest = hashlib.sha256()
    for name in profile:
        digest.update(PurePosixPath(name).name.encode() + b"\0")
        digest.update(read(name))
    assert digest.hexdigest() == lock["pgo"]["sha256"], "PGO profile differs from the shipped binary's lock"
print("test-source-archive: locked PGO, patches and build inputs present")
