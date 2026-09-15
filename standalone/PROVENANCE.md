# Provenance

How the shipped DSperate binary is produced, and what it is linked against.
Everything here is measured from the build, not from memory.

## Source

| | |
| --- | --- |
| Upstream | `https://github.com/beebono/DSperate.git` |
| Tag | `v1.15.1` |
| Commit | `4076a9ec0be9f649eb79fcd9e554d2cb48316d70` |
| Licence | GPL-3.0-or-later (`LICENSE`) |
| Patches | none; the tree builds unmodified |

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
| `DSPERATE_WAYLAND` | `ON` | request the Wayland dmabuf tier (see below) |
| `DSPERATE_CHEEVOS_VERSION` | `1.15.1` | passed explicitly; a shallow checkout has no tags for upstream's `git describe` fallback |

`SOURCE_DATE_EPOCH` is the pinned commit's committer timestamp
(`1789088321`). PGO is off (upstream default), so no training data is needed.

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

## Artifact

| | |
| --- | --- |
| File | `build/standalone/dsperate` |
| sha256 | `bfdde65e4d00cb566ce1f12757816aa778450184bd62f8bf52d1bd029fe9a936` |
| Size | 1,779,872 bytes |
| Reproduced | two clean `FORCE=1` builds agreed byte for byte (2026-09-15) |

## The Wayland dmabuf tier is not built

The MLP1's own `libSDL2-2.0.so.0` (2.28.5) is built with its Wayland video
driver, but the toolchain sysroot's SDL2 2.28.5 is a KMSDRM-only build:
`SDL_config.h` leaves `SDL_VIDEO_DRIVER_WAYLAND` undefined. DSperate's CMake
check for `SDL_SysWMinfo`'s Wayland member therefore fails, and the dmabuf
scanout tier is compiled out (the configure log says so). The SDL renderer path
is still built, and under `SDL_VIDEODRIVER=wayland` it runs as an ordinary
fullscreen Wayland window that Weston transforms.

Building the dmabuf tier needs an SDL2 with Wayland in the toolchain sysroot
(`BR2_PACKAGE_SDL2_WAYLAND=y` in `mlp1-toolchain`'s Buildroot defconfig). That
is a toolchain change, tracked separately, not a change to this pak.
