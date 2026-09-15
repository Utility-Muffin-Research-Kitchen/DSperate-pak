# DSperate-pak

An optional standalone Nintendo DS emulator for Leaf on the Miniloong Pocket 1
(MLP1), installable through Pak Rat.

DSperate is added as an alternate core for the existing Nintendo DS system, so
there is no new tile and no app to open. Install this pak and DSperate appears
in the Nintendo DS core picker, where you choose it per system or per game.
DraStic stays the default, and existing DraStic choices keep working. DSperate
keeps its own battery saves and save states, separate from DraStic's.

This repository is a pure content pak. It declares a `type: "path"` core,
carries the compiled DSperate binary and a launch wrapper, and builds from a
clean clone with no sibling checkout.

## Status

Early. The build lane and wrapper exist; device qualification is outstanding.
The settings, controls and limits below are the intended behavior and may move
as the plan's spike and qualification steps complete. See
`../umrk-workspace/plans/dsperate-standalone-content-pak.md` for the plan.

## Build

You need Docker, make, git and python3. Everything else is pinned.

```sh
make standalone     # build the pinned DSperate binary (long; cached)
make test-wrapper   # check the launch wrapper without building
make validate       # check pak.json against the content-pak contract
make check          # validate, test the wrapper, package, validate the package
make dist-pakrat    # build/dist/DSperate.mlp1.pak.zip
make dist-source    # GPL corresponding source for the shipped binary
```

`make standalone` builds inside the digest-pinned `mlp1-toolchain` image and
refuses an artifact whose sha256 does not match `standalone/upstream.lock.json`.

## Install

Install the pak on the primary card at `Apps/mlp1/DSperate.pak`. It is an
ordinary content pak: the launcher compiles it into the catalog and offers
DSperate in the Nintendo DS core picker.

## Where your data lives

| Data | Location |
| --- | --- |
| Configuration | `$USERDATA_PATH/dsperate/dsperate.ini`, on the primary card |
| Per-game settings | `$USERDATA_PATH/dsperate/games/<game key>/` |
| Battery saves | `$SAVES_PATH/DSperate/`, for the selected card |
| Save states and screenshots | `$STATES_PATH/DSperate/`, for the selected card |
| ROM unpack cache | `$USERDATA_PATH/dsperate/cache/` |
| Log | `$LOGS_PATH/dsperate.log` |

The game key comes from the ROM's path relative to the selected card's
`Roms/NDS`, so two same-named ROMs in different folders do not share progress.
Renaming or moving a ROM starts a new identity; it does not silently merge
progress.

DSperate's saves are raw SRAM in its own format. They are not DraStic or Fun
DraStic saves, and switching emulators switches saves.

## BIOS and firmware

DSperate boots games with a built-in FreeBIOS and a generated firmware, so no
dumps are required. If you place the optional dumps Leaf names under
`BIOS/NDS/` (`nds_bios_arm9.bin`, `nds_bios_arm7.bin`, `nds_firmware.bin`), the
wrapper passes them to DSperate. No BIOS or firmware is bundled here.

## Controls

The defaults are DSperate's own. The MLP1 profile, including the stylus stick
and the hotkey modifier, is settled in the plan's controls step and documented
in the launcher once qualified.

## Display

Leaf runs under Weston on the MLP1. The wrapper starts DSperate as a single
fullscreen Wayland window and leaves the panel transform to Weston, so the
emulator never rotates the output itself. Correct orientation and input
coordinates are demonstrated on hardware during qualification.

## Known limits

- MLP1 only.
- `.nds` and `.zip` content. DSperate does not read `.7z`, and the NDS system
  passes archives through, so a `.7z` is not playable.
- The toolchain's SDL2 sysroot does not currently enable the Wayland client
  build, so the optional Wayland dmabuf scanout tier is not compiled. The SDL
  renderer path runs under `SDL_VIDEODRIVER=wayland` instead. Enabling the tier
  needs an SDL2 with Wayland in the toolchain sysroot.
- No bundled games, BIOS or firmware.

## Licence

The DSperate binary is GPL-3.0-or-later; this repository's build system and
scripts are MIT. See `LICENSES/README.md`, and run `make dist-source` before
distributing a build.
