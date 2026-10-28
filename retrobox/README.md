# RetroBox build of qemu-3dfx

This branch packages qemu-3dfx for [RetroBox](https://github.com/nakioman/retro-pc),
a Debian 13 retro PC appliance. It runs a Windows XP guest under KVM with
OpenGL forwarded to the host GPU through the MESA GL pass-through, and
Direct3D on top of it through WineD3D in the guest.

`master` mirrors [kjliew/qemu-3dfx](https://github.com/kjliew/qemu-3dfx);
RetroBox changes live on the `retrobox` branch.

## Differences from upstream

- **No X server.** QEMU builds the SDL GL context backend
  (`mglcntx_sdlgl.c`) instead of the GLX one and runs on SDL's `kmsdrm`
  driver, like 86Box on the appliance.
- **KMS/DRM display fixes** for SDL2's `kmsdrm` backend with a GL renderer:
  - `patches/0001-sdl2-fullscreen-no-resize.patch`: a fullscreen window is
    never resized on guest mode changes (scaling handles it).
  - `patches/0004-sdl2-2d-present-every-refresh.patch`: a frame presented
    once never reaches the screen, so the 2D frame is re-presented on every
    refresh tick instead of only on guest updates.
  - `patches/0005-sdl2-2d-x-formats-are-opaque.patch`: the scanout honours
    alpha, so x-channel framebuffers (x byte = 0) map to SDL's X formats
    instead of showing as black.
- **1024x768 monitor** (`patches/0002-vga-vbe-caps-follow-edid.patch`): with
  `-device VGA,edid=on,xmax=1024,ymax=768` the VGA BIOS only offers VESA
  modes up to the EDID maximum, like a period monitor.
- **4:3 CRT output** (`patches/0003-sdl2-fullscreen-force-4-3.patch`): in
  fullscreen every 2D guest mode is stretched into a 4:3 box (e.g. the
  720x400 text mode), the way a CRT displayed it.
- **Core 2 Duo guest.** The guest wrappers target `-march=core2` instead of
  `x86-64-v2`.
- **No Glide.** Only the MESA GL path ships; the Glide device stays in the
  binary but no host Glide library or guest Glide DLLs are packaged.

## Build

On Debian 13 amd64, or anywhere with Docker:

```bash
docker run --rm --platform linux/amd64 -v "$PWD:/src" -w /src \
    debian:trixie retrobox/build.sh --install-deps
```

`retrobox/out/` then holds:

| File | Contents |
| --- | --- |
| `qemu-retrobox-<qemu>-<rev>-linux-x86_64.tar.gz` | QEMU installed under `/opt/qemu-retrobox` (unpack there). |
| `retrobox-xp-tools-<rev>.iso` | `OPENGL32.DLL`, `FXPTL.SYS`, `INSTDRV.EXE`, `INSTALL.TXT` for the XP guest. |
| `SHA256SUMS` | Checksums of both. |

The host package and the tools ISO must come from the same commit; the
wrappers check the revision stamped into QEMU.

Runtime packages on the host (Debian 13): `libsdl2-2.0-0 libslirp0
libpixman-1-0 libgl1 libglx-mesa0 libasound2t64`.

## Releases

GitHub Actions (`.github/workflows/retrobox.yml`) builds every push to
`retrobox` and attaches the artifacts to a release for tags named
`retrobox-*`.

## Updating

```bash
git fetch upstream
git checkout master && git merge --ff-only upstream/master && git push
git checkout retrobox && git merge master
```

Bump `retrobox/qemu.env` when upstream moves to a new QEMU series patch.
