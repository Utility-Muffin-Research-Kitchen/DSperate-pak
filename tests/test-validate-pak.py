#!/usr/bin/env python3
"""validate-pak.py checks the standalone-ra-account-v1 capability record.

    python3 tests/test-validate-pak.py <leaf-contracts checkout>   (make test-validate-pak)

Jawaka hands the Leaf RetroAchievements account to DSperate only when the
installed pak carries `ra-account-v1` holding exactly `standalone-ra-account-v1`,
optionally followed by one newline. The validator must accept exactly that,
refuse anything else wherever the record appears, and require it in a built
package. Runs the real validator against copies of pak/ and a stand-in package
tree; no build needed.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VALIDATOR = REPO / "scripts" / "validate-pak.py"
checks = 0
failures = 0


def check(ok: bool, what: str) -> None:
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print(f"FAIL {what}")


def validate(contract: Path, pak: Path, packaged: bool) -> tuple[bool, str]:
    cmd = [sys.executable, str(VALIDATOR), "--contract", str(contract), "--pak", str(pak)]
    if packaged:
        cmd.append("--packaged")
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.returncode == 0, result.stdout


def stand_in_package(root: Path) -> Path:
    """The shape package-mlp1 produces, with placeholder binaries."""
    package = root / "DSperate.pak"
    shutil.copytree(REPO / "pak", package)
    for rel in ("bin/dsperate", "bin/dsperate-notice"):
        path = package / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
    (package / "scripts/run.sh").chmod(0o755)
    for rel in ("LICENSE-DSPERATE.txt", "LICENSE-THIRD-PARTY.txt"):
        (package / rel).write_text("licence\n")
    return package


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    contract = Path(sys.argv[1]).resolve()
    record = REPO / "pak" / "ra-account-v1"
    check(record.read_bytes() in (b"standalone-ra-account-v1", b"standalone-ra-account-v1\n"),
          "the shipped pak/ra-account-v1 holds the contract id")

    good = [b"standalone-ra-account-v1", b"standalone-ra-account-v1\n"]
    bad = {
        "two trailing newlines": b"standalone-ra-account-v1\n\n",
        "CRLF": b"standalone-ra-account-v1\r\n",
        "trailing space": b"standalone-ra-account-v1 \n",
        "leading space": b" standalone-ra-account-v1\n",
        "a UTF-8 BOM": b"\xef\xbb\xbfstandalone-ra-account-v1\n",
        "another version": b"standalone-ra-account-v2\n",
        "an empty file": b"",
        "an embedded NUL": b"standalone-ra-account-v1\0\n",
        "a second line": b"standalone-ra-account-v1\nextra\n",
    }
    with tempfile.TemporaryDirectory(prefix="dsperate-validate-") as tmp:
        tmp_path = Path(tmp)
        for packaged in (False, True):
            mode = "package" if packaged else "source tree"
            case_root = tmp_path / mode.replace(" ", "-")
            case_root.mkdir()
            if packaged:
                pak = stand_in_package(case_root)
            else:
                pak = case_root / "pak"
                shutil.copytree(REPO / "pak", pak)
            target = pak / "ra-account-v1"

            ok, out = validate(contract, pak, packaged)
            check(ok and "ok   ra-account" in out, f"{mode}: the shipped record passes\n{out}")
            for content in good:
                target.write_bytes(content)
                ok, out = validate(contract, pak, packaged)
                check(ok, f"{mode}: accepts {content!r}\n{out}")
            for label, content in bad.items():
                target.write_bytes(content)
                ok, out = validate(contract, pak, packaged)
                check(not ok and "FAIL ra-account" in out, f"{mode}: refuses {label}\n{out}")

            target.unlink()
            target.mkdir()
            ok, out = validate(contract, pak, packaged)
            check(not ok and "not a regular file" in out, f"{mode}: refuses a directory\n{out}")
            target.rmdir()
            os.symlink("elsewhere", target)
            ok, out = validate(contract, pak, packaged)
            check(not ok and "not a regular file" in out, f"{mode}: refuses a symlink\n{out}")
            target.unlink()

            ok, out = validate(contract, pak, packaged)
            if packaged:
                check(not ok and "missing ra-account-v1" in out,
                      f"package: a package without the record fails\n{out}")
            else:
                check(ok, f"source tree: the record is optional before packaging\n{out}")

    print(f"test-validate-pak: {checks - failures}/{checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
