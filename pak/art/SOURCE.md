# DSperate pak artwork

The console render and light wordmark were generated with ChatGPT and supplied
by UMRK for this pak on 2026-09-16. They are packaging artwork, not an official
DSperate logo or a claim of endorsement by its author, [beebono](https://github.com/beebono).
The emulator project is [DSperate](https://github.com/beebono/DSperate).

Both supplied PNG originals are archived unchanged in the private `umrk-assets`
repository at `icons/apps/DSperate-pak/originals/`. The generation prompt, model
and original generation date were not supplied. No new image generation was
used for these exports: transparent margins were cropped, the existing two-screen
glyph was isolated, and Pillow 12.3.0 resized the images with Lanczos filtering.

The user supplied and authorized these images for this package. No separate
artwork license was supplied. The emulator's GPL license covers its software;
it is not the source of these images or a branding license for them.

## Vendored exports

| File | Size | Use |
| --- | --- | --- |
| `res/icon.png` | 256x256 RGBA | Small pak branding icon |
| `art/DSperate-flat.png` | 512x512 RGBA | Flat two-screen mark |
| `art/DSperate-photo.png` | 512x512 RGBA | Console render |
| `art/DSperate-wordmark.png` | 1024x214 RGBA | Light wordmark |

The public pak vendors these PNGs and builds offline without the private asset
repository. This pak extends the existing Nintendo DS system; it does not
replace Nintendo DS system artwork or add an Apps tile. The current content
store contract has no pak-logo field, so these are packaged branding assets,
not a new catalog capability.

## SHA-256

- `originals/DSperate_console_transparent.png`: `2afc69b5780e1b5ad76d2ecaa7c6b8cf23d9f7810cb1e13dbe718b9c990968fd`
- `originals/DSperate_logo_light.png`: `345e08c9f479f5d5c2e7b7b6f175598025ff463cf60d3551c38b3cfc37cdf66e`
- `exports/DSperate-flat.png`: `6372e43d83f6ae9443b42c697c6c402b2ab9b9e17859e4eea4ed913146d86fd3`
- `exports/DSperate-photo.png`: `620a0678e62004d332bc3653e8fc0efbd828043212f4bb82d5ec7e4eadd874a5`
- `exports/DSperate-wordmark.png`: `36ed2d007b0c60db7f903406466af8152deaaaa65abdb5d4572253c25b4a6248`
- `exports/icon.png`: `465af3484ee55283431081f0eeb8c2a983d0dc141c31df923d933475b76dbbc6`
