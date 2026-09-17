# Provenance

How the shipped DSperate binary is produced, and what it is linked against.
Everything here is measured from the build, not from memory.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/beebono/DSperate.git` |
| Tag | `v2.0.0` |
| Commit | `86bef065f93c55fc59c5ab5e93e06c812fcd7bf7` |
| Licence | GPL-3.0-or-later (`LICENSE`) |
| Patches | `patches/0001-pak-cache-and-archive-policy.patch`, `patches/0002-save-durability.patch` and `patches/0003-lid-resume-no-fabricated-close.patch` (sha256-locked; see below) |

## Patches

The three patches are locked by sha256 in `upstream.lock.json`; the build
applies them in order and refuses a patch whose hash differs.

Reviewed against [upstream v2.0.0](https://github.com/beebono/DSperate/releases/tag/v2.0.0)
on 2026-09-17:

| Patch | Decision |
| --- | --- |
| 0001 archive/cache policy | Keep. Upstream's ZIP parser and cache selection are unchanged. Rebase frontend context around the expanded CLI; retain every new upstream CLI setting. |
| 0002 save durability | Keep checked writes and firmware flush/close. Drop the old fixed-size loading check: upstream now detects unlisted save chips, understands DeSmuME footers and backs up size mismatches. |
| 0003 lid/resume | Keep byte for byte. Upstream's lid implementation is unchanged and still fabricates a close on a device with no switch. |

`standalone/patches/0001-pak-cache-and-archive-policy.patch` adds the pak's
archive policy.

It adds three opt-in command-line flags and the two settings behind them:

- `--cache-root-only` (`[cart] cache_root_only`): a configured `paths.cache` is
  the only place a deflated archive may be unpacked, never a `.dsperate`
  directory beside a writable ROM. The pak pins the cache to
  `$USERDATA_PATH/dsperate/cache/<key>/`.
- `--single-rom` (`[cart] single_nds`): refuse an archive that holds more than
  one eligible `.nds` entry instead of picking one by game database and
  revision. The pak wants one unambiguous game per archive.
- `--inspect-cart FILE`: print `kind`, `extract`, `bytes` and `entry` for a
  cartridge and exit without booting anything, or exit non-zero with the reason
  on stderr. The wrapper sizes and bounds its cache with this and refuses an
  unreadable archive before a window opens.

The same patch rejects an `.nds` entry whose name is absolute or carries a `..`
component. Upstream already refuses encryption, zip64 and unknown compression;
this closes the remaining path-shaped case, and the extraction target was never
derived from the entry name in any case.

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
| `DSPERATE_CHEEVOS_VERSION` | `2.0.0` | passed explicitly; a shallow checkout has no tags for upstream's `git describe` fallback |
| `DSPERATE_PGO` | `use` | consume the pak's own trained aarch64 profile (see below) |
| `DSPERATE_PGO_DIR` | `/standalone/pgo/aarch64` | the locked profile; `build-dsperate.sh` verifies its sha256 before the build |

`SOURCE_DATE_EPOCH` is the pinned commit's committer timestamp
(`1789612242`).

## Profile-guided optimisation

The build consumes a PGO profile trained with **this same toolchain** (Buildroot
GCC 12.3.0) and these same flags. Upstream ships an aarch64 profile too, but it
was made with a GCC 13.3.0 `aarch64-linux-gnu` compiler and is refused by
CMake's fingerprint check, and a `.gcda` is bound to the compiler that wrote it,
so it cannot be used here.

How the profile was produced (see `standalone/pgo/aarch64/MANIFEST`):

- an instrumented headless build (`-DDSPERATE_PGO=generate`) configured with the
  release flags, whose `pgo-fingerprint` matched the release build's
  (`e5053f2d1f5b27e9ed70bda94b614845979aa599`);
- seven of upstream's recorded scenes run on an MLP1 (`mlbis sm64 etody dbori
  meteos gsdd nsmb`), with the real BIOS and firmware. `st` is absent because
  the recorded save state is for another ROM revision, which the loader
  refuses;
- the resulting `.gcda` files, the `MANIFEST`, and a sha256 over the whole
  directory, pinned in `upstream.lock.json`. The build refuses a profile whose
  directory hash does not match the lock, and CMake refuses one whose compiler
  or flags (the MANIFEST fingerprint) do not match the build.

Verification: a `-DDSPERATE_PGO_STRICT=ON` build reports 0 unexpected objects
without a profile and 0 coverage mismatches. The only objects without a profile
are the groups a headless run never executes (the SDL frontend, rcheevos, the
reference kernels, miniz), which is expected.

Measured on MLP1 `43990f377d9284c1` with the headless frontend and
`--quantum 0`, same scenes and dumps, non-PGO vs PGO:

| scene | frames | median ms | p99 ms | total ms |
| --- | --- | --- | --- | --- |
| `mlbis` | 1800 | 10.78 -> 10.23 (-5.1%) | 16.44 -> 15.69 | 16484 -> 15683 (-4.9%) |
| `gsdd` | 800 | 18.73 -> 17.96 (-4.1%) | 32.25 -> 31.32 | 15140 -> 14440 (-4.6%) |
| `nsmb` | 1500 | 11.90 -> 10.82 (-9.1%) | 21.58 -> 20.31 | 15819 -> 14604 (-7.7%) |
| `sm64` | 1800 | 4.55 -> 4.25 (-6.6%) | 11.24 -> 10.89 | 8545 -> 7953 (-6.9%) |

Two clean `FORCE=1` builds with the locked profile agree byte for byte.

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
| sha256 | `a63ee1db30cf37de0b802217bedbd1cdd664855af350242d7235d0a347651646` | `c52bf4d447c5c855dd02dfb24d8eef962a5d3d079c15b3e4438ae2a5df34a160` |
| Size | 4,378,136 bytes | 14,224 bytes |
| Reproduced | clean `FORCE=1` builds agreed byte for byte | clean `FORCE=1` builds agreed byte for byte |

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

## v2.0.0 verification

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
