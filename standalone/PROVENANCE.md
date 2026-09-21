# Provenance

How the shipped DSperate binary is produced, and what it is linked against.
Everything here is measured from the build, not from memory.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/beebono/DSperate.git` |
| Tag | `v2.1.1` |
| Commit | `baec96501802bb04203cac07b420c67eff8054b8` |
| Licence | GPL-3.0-or-later (`LICENSE`) |
| Patches | `patches/0001-pak-cache-and-archive-policy.patch`, `patches/0002-save-durability.patch`, `patches/0003-lid-resume-no-fabricated-close.patch` and `patches/0004-deterministic-version.patch` (sha256-locked; see below) |

## Patches

The four patches are locked by sha256 in `upstream.lock.json`; the build
applies them in order and refuses a patch whose hash differs.

Reviewed against [upstream v2.1.1](https://github.com/beebono/DSperate/releases/tag/v2.1.1)
on 2026-09-21:

| Patch | Decision |
| --- | --- |
| 0001 archive/cache policy | Keep and rebase. v2.1.1 renamed `find_nds` to `find_rom` and widened the entry kinds to `.nds/.dsi/.srl/.cia`; the cache-root, single-entry and unsafe-path policies are still absent upstream, so they are re-expressed against `find_rom`. |
| 0002 save durability | Keep. Re-anchored onto v2.1.1's larger SDL frontend; checked writes and firmware flush/close are unchanged. |
| 0003 lid/resume | Keep. v2.1.1's lid implementation is unchanged and still fabricates a close on a device with no switch. |
| 0004 deterministic `--version` | New. Prefers the lock's tag and commit over git so a source archive and a patched checkout report the same identity. |

`standalone/patches/0001-pak-cache-and-archive-policy.patch` adds the pak's
archive policy.

It adds three opt-in command-line flags and the two settings behind them:

- `--cache-root-only` (`[cart] cache_root_only`): a configured `paths.cache` is
  the only place a deflated archive may be unpacked, never a `.dsperate`
  directory beside a writable ROM. The pak pins the cache to
  `$USERDATA_PATH/dsperate/cache/<key>/`.
- `--single-rom` (`[cart] single_nds`): refuse an archive that holds more than
  one eligible image entry instead of picking one by game database and
  revision. The pak wants one unambiguous game per archive.
- `--inspect-cart FILE`: print `kind`, `extract`, `bytes` and `entry` for a
  cartridge and exit without booting anything, or exit non-zero with the reason
  on stderr. The wrapper sizes and bounds its cache with this and refuses an
  unreadable archive before a window opens.

The same patch rejects an image entry whose name is absolute or carries a `..`
component. Upstream already refuses encryption, zip64 and unknown compression;
this closes the remaining path-shaped case, and the extraction target was never
derived from the entry name in any case.

`standalone/patches/0004-deterministic-version.patch` makes `--version` report
the lock's release tag and commit. Upstream's generator takes the tag from
`git describe` and the commit from `git rev-parse`, so a corresponding-source
archive without git says `unknown` and a patched checkout says `<hash>-dirty`.
The patch prefers `DSPERATE_LOCK_VERSION` and `DSPERATE_LOCK_COMMIT`, which
`build-in-container.sh` exports from the lock, and leaves ordinary git
development unchanged.

The cache-root and single-ROM policies default off. Unsafe archive entry
names are rejected regardless of those flags.

`standalone/patches/0003-lid-resume-no-fabricated-close.patch` stops the
host-resume lid pulse from fabricating a close on a device with no lid switch
(the MLP1). Upstream pulses the emulated lid whenever the clocks show a suspend
it did not see, which on these devices is every resume. A game that blanks its
screens on lid-close and restores them only on an open it saw coming (Contra 4)
then stays black; emulation, audio and input all keep running. The pulse now
fires only for a lid already believed closed, so with no switch nothing happens
and the screens survive a resume.

`standalone/patches/0002-save-durability.patch` makes battery-save and
save-state writes durable. Upstream writes to `<file>.tmp`, closes it without
checking the result, and renames. A buffered write on a full or read-only card
can report success from `fwrite` and still never reach the disk, so a save
reported as successful might not be there. The patch adds a checked helper
(`write_file_durable`): `fwrite`, `fflush`, `fsync`, `fclose` and `rename` are
all checked, the temporary is removed on failure, and the previous committed
file is left untouched. It also checks the firmware-override flush and close.
A failed battery save stays dirty, so the next flush retries.

Save loading now follows upstream v2.0.0. For a known chip, upstream loads the
portion that fits and saves the original mismatched file as `.bak`; for an
unknown chip, a supported save size selects the chip. This is different from
refusing every short save. The removed guard read into live SRAM before checking
the count, so it did not actually undo partial reads even in the old patch.
The checked-write helper covers DS battery saves and save-state files, not
upstream's new DSi NAND/SD persistence or mismatch-backup writes.

Upstream writes state format 3 and accepts DS format 2 from v1.15.1. This is a
source-reviewed compatibility promise, not a device migration test. Back up your
states before updating: v1.15.1 cannot read states newly written by v2.0.0.

## Toolchain and flags

Built inside the digest-pinned `mlp1-toolchain` image
(`sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9`)
with the cross prefix `aarch64-buildroot-linux-gnu` and the target sysroot at
`/opt/mlp1-toolchain/aarch64-buildroot-linux-gnu/sysroot`.

CMake configuration (see `standalone/build-in-container.sh`):

| Setting | Value | Why |
| --- | --- | --- |
| `CMAKE_SYSTEM_PROCESSOR` | `aarch64` | selects the AArch64 JIT and NEON kernels |
| `CMAKE_BUILD_TYPE` | `RelWithDebInfo` | upstream default; debug info is stripped from the artifact |
| `DSPERATE_TESTS` | `OFF` | no test binaries ship |
| `DSPERATE_HEADLESS` | `OFF` | the measurement harness does not ship |
| `DSPERATE_CHEEVOS` | `ON` | upstream default; libcurl is `dlopen`ed at runtime, not linked |
| `DSPERATE_NET` | `ON` | upstream default; vendored ENet and libslirp are linked statically; network sessions default off |
| `CMAKE_CXX_FLAGS` | `-DSDL_VIDEO_DRIVER_WAYLAND=1` | exposes `SDL_SysWMinfo`'s Wayland fields so the dmabuf tier compiles (see below) |
| `DSPERATE_WAYLAND` | `ON` | build the Wayland dmabuf tier; the build fails rather than substituting the stub |
| `DSPERATE_CHEEVOS_VERSION` | `2.1.1` | passed explicitly; a shallow checkout has no tags for upstream's `git describe` fallback |
| `DSPERATE_PGO` | `off` | this candidate ships unprofiled (see below) |

`SOURCE_DATE_EPOCH` is the pinned commit's committer timestamp
(`1789871851`). `DSPERATE_LOCK_VERSION=v2.1.1` and
`DSPERATE_LOCK_COMMIT=baec965` are exported from the lock so `--version` is
deterministic.

## Profile-guided optimisation

This candidate ships **without PGO**. The v2.0.0 locked profile was trained with
this pak's toolchain (Buildroot GCC 12.3.0) and is bound to the v2.0.0 source:
the `.gcda` format is compiler-version-checked and CMake's fingerprint covers
the compiler, flags and build type, while source changes leave the affected
functions without a profile. Upstream v2.1.1 ships profiles for GCC 10.5
(`pgo/aarch64`) and GCC 12.4.0 only, neither usable by GCC 12.3.0.

Retraining the headless scenes needs games and hardware, which ordinary rebuilds
must not. The GCC 12.3.0 profile is therefore removed for this candidate and the
lock records `build.pgo = off`. The v2.0.0 profile measured (on MLP1
`43990f377d9284c1`, headless, `--quantum 0`) a 4-9% median improvement on its
scenes; a v2.1.1 profile has not been measured. A later candidate can add one
with a GCC 12.3.0 training build without changing this unprofiled artifact.
Device performance of this candidate must be re-measured before any claim.

## Linkage

`readelf -d` on the stripped artifact reports exactly:

```text
libSDL2-2.0.so.0
libstdc++.so.6
libm.so.6
libgcc_s.so.1
libc.so.6
```

Every one is provided by the MLP1 in `/lib`; the pak bundles no shared
libraries. The artefact is AArch64, stripped, carries no RPATH/RUNPATH and its
highest glibc symbol version is `GLIBC_2.38`, the device's glibc.

## Artifacts

| | `bin/dsperate` | `bin/dsperate-notice` |
| --- | --- | --- |
| Source | upstream at the pinned commit, plus the locked patches | `standalone/notice/notice.c` (this repository) |
| Licence | GPL-3.0-or-later | MIT |
| sha256 | `b1b6c3410174287642c9ead95d834f436aea9830024b85c7defe416cd50690ac` | `c52bf4d447c5c855dd02dfb24d8eef962a5d3d079c15b3e4438ae2a5df34a160` |
| Size | 4,693,528 bytes | 14,224 bytes |
| Reproduced | two clean `FORCE=1` builds agreed byte for byte (unprofiled) | `FORCE=1` builds agreed byte for byte |

The notice program is the fullscreen message the wrapper shows when a launch
cannot proceed. It links only SDL2 and SDL_ttf, both provided by the MLP1, and
resolves the launcher's own font at runtime; the pak bundles neither a library
nor a font. It is verified with the same AArch64/stripped/glibc/allowlist checks
as the emulator (see `build/standalone/verify-notice.txt`).

## The Wayland dmabuf tier is built

The MLP1's own `libSDL2-2.0.so.0` (2.28.5) is built with its Wayland video
driver, but the toolchain sysroot's SDL2 2.28.5 is a KMSDRM-only build:
`SDL_config.h` leaves `SDL_VIDEO_DRIVER_WAYLAND` undefined, so `SDL_syswm.h`
hides `SDL_SysWMinfo`'s Wayland fields and DSperate's dmabuf tier cannot
compile against those headers.

The build defines `SDL_VIDEO_DRIVER_WAYLAND=1` for this pak only. That exposes
the header fields; it does not, and cannot, add a Wayland driver to a runtime
SDL that lacks one. The fields live in SDL's public `SDL_SysWMinfo` union,
whose reserved space is the same whether or not the macro is set, and the
binary is dynamically linked to the device's Wayland-capable SDL. The dmabuf
tier loads `libwayland-client.so.0` with `dlopen` at runtime, so `libwayland`
is not a link-time dependency.

Independent ABI check (2026-09-16), compiled for AArch64 with the pinned SDK:
`sizeof(SDL_SysWMinfo) = 72`, `offsetof(info) = 8`, Wayland member size 64,
`offsetof(info.wl.surface) = 16`, and `offsetof(info.wl.xdg_toplevel) = 48`.
The public structure size and union offset agree with and without the define.
A separate full build with the define reproduced the then-pinned v1.15.1 artifact hash.
This check applies to these pinned SDL 2.28.5 headers and the qualified device
SDL; changing the SDK or runtime SDL requires checking the ABI again.

Evidence in the pinned artifact: `strings` shows `zwp_linux_dmabuf_v1`,
`zwp_linux_dmabuf_feedback_v1`, `/dev/dma_heap` and `libwayland-client.so.0`,
and the `NEEDED` set is unchanged from the window-surface-only build. The build
also fails if CMake's Wayland probe or the compilation of `display_wl.cpp`
does not confirm the real tier, so a silently stubbed build cannot ship.

The dmabuf allocation, Weston import, orientation and performance are qualified
on the device separately; the SDL window-surface route remains the fallback.

## v2.0.0 verification (historical)

The v2.0.0 release checks below are retained as history. The v2.1.1 candidate in
this revision is host-verified only: the patched source builds unprofiled to
`b1b6c341…`, two clean `FORCE=1` builds agree, `--version` reports
`v2.1.1 (baec965)` from the lock, and `make check`, `make dist-pakrat` and
`make dist-source` pass (82 wrapper checks, 14 MLP1 profile checks, packaged-tree
validation). Device requalification of v2.1.1, including the performance the
unprofiled build must re-measure, is pending.

Two clean `FORCE=1` builds agreed on both artifact hashes. The SDK, flags and
runtime library allowlist are unchanged. The larger emulator contains the new
DSi core, generated system fonts and vendored networking code. The package
carries FreeBIOS, miniz, rcheevos, ENet, libslirp and both font notices in
`LICENSE-THIRD-PARTY.txt`, copied from the exact pinned source; the complete
corresponding source retains all file-level notices.

Checks passed on 2026-09-17:

- 82 wrapper checks and 14 MLP1 profile checks.
- Seven real-executable archive CLI checks (raw, stored, deflated, ambiguous,
  opt-in selection, unsafe path and malformed ZIP).
- Eight upstream AArch64 tests in the pinned container: `scheduler`,
  `cart_save`, `fastmem`, `spu`, `config`, `input`, `firmware` and `zip`.
- AArch64, stripping, GLIBC ceiling, library allowlist and real Wayland backend.

Run the archive check against a Linux executable with
`python3 tests/test-archive-cli.py /path/to/dsperate`. In the pinned AArch64
container, prefix the executable with the SDK's `lib/ld-linux-aarch64.so.1`
and `--library-path` naming its `lib` and `usr/lib` directories.

The patched v2.0.0 build passed MLP1 launch, controls, save faults, sleep and
sustained pacing checks on 2026-09-17. The locked PGO build was subsequently
installed on the same device; both core pickers, selection persistence after a
device reboot, the visible `.7z` refusal and stick-driven stylus input were
verified there. Local Pak Rat install/reinstall/uninstall passed and preserved
all 35 tested settings, save and state files byte for byte.
DSiWare, NAND/SD persistence and networking are not
qualified Leaf features in this update. The pak version is `2.0.0`.
