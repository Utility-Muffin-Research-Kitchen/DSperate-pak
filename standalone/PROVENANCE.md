# Provenance

How the shipped DSperate binary is produced, and what it is linked against.
Everything here is measured from the build, not from memory.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/beebono/DSperate.git` |
| Tag | `v3.0.5` |
| Commit | `ddf2910e6d80220c6b22b4df61f0786ac9879cda` |
| Licence | GPL-3.0-or-later (`LICENSE`) |
| Vulkan headers | `https://github.com/KhronosGroup/Vulkan-Headers.git` `v1.4.321` (`2cd90f9d20df57eac214c148f3aed885372ddcfe`), build-time only, Apache-2.0 OR MIT |
| Patches | `patches/0001-pak-cache-and-archive-policy.patch`, `patches/0002-save-durability.patch`, `patches/0003-lid-resume-no-fabricated-close.patch`, `patches/0004-deterministic-version.patch` and `patches/0005-dsperate-ra-account-adapter.patch` (sha256-locked; see below) |

## Patches

The five patches are locked by sha256 in `upstream.lock.json`; the build
applies them in order and refuses a patch whose hash differs.

Reviewed against [upstream v3.0.5](https://github.com/beebono/DSperate/releases/tag/v3.0.5)
on 2026-10-26, by rebasing the five patches from v3.0.3 onto v3.0.5 as commits.
0002, 0004 and 0005 merged without conflicts; 0001 and 0003 needed a hand
resolution. None changed what it does, and none became redundant:

| Patch | Decision |
| --- | --- |
| 0001 archive/cache policy | Keep and rebase. Only the frontend's include list conflicted (upstream added `<optional>`). v3.0.5's new `--saves`/`--states` flags and start-failure screen do not overlap the cache-root, single-entry and unsafe-path policies, which are still absent upstream. A refused archive sets the loader's error like any other failure, so v3.0.5's start-failure screen reports it; the wrapper refuses such archives with its own notice before launch in any case. |
| 0002 save durability | Keep and rebase. v3.0.5 still writes battery saves and states with an unchecked `fclose`, and the firmware override without a checked flush and close. |
| 0003 lid/resume | Keep and rebase. v3.0.4 rewrote `Lid::poll` so the guest sees every close for at least 60 emulated frames. The switchless resume pulse is now one frame, held for those 60, and it still fires on every resume of a device with no switch. The rebased patch keeps upstream's one-frame pulse and the hold, and adds the same `closed_` condition. |
| 0004 deterministic `--version` | Keep. Applies unchanged; `cmake/version.cmake` did not move. |
| 0005 Leaf account adapter | Keep and rebase. The frontend hooks moved with v3.0.5's new start-up code and merged cleanly; the adapter's own three files apply unchanged. |

The v3.0.3 review (2026-10-10) re-anchored four of the five patches by hand
after upstream rewrote comments across the whole tree (`46eb3b5`, `95c4a1f`).

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

`standalone/patches/0005-dsperate-ra-account-adapter.patch` makes DSperate use
the RetroAchievements account saved in Leaf. It adds three files under
`src/cheevos/` and small hooks in the achievement client and the SDL frontend:

- `ra_account_contract.cpp` and `ra_account.h`: the contract classifier, the
  revision marker (`.umrk-ra-account`) and the transition table, the same logic
  as the Flycast consumer and the leaf-contracts reference.
  `make test-ra-account` replays the pinned leaf-contracts fixtures through
  this classifier.
- `ra_account_bridge.cpp`: captures `UMRK_RA_ACCOUNT_*` (and a leaked
  `JAWAKA_CHEEVOS_*` pair) into private memory and unsets them as the first
  thing the frontend does. It picks the transition, writes the marker as
  pending before a login, and hands the password to the native rcheevos login
  once. A verified token goes through the adapter's own checked writer: a
  0600 temporary in the same directory, then write, `fsync`, close and rename,
  each checked. Only after that does the marker become accepted. Any failure
  leaves the previous files in place and keeps the revision pending.
- An explicit `cheevos.enabled = false` (global or per-game INI) or
  `--no-cheevos` is decided before the handoff is consumed and wins over the
  managed account. The handoff is still captured and scrubbed, but nothing
  signs in and neither the marker nor the token is touched.
- Bridge failures are queued as notices that the achievement client drains
  into its own pop-up queue, the path upstream's sign-in failure uses. The
  frontend shows them even with `cheevos.toasts` off.
- Unmanaged launches keep upstream behavior: a menu sign-in lasts for the
  session and is not written anywhere. Upstream reads
  `<Config::dir()>/cheevos.token` but never writes one, and the Leaf wrapper
  gives every game its own `XDG_CONFIG_HOME`, so persisting there would
  scatter tokens across per-game directories.
- The account page says `MANAGED BY LEAF`, offers no manual sign-in for a
  managed account, and keeps its sign-out session-only.

The wrapper passes the managed directory as `--managed-account-dir`
(`$USERDATA_PATH/dsperate/retroachievements`). It copies and unsets the
snapshot before any helper runs and restores it only for the emulator's
`exec`. It passes a leaked RetroArch pair on by presence only, never by value.

The cache-root and single-ROM policies default off. Unsafe archive entry
names are rejected regardless of those flags.

`standalone/patches/0003-lid-resume-no-fabricated-close.patch` stops the
host-resume lid pulse from fabricating a close on a device with no lid switch
(the MLP1). Upstream pulses the emulated lid whenever the clocks show a suspend
it did not see, which on these devices is every resume. A game that blanks its
screens on lid-close and restores them only on an open it saw coming (Contra 4)
then stays black; emulation, audio and input all keep running. The pulse now
fires only for a lid already believed closed, so with no switch nothing happens
and the screens survive a resume. Since v3.0.4 upstream also resyncs the DS
clock from the host clock when the lid opens. With no close there is no open
either, so on the MLP1 the DS clock still runs behind by the length of a
suspend, as it did in 3.0.3.

`standalone/patches/0002-save-durability.patch` makes battery-save and
save-state writes durable. Upstream writes to `<file>.tmp`, closes it without
checking the result, and renames. A buffered write on a full or read-only card
can report success from `fwrite` and still never reach the disk, so a save
reported as successful might not be there. The patch adds a checked helper
(`write_file_durable`): `fwrite`, `fflush`, `fsync`, `fclose` and `rename` are
all checked, the temporary is removed on failure, and the previous committed
file is left untouched. It also checks the firmware-override flush and close.
A failed battery save stays dirty, so the next flush retries.

Save loading follows upstream, unchanged since v2.0.0. For a known chip,
upstream loads the portion that fits and saves the original mismatched file as
`.bak`; for an unknown chip, a supported save size selects the chip. This is different from
refusing every short save. The removed guard read into live SRAM before checking
the count, so it did not actually undo partial reads even in the old patch.
The checked-write helper covers DS battery saves and save-state files, not
upstream's new DSi NAND/SD persistence or mismatch-backup writes.

Upstream v3.0.5 writes state format 4 and reads only format 4
(`src/core/state/state.h`: `FORMAT_VERSION` 4, `OLDEST_READABLE_VERSION` 4),
as v3.0.3 did; `src/core/state/` is unchanged between the two. v3.0.5 gives
the GPU raster's vertices a sub-pixel position, but does not save it: a loaded
frame's vertices draw on whole pixels. States written by DSperate 2.x are
format 3, and 3.x refuses them with a message instead of loading them. Battery saves are unaffected: the save-chip
handling, the `.bak` logic and the firmware override format are unchanged, and
so are the state file names, so old states stay on the card untouched.

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
| `DSPERATE_VULKAN` | `ON` | build the Vulkan presenter and the optional GPU 3D raster (see below) |
| `DSPERATE_VULKAN_INCLUDE` | `/vulkan-include` | the pinned Khronos headers; the image has none, and the build fails if the presenter is not enabled |
| `DSPERATE_CHEEVOS_VERSION` | `3.0.5` | passed explicitly; a shallow checkout has no tags for upstream's `git describe` fallback |
| `DSPERATE_PGO` | `use` | consume the pak's own trained aarch64 profile (see below) |
| `DSPERATE_PGO_DIR` | `/standalone/pgo/aarch64` | the locked profile; `build-dsperate.sh` verifies its sha256 before the build |
| `DSPERATE_PGO_STRICT` | `ON` | keeps GCC's missing-profile and coverage-mismatch warnings; the build counts them and fails (see below) |

`SOURCE_DATE_EPOCH` is the pinned commit's committer timestamp
(`1792600541`). `DSPERATE_LOCK_VERSION=v3.0.5` and
`DSPERATE_LOCK_COMMIT=ddf2910` are exported from the lock so `--version` is
deterministic.

### Presenters

v3 adds two ways to scale and compose the picture off the CPU into the scanout
buffer (`video.gpu_present`, on by default): Vulkan, and the Rockchip RGA
through V4L2 mem2mem. Since v3.0.5 Vulkan is tried first, and it draws with a
render pass on the scanout buffer (vertex and fragment shaders, shipped
precompiled in the source tree) instead of v3.0.3's compute pass.

- The RGA presenter is compiled (the sysroot's `linux/videodev2.h` has
  multi-planar mem2mem), but it declines on the MLP1: the stock kernel exposes
  the RGA only as the vendor `/dev/rga`, not as a V4L2 node.
- The Vulkan presenter is what runs on the MLP1. Upstream compiles it, and the
  optional GPU 3D raster, only when it finds `vulkan/vulkan.h`, and otherwise
  builds stubs that decline. The pinned image has no Vulkan headers, so the
  build fetches the Khronos headers pinned in the lock (`vulkan_headers`, the
  same release PPSSPP 1.20.4 vendors) by commit, mounts them at
  `/vulkan-include`, and fails if the presenter is not enabled. Nothing links
  `libvulkan`: the binary loads the device's loader with `dlopen`, and with it
  the stock Mali driver. The log says
  `video: GPU present on Mali-G52 ... (dma-buf import, dmabuf scanout)`.
- GPU 3D (`video.gpu3d`) stays off, upstream's default; the CPU raster remains
  the exact reference. A player can turn it on per game.
- The DSperate TATE core sets `DS_ROTATE=270`. The Vulkan presenter turns the
  picture in the same pass, and so does the CPU scanline path it falls back to.
  The RGA presenter declines a turned picture.

The presenter decides one game in the qualification set. Measured with 3.0.3's
compute-pass presenter on the MLP1 at the normal 60 fps cap through real Leaf
launches (frames 900 to 2400 of a boot with no input, two passes): Golden Sun:
Dark Dawn holds 100% speed with
5 of 3,000 frames over the 16.7 ms budget, against 91.8% speed and 958 frames
over with the presenter off. New Super Mario Bros., Spirit Tracks and Mario
Kart DS hold full speed either way. Leaf's g29p1 Mali driver, which PPSSPP
uses, measured the same as the stock driver for the presenter, so the pak
does not load it.

The wrapper names no video sink. With `SDL_VIDEODRIVER=wayland`, DSperate
skips the direct-panel tiers and tries the Wayland dmabuf sink, then the window
surface, then the renderer, as 2.1.1 did with `--no-disp --no-fbdev`. Naming
`dmabuf` outright would drop the window-surface step: if the dmabuf allocation
failed, the renderer could not take over the window and the launch would exit.

The wrapper does pin the dmabuf heap, with `DS_DMA_HEAP=system-uncached`. v3's
dmabuf sink allocates four panel-sized buffers (five under GPU present) and
prefers the CMA heap. The MLP1's CMA pool is 16 MB and page cache usually fills
it, so in real Leaf launches the allocation failed
(`/dev/dma_heap/cma-uncached: alloc: Cannot allocate memory`) and the picture
fell back to the window surface, which cost about 2 ms per frame to present.
Weston accepts buffers from the non-contiguous heap, and with it the present
step takes about 0.1 ms. Since v3.0.5 a pinned heap that runs out of memory
falls back to the next heap that imports, so the pin no longer turns an
exhausted heap into a failed allocation; it still skips the CMA attempt.

## Profile-guided optimisation

The build consumes a PGO profile trained with **this same toolchain** (Buildroot
GCC 12.3.0) and these same flags, against the patched v3.0.5 source. Upstream
ships profiles for other GCC versions only; CMake's fingerprint check refuses
those, and a `.gcda` is bound to the compiler that wrote it, so they cannot be
used here. A profile is also bound to its source: every upstream bump needs a
new one. The fingerprint itself is unchanged from 3.0.3, because the compiler
and flags are.

`make pgo-train` (`standalone/pgo-train.sh`) produces it:

- `build-dsperate.sh` prepares the pinned commit with the locked patches, the
  same tree the release builds;
- inside the pinned image, `pgo-train-in-container.sh` turns the lock's own
  CMake flags into an instrumented headless build (`-DDSPERATE_PGO=generate`,
  `-DDSPERATE_HEADLESS=ON`), so its `pgo-fingerprint` is the release build's
  (`2d22e81dd634b4f0237a38ab089fbe6ee63d0368` for this revision). The image is
  aarch64, so the binary runs natively on an arm64 Docker host;
- it runs upstream's v3.0.5 scene list (unchanged from v3.0.3) with the real
  BIOS and firmware: five recorded replays (`mlbis sm64 etody dbori meteos`)
  and three boots from frame 0 (`gsdd st nsmb`), and records in the MANIFEST
  only the scenes that ran. All eight ran for this profile (MANIFEST date
  2026-10-26T21:13Z), with the same ROMs and BIOS as the 3.0.3 profile.
  Upstream's two DSi scenes need DSi dumps and are not trained;
- the `.gcda` files, the `MANIFEST`, and a sha256 over the whole directory are
  written to `standalone/pgo/aarch64` and the lock. The build refuses a profile
  whose directory hash does not match the lock, and CMake refuses one whose
  compiler or flags (the MANIFEST fingerprint) do not match the build.

The ROMs and BIOS stay outside the repository; `DS_ROMS` and `DS_BIOS` name
them.

Verification is part of every build. The release build itself runs with
`-DDSPERATE_PGO_STRICT=ON`, and `build-in-container.sh` counts the warnings the
same way upstream's `tools/pgo_refresh.sh` does: it fails if any object outside
the never-trained groups (the SDL frontend and the windowless video library
only it links, rcheevos and the achievement code, the standalone tools, miniz,
the reference kernels) has no profile, if any function's control flow no longer
matches its profile, or if no strict warning appears at all. The current build
reports 55 objects without a profile, all in those groups, and 0 mismatches.
The strict flags are warning switches only; the binary is byte-identical to the non-strict
build. `make test-pgo` checks, without a build or a device, that the profile
directory, its MANIFEST and the build flags match the lock. Two clean
`FORCE=1` builds with the locked profile agree byte for byte.
Device performance of this candidate must be re-measured before any claim.

## Archives

`make dist-pakrat` and `make dist-source` write the pak ZIP and the
corresponding-source tarball with `scripts/make-archive.py`, run inside the
same pinned image so the Python and zlib doing the compression are fixed.
Entries are sorted, every timestamp is `SOURCE_DATE_EPOCH`, owner and group are
0 with no names, modes are 0755 or 0644, the ZIP has no extra fields and the
gzip header has no name or timestamp. `make test-archives` builds both twice
with every input's mtime and the umask changed in between and requires the
same sha256. `make test-version` extracts the source archive, rebuilds from it
with no git, and requires the locked binary and `DSperate v3.0.5 (ddf2910)`.

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
| sha256 | `86bf025da6ed951b7e8b29326f62bb0f341c7e2700fb060444f3305d5d459a1d` | `c52bf4d447c5c855dd02dfb24d8eef962a5d3d079c15b3e4438ae2a5df34a160` |
| Size | 4,693,784 bytes | 14,224 bytes |
| Reproduced | two clean `FORCE=1` PGO builds agreed byte for byte | `FORCE=1` builds agreed byte for byte |

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

## Earlier releases (historical)

DSperate 3.0.3 (upstream v3.0.3, `f5fa35e`, binary `62a5f6c7...`, 4,677,384
bytes, the same five patches) was published on 2026-10-13 after MLP1
qualification on 2026-10-10 (see the README). The v3.0.5 candidate in this
revision has not been on a device yet.

DSperate 2.1.1 (upstream v2.1.1, `baec965`, the same five patches) was
published on 2026-09-26 after MLP1 qualification from 2026-09-24 to
2026-09-26. Not re-run for 3.0.3, because the code behind them is unchanged
and the host tests replay them: the DraStic fallback while uninstalled, the
account fault rows and the `.7z` refusal. The v2.0.0 release checks below are
retained as history.

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
qualified Leaf features in that update. The pak version was `2.0.0`.
