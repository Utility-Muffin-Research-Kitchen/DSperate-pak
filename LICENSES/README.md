# Licensing

The components in this repository are not under one licence. Read this before
redistributing the built pak.

| What | Licence | Where |
| --- | --- | --- |
| The DSperate binary (`bin/dsperate`) | **GPL-3.0-or-later** | `DSPERATE-LICENSE.txt`; in the package also `LICENSE-DSPERATE.txt` |
| Third-party code inside DSperate (miniz, rcheevos) | See their notices in the DSperate source | The corresponding-source archive |
| This repository's build system, manifest, wrapper, scripts | MIT | `REPO-LICENSE.txt` |

DSperate is a clean-room emulator; its own `LICENSE` and `src/core/bios/LICENSE.freebios`
are reproduced by the source this repository builds. The binary links the
device's own shared libraries (SDL2, the C and C++ runtimes) and bundles none of
them. `make dist-source` produces the corresponding source for the exact binary
this pak distributes.

No bundled games, BIOS or firmware dumps are part of this repository or the pak.

## The GPL obligation, concretely

The DSperate binary is GPLv3. Distributing it, which is what installing this pak
does, obliges you to offer the **corresponding source** for that exact binary.

This repository discharges that by construction rather than by promise:

- `standalone/upstream.lock.json` pins the exact upstream DSperate commit and
  the exact build flags.
- `standalone/build-dsperate.sh` rebuilds that source with a digest-pinned
  toolchain image and refuses to package an artifact whose sha256 does not
  match its lock.
- `make dist-source` produces an archive to publish **alongside** the pak: the
  DSperate tree at the pinned commit plus the lock.

If you fork this repository and change a pin, republish the source for your pin:
the obligation follows the binary you distributed, not the one upstream
currently builds.

Leaf's separate constraints on which emulators may ship in a release image are a
different question and do not discharge this one.
