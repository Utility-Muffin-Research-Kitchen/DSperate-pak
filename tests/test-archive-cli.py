#!/usr/bin/env python3
"""Exercise the patched executable, without games or a display.

Usage: python3 tests/test-archive-cli.py [loader and options ...] /path/to/dsperate
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    with tempfile.TemporaryDirectory(prefix="dsperate-archive-") as directory:
        root = Path(directory)
        config = root / "config.ini"
        config.write_text("")
        env = dict(os.environ, XDG_CONFIG_HOME=str(root / "xdg"))
        rom = bytes(1024)
        plain = root / "game.nds"
        plain.write_bytes(rom)

        def inspect(path, single=True):
            return subprocess.run(
                sys.argv[1:] + ["--config", str(config), "--cache-root-only"]
                + (["--single-rom"] if single else [])
                + ["--inspect-cart", str(path)],
                env=env, capture_output=True, text=True, timeout=15,
            )

        result = inspect(plain)
        assert result.returncode == 0, result.stderr
        assert result.stdout == "kind=nds\nextract=no\nbytes=1024\n"
        for method, extract in ((zipfile.ZIP_STORED, "no"), (zipfile.ZIP_DEFLATED, "yes")):
            archive = root / f"single-{method}.zip"
            with zipfile.ZipFile(archive, "w", compression=method) as z:
                z.writestr("folder/game.nds", rom)
            result = inspect(archive)
            assert result.returncode == 0, result.stderr
            assert result.stdout == f"kind=zip\nextract={extract}\nbytes=1024\nentry=folder/game.nds\n"

        multi = root / "multi.zip"
        with zipfile.ZipFile(multi, "w") as z:
            z.writestr("one.nds", rom)
            z.writestr("two.nds", rom)
        result = inspect(multi)
        assert result.returncode != 0 and "more than one .nds" in result.stderr
        assert inspect(multi, single=False).returncode == 0  # policy stays opt-in

        unsafe = root / "unsafe.zip"
        with zipfile.ZipFile(unsafe, "w") as z:
            z.writestr("../escape.nds", rom)
        result = inspect(unsafe)
        assert result.returncode != 0 and "unsafe path" in result.stderr

        broken = root / "broken.zip"
        broken.write_bytes(b"PK\x03\x04" + bytes(64))
        assert inspect(broken).returncode != 0
        assert not (root / ".dsperate").exists()  # inspection never extracts
    print("test-archive-cli: 7 checks passed")


if __name__ == "__main__":
    main()
