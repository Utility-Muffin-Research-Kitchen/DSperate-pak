# Provenance

How the shipped DSperate binary is produced, and what it is linked against.
Everything here is measured from the build, not from memory.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/beebono/DSperate.git` |
| Tag | `v3.5.0` |
| Commit | `3a2bcd2cca016b2c38f9a11a5159ab9c3d16b883` |
| Licence | GPL-3.0-or-later (`LICENSE`) |
| Vulkan headers | `https://github.com/KhronosGroup/Vulkan-Headers.git` `v1.4.321` (`2cd90f9d20df57eac214c148f3aed885372ddcfe`), build-time only, Apache-2.0 OR MIT |
| Patches | `patches/0001-pak-cache-and-archive-policy.patch`, `patches/0002-save-durability.patch`, `patches/0003-lid-resume-no-fabricated-close.patch`, `patches/0004-deterministic-version.patch` and `patches/0005-dsperate-ra-account-adapter.patch` (sha256-locked; see below) |

## Patches

The five patches are locked by sha256 in `upstream.lock.json`; the build
applies them in order and refuses a patch whose hash differs.

Reviewed against [upstream v3.5.0](https://github.com/beebono/DSperate/releases/tag/v3.5.0)
on 2026-11-20, by rebasing the five patches from v3.0.5 onto v3.5.0 as commits
(139 upstream commits: v3.0.6, v3.1.0, v3.2.0, v3.3.0, v3.4.0, v3.4.1 and
v3.5.0). 0002, 0003 and 0004 applied without conflicts; 0001 and 0005 needed a
hand resolution in the SDL frontend. None changed what it does, and none became
redundant. One patch grew:

| Patch | Decision |
| --- | --- |
| 0001 archive/cache policy | Keep and rebase. The usage text and the list of keys the command line may set both conflicted with new upstream entries (`--gba-rom`, `--rumble-pak`, `--no-slot2`, `--clear-cache` now also clearing the Vulkan pipeline cache, and `video.colour`, `video.gpu3d_scale`); both sides were kept. The cache-root, single-entry and unsafe-path policies are still absent upstream. |
| 0002 save durability | Keep, rebase and extend. v3.5.0 still writes battery saves and states with an unchecked `fclose`, and the firmware override without a checked flush and close. v3.2.0 added a GBA cartridge in slot 2 whose save is written back like the battery save, through `slot2::write_save`: a temporary, checked write and close, and a rename, but no flush or `fsync`. The frontend's write-back now goes through the same `write_file_durable`. |
| 0003 lid/resume | Keep. Applies unchanged; `src/frontend/sdl/lid.cpp` did not move. v3.4.1's sleep fix (the whole system sleeps until an ARM7 interrupt wakes it) is the DS's own power management, not the host-resume lid pulse this patch stops. |
| 0004 deterministic `--version` | Keep. Applies unchanged; `cmake/version.cmake` did not move. |
| 0005 Leaf account adapter | Keep and rebase. The account page's status strings are translated since v3.4.0; the rebased page keeps upstream's `tr()` strings and appends the pak's `MANAGED BY LEAF` as before (untranslated, like the rest of the pak's own text). v3.4.1 also takes SIGINT and SIGTERM on one thread, set up first thing in `run()`; the adapter still captures and scrubs the account snapshot before that thread exists. v3.4.1's `DS_CHEEVOS_HOST` sends every request, the login included, to another server unchanged; the wrapper does not set it, so DSperate talks to RetroAchievements directly as before. |

The v3.0.5 review (2026-10-26) resolved 0001 and 0003 by hand, and the v3.0.3
review (2026-10-10) re-anchored four of the five patches after upstream
rewrote comments across the whole tree (`46eb3b5`, `95c4a1f`).

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
file is left untouched. It also checks the firmware-override flush and close,
and writes a slot-2 GBA cartridge's save back through the same helper. A failed
battery or GBA save stays dirty, so the next flush retries.

Save loading follows upstream, unchanged since v2.0.0. For a known chip,
upstream loads the portion that fits and saves the original mismatched file as
`.bak`; for an unknown chip, a supported save size selects the chip. This is different from
refusing every short save. The removed guard read into live SRAM before checking
the count, so it did not actually undo partial reads even in the old patch.
The checked-write helper covers DS battery saves, GBA cartridge saves and
save-state files, not upstream's DSi NAND/SD persistence or mismatch-backup
writes. The pak sets no `paths.gba_games`, so no GBA game is offered unless you
set one.

Upstream v3.5.0 writes state format 4 and reads only format 4
(`src/core/state/state.h`: `FORMAT_VERSION` 4, `OLDEST_READABLE_VERSION` 4),
as v3.0.3 and v3.0.5 did, so 3.0.x states load. The chunks grew in ways older
states still read: v3.1.0 saves the 3D geometry engine's busy timing (an older
state loads as idle) and the bytes an analog patch replaced (an optional chunk).
States written by DSperate 2.x are format 3, and 3.x refuses them with a message
instead of loading them. Battery saves are unaffected: the save-chip handling,
the `.bak` logic and the firmware override format are unchanged, and so are the
state file names, so old states stay on the card untouched.

## Toolchain and flags

Built inside the digest-pinned `mlp1-toolchain` image
(`sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9`)
with the cross prefix `aarch64-buildroot-linux-gnu` and the target sysroot at
`/opt/mlp1-toolchain/aarch64-buildroot-linux-gnu/sysroot`.

CMake configuration (see `standalone/build-in-container.sh`):

| Setting | Value | Why |
| --- | --- | --- |
| `CMAKE_SYSTEM_PROCESSOR` | `aarch64` | selects the AArch64 JIT and NEON kernels |
| `CMAKE_BUILD_TYPE` | `RelWithDebInfo` | upstream's default until v3.4.1, which made `Release` the default; kept so that this bump changes the source and not the optimisation level. Debug info is stripped from the artifact |
| `DSPERATE_TESTS` | `OFF` | no test binaries ship |
| `DSPERATE_HEADLESS` | `OFF` | the measurement harness does not ship |
| `DSPERATE_CHEEVOS` | `ON` | upstream default; libcurl is `dlopen`ed at runtime, not linked |
| `DSPERATE_NET` | `ON` | upstream default; vendored ENet and libslirp are linked statically; network sessions default off |
| `CMAKE_CXX_FLAGS` | `-DSDL_VIDEO_DRIVER_WAYLAND=1` | exposes `SDL_SysWMinfo`'s Wayland fields so the dmabuf tier compiles (see below) |
| `DSPERATE_WAYLAND` | `ON` | build the Wayland dmabuf tier; the build fails rather than substituting the stub |
| `DSPERATE_VULKAN` | `ON` | build the Vulkan presenter and the optional GPU 3D raster (see below) |
| `DSPERATE_VULKAN_INCLUDE` | `/vulkan-include` | the pinned Khronos headers; the image has none, and the build fails if the presenter is not enabled |
| `DSPERATE_CHEEVOS_VERSION` | `3.5.0` | passed explicitly; a shallow checkout has no tags for upstream's `git describe` fallback |
| `DSPERATE_PGO` | `use` | consume the pak's own trained aarch64 profile (see below) |
| `DSPERATE_PGO_DIR` | `/standalone/pgo/aarch64` | the locked profile; `build-dsperate.sh` verifies its sha256 before the build |
| `DSPERATE_PGO_STRICT` | `ON` | keeps GCC's missing-profile and coverage-mismatch warnings; the build counts them and fails (see below) |

`SOURCE_DATE_EPOCH` is the pinned commit's committer timestamp
(`1795137615`). `DSPERATE_LOCK_VERSION=v3.5.0` and
`DSPERATE_LOCK_COMMIT=3a2bcd2` are exported from the lock so `--version` is
deterministic.

### Presenters

v3 scales and composes the picture off the CPU into the scanout buffer
(`video.gpu_present`, on by default) with Vulkan: a render pass on the scanout
buffer (vertex and fragment shaders, shipped precompiled in the source tree),
since v3.0.5. v3.5.0 removed the second presenter, the Rockchip RGA through
V4L2 mem2mem, which declined on the MLP1 anyway (the stock kernel exposes the
RGA only as the vendor `/dev/rga`, not as a V4L2 node). `video.gpu_present` is
now on or off, and `rga` or `vulkan` in an older config read as on.

- The Vulkan presenter is what runs on the MLP1. Upstream compiles it, and the
  optional GPU 3D raster, only when it finds `vulkan/vulkan.h`, and otherwise
  builds stubs that decline. The pinned image has no Vulkan headers, so the
  build fetches the Khronos headers pinned in the lock (`vulkan_headers`, the
  same release PPSSPP 1.20.4 vendors) by commit, mounts them at
  `/vulkan-include`, and fails if the presenter is not enabled. Nothing links
  `libvulkan`: the binary loads the device's loader with `dlopen`, and with it
  the stock Mali driver. The log says
  `video: GPU present on Mali-G52 ... (dma-buf import, dmabuf scanout)`.
  Since v3.4.0 bilinear scaling, the seam blends, the chunky cells and colour
  correction (`video.colour`) all work on it.
- GPU 3D (`video.gpu3d`) stays off, upstream's default; the CPU raster remains
  the exact reference. A player can turn it on per game, and since v3.5.0 draw
  the 3D at up to 2x or 4x (`video.gpu3d_scale`). v3.2.0 added an OpenGL ES
  3.1 raster for devices without Vulkan; it is built (`DSPERATE_GLES`,
  upstream's default, `dlopen`ing `libEGL` and `libGLESv2` with no headers), and
  on the MLP1 the Vulkan raster opens first.
- The DSperate TATE core sets `DS_ROTATE=270`. The Vulkan presenter turns the
  picture in the same pass, and so does the CPU scanline path it falls back to.

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
skips the direct-panel tiers and tries the Wayland dmabuf sink. Since v3.5.0
the next step is the SDL renderer, now drawing on its own present thread, and
the window surface only for a turned picture. Up to 3.0.5 it was the window
surface; the renderer came after it and could not take over a window a failed
dmabuf attempt had used, so a launch that reached it exited. Checked on the MLP1 on
2026-11-20 with upstream's `DS_DMABUF_FAIL_AFTER` test switch, through real
Leaf launches of Super Mario 64 DS: with no dmabuf at all DSperate fell back to
the OpenGL ES 2 renderer on the present thread and ran its 900 frames with 3
of 600 over budget; failing after two buffers, it kept the two and stayed on
the Vulkan present; TATE with no dmabuf fell back to the window surface with
the picture turned.

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
GCC 12.3.0) and these same flags, against the patched v3.5.0 source. Upstream
ships profiles for other GCC versions only (13.3, and 10.5 and 12.4 as
secondary profiles); CMake's fingerprint check refuses those, and a `.gcda` is
bound to the compiler that wrote it, so they cannot be used here. A profile is
also bound to its source: every upstream bump needs a new one. The fingerprint
changed from 3.0.5's (`2d22e81d...`) with the same compiler and flags, because
upstream v3.4.1 took the `-g` flags and the build type's name out of it.

`make pgo-train` (`standalone/pgo-train.sh`) produces it:

- `build-dsperate.sh` prepares the pinned commit with the locked patches, the
  same tree the release builds;
- inside the pinned image, `pgo-train-in-container.sh` turns the lock's own
  CMake flags into an instrumented headless build (`-DDSPERATE_PGO=generate`,
  `-DDSPERATE_HEADLESS=ON`), so its `pgo-fingerprint` is the release build's
  (`b752d035a1de1ab72bffc8f867fe1efcaffd59c7` for this revision). The image is
  aarch64, so the binary runs natively on an arm64 Docker host;
- it runs upstream's v3.5.0 scene list with the real BIOS and firmware: five
  recorded replays (`mlbis sm64 etody dbori meteos`), three boots from frame 0
  (`gsdd st nsmb`) and, new since v3.2.0, `ghontour`: Guitar Hero: On Tour
  mid-song from upstream's save state, with the Guitar Grip in slot 2 and the
  game's display capture read back every VBlank. The pak adds one boot of its
  own, `mkds` (Mario Kart DS, 2400 frames, see below). It records in the
  MANIFEST only the scenes that ran. All ten ran for this profile (MANIFEST
  date 2026-11-20T21:42Z), with the same ROMs and BIOS as the 3.0.5 profile.
  `ghontour` needs the exact image upstream recorded the state with, since a
  state refuses another ROM image: the USA dump RetroAchievements lists as
  `Guitar Hero - On Tour (Control)` (SHA-1 `7b5abe0b...`) loads it, and the run
  went from the state's frame 1612 to 2812. Upstream's two DSi scenes need DSi
  dumps and are not trained;
- the `.gcda` files, the `MANIFEST`, and a sha256 over the whole directory are
  written to `standalone/pgo/aarch64` and the lock. The build refuses a profile
  whose directory hash does not match the lock, and CMake refuses one whose
  compiler or flags (the MANIFEST fingerprint) do not match the build.

The ROMs and BIOS stay outside the repository; `DS_ROMS` and `DS_BIOS` name
them.

Verification is part of every build. The release build itself runs with
`-DDSPERATE_PGO_STRICT=ON`, and `build-in-container.sh` counts the warnings the
same way upstream's `tools/pgo_refresh.sh` does: it fails if any object outside
the never-trained groups (the SDL frontend and the code only it uses: the
windowless video library, the menu translations and slot 2's GBA-cart
compatibility table behind the game picker; rcheevos and the achievement code,
the standalone tools, miniz, the reference kernels) has no profile, if any
function's control flow no longer matches its profile, or if no strict warning
appears at all. The translations and the compatibility table are new in v3.4.0
and v3.2.0; upstream's own profile has no data for them either. The current
build reports 57 objects without a profile, all in those groups, and 0
mismatches.
The strict flags are warning switches only; the binary is byte-identical to the non-strict
build. `make test-pgo` checks, without a build or a device, that the profile
directory, its MANIFEST and the build flags match the lock. Two clean
`FORCE=1` builds with the locked profile agree byte for byte.

### Why the pak adds a Mario Kart DS scene

Measured on the MLP1 on 2026-10-27 through real Leaf launches, at the 60 fps
cap over frames 900 to 2400 of Mario Kart DS's boot with no input, the build
trained on upstream's eight scenes alone went over the 16.7 ms frame budget in
bursts: 4 of 11 runs had 244 to 367 of 1,500 frames over, 8.6% in all. Built
with the same flags and no profile, v3.0.3 and v3.0.5 both stayed at 0.8% to
0.9% over in 28 runs, so the profile caused it, not a source change; the
presenter did not either (turning it off was worse). Dropping the profile is no
fix: without it New Super Mario Bros., Golden Sun: Dark Dawn and Spirit Tracks
spend 10% to 13% more time emulating each frame.

With `mkds` trained, alternating with the eight-scene build on the same device
(eight runs each for Mario Kart DS, three for the others): Mario Kart DS 1.0%
over (worst run 46 frames) against 3.6%, New Super Mario Bros. and Golden Sun:
Dark Dawn unchanged at 0.0% and 0.2%, Spirit Tracks 3.4% against 5.9%. Spirit
Tracks varies from run to run on the same build (1.2% to 6.0% across these
sessions). The scene trains on the same attract-mode race that was measured; a
race played with input has not been measured.

The scene stays for 3.5.0. Measured on 2026-11-20 the same way, alternating
with the published 3.0.5 (five runs each): 3.5.0 held Mario Kart DS at 0.3%
over (worst run 7 frames), against 3.0.5's 3.9%, one of whose runs again went
over in a burst (249 frames).

## Archives

`make dist-pakrat` and `make dist-source` write the pak ZIP and the
corresponding-source tarball with `scripts/make-archive.py`, run inside the
same pinned image so the Python and zlib doing the compression are fixed.
Entries are sorted, every timestamp is `SOURCE_DATE_EPOCH`, owner and group are
0 with no names, modes are 0755 or 0644, the ZIP has no extra fields and the
gzip header has no name or timestamp. `make test-archives` builds both twice
with every input's mtime and the umask changed in between and requires the
same sha256. `make test-version` extracts the source archive, rebuilds from it
with no git, and requires the locked binary and `DSperate v3.5.0 (3a2bcd2)`.

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
| sha256 | `e587bbc1d245e0adb18366e914b392827b0bb29f7c62c4ca4513bc06d47f201f` | `c52bf4d447c5c855dd02dfb24d8eef962a5d3d079c15b3e4438ae2a5df34a160` |
| Size | 5,320,520 bytes | 14,224 bytes |
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
qualification on 2026-10-10 (see the README). DSperate 3.0.5 (upstream v3.0.5,
`ddf2910`, binary `11124142...`, 4,693,784 bytes, the same five patches, profile
`c3e810f3...` on nine scenes) was checked on an MLP1 on 2026-10-27 (the Mario
Kart DS measurement above, Pak Rat install and update, TATE on the screen and
on a TV) and published the same day.

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
